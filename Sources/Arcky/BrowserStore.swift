import Foundation
import Observation

/// App-wide browser state: spaces, sidebar tabs, selection and history.
@MainActor @Observable
final class BrowserStore {
    static let shared = BrowserStore()

    var spaces: [Space]
    var favorites: [BrowserTab]
    var activeSpaceID: UUID
    var selectedTabBySpace: [UUID: UUID]
    var archive: [HistoryEntry]
    var history: [HistoryEntry]
    var sidebarVisible = true
    var commandBar: CommandBarMode?

    @ObservationIgnored let pool = WebViewPool()
    @ObservationIgnored private var closedTabs: [(tab: BrowserTab, location: TabLocation, index: Int)] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static let spaceHues: [Double] = [0.60, 0.95, 0.38, 0.08, 0.75, 0.50, 0.15]
    private static let spaceEmoji = ["🏠", "💼", "🎨", "📚", "🚀", "🌿", "🎧"]

    private init() {
        if let saved = Persistence.load(), !saved.spaces.isEmpty {
            spaces = saved.spaces
            favorites = saved.favorites
            activeSpaceID = saved.spaces.contains { $0.id == saved.activeSpaceID } ? saved.activeSpaceID : saved.spaces[0].id
            selectedTabBySpace = saved.selectedTabBySpace
            archive = saved.archive
            history = saved.history
        } else {
            let home = Space(name: "Home", emoji: Self.spaceEmoji[0], hue: Self.spaceHues[0])
            spaces = [home]
            favorites = []
            activeSpaceID = home.id
            selectedTabBySpace = [:]
            archive = []
            history = []
        }
        pool.store = self
    }

    // MARK: - Lookup

    var activeSpaceIndex: Int { spaces.firstIndex { $0.id == activeSpaceID } ?? 0 }
    var activeSpace: Space { spaces[activeSpaceIndex] }
    var activeTabID: UUID? { selectedTabBySpace[activeSpaceID] }
    var activeTab: BrowserTab? { tab(activeTabID) }

    /// Tabs reachable from the active space, in sidebar order.
    var sidebarOrder: [BrowserTab] { favorites + activeSpace.pinned + activeSpace.today }

    var allTabs: [BrowserTab] { favorites + spaces.flatMap { $0.pinned + $0.today } }

    func tab(_ id: UUID?) -> BrowserTab? {
        guard let id, let (location, index) = location(of: id) else { return nil }
        return tabs(in: location)[index]
    }

    func location(of id: UUID) -> (TabLocation, Int)? {
        if let i = favorites.firstIndex(where: { $0.id == id }) { return (.favorites, i) }
        for space in spaces {
            if let i = space.pinned.firstIndex(where: { $0.id == id }) { return (.pinned(space.id), i) }
            if let i = space.today.firstIndex(where: { $0.id == id }) { return (.today(space.id), i) }
        }
        return nil
    }

    /// Read-only access. Views call this, so it must not go through `modifyTabs`,
    /// whose inout access counts as a mutation and would re-render forever.
    func tabs(in location: TabLocation) -> [BrowserTab] {
        switch location {
        case .favorites: favorites
        case .pinned(let spaceID): spaces.first { $0.id == spaceID }?.pinned ?? []
        case .today(let spaceID): spaces.first { $0.id == spaceID }?.today ?? []
        }
    }

    @discardableResult
    private func modifyTabs<R>(_ location: TabLocation, _ body: (inout [BrowserTab]) -> R) -> R {
        switch location {
        case .favorites:
            return body(&favorites)
        case .pinned(let spaceID):
            let i = spaces.firstIndex { $0.id == spaceID }!
            return body(&spaces[i].pinned)
        case .today(let spaceID):
            let i = spaces.firstIndex { $0.id == spaceID }!
            return body(&spaces[i].today)
        }
    }

    func updateTab(_ id: UUID, _ body: (inout BrowserTab) -> Void) {
        guard let (location, index) = location(of: id) else { return }
        modifyTabs(location) { body(&$0[index]) }
        scheduleSave()
    }

    // MARK: - Tabs

    func select(_ id: UUID) {
        guard let (location, _) = location(of: id) else { return }
        switch location {
        case .pinned(let spaceID), .today(let spaceID): activeSpaceID = spaceID
        case .favorites: break
        }
        selectedTabBySpace[activeSpaceID] = id
        updateTab(id) { $0.lastActive = Date() }
    }

    /// New tabs go to the top of Today, like Arc.
    @discardableResult
    func newTab(_ url: URL?, select shouldSelect: Bool = true) -> UUID {
        let tab = BrowserTab(url: url)
        modifyTabs(.today(activeSpaceID)) { $0.insert(tab, at: 0) }
        if shouldSelect { select(tab.id) }
        scheduleSave()
        return tab.id
    }

    func open(_ url: URL, inNewTab: Bool) {
        if !inNewTab, let id = activeTabID {
            updateTab(id) { $0.url = url }
            pool.load(url, tabID: id)
        } else {
            newTab(url)
        }
    }

    func close(_ id: UUID) {
        guard let (location, index) = location(of: id), let tab = tab(id) else { return }
        let wasActive = activeTabID == id
        pool.discard(id)
        switch location {
        case .today:
            modifyTabs(location) { $0.remove(at: index) }
            closedTabs.append((tab, location, index))
            if let url = tab.url { addToArchive(url: url, title: tab.displayTitle) }
            if wasActive {
                let remaining = tabs(in: location)
                selectedTabBySpace[activeSpaceID] = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
            }
        case .pinned, .favorites:
            // Closing a pinned tab unloads it and resets it to its pinned URL.
            updateTab(id) { $0.url = $0.homeURL ?? $0.url }
            if wasActive { selectedTabBySpace[activeSpaceID] = nil }
        }
        scheduleSave()
    }

    func closeActiveTab() {
        if let id = activeTabID { close(id) }
    }

    func reopenClosedTab() {
        guard let closed = closedTabs.popLast() else { return }
        var location = closed.location
        if case .today(let spaceID) = location, !spaces.contains(where: { $0.id == spaceID }) {
            location = .today(activeSpaceID)
        }
        modifyTabs(location) { $0.insert(closed.tab, at: min(closed.index, $0.count)) }
        select(closed.tab.id)
    }

    func duplicate(_ id: UUID) {
        guard let tab = tab(id) else { return }
        newTab(tab.url)
    }

    /// Moves a tab to `destination`, before the tab `beforeID` (or at the end).
    func move(_ id: UUID, to destination: TabLocation, before beforeID: UUID? = nil) {
        guard id != beforeID, var tab = tab(id), let (source, sourceIndex) = location(of: id) else { return }
        switch destination {
        case .favorites, .pinned:
            if tab.homeURL == nil { tab.homeURL = tab.url }
        case .today:
            tab.homeURL = nil
        }
        modifyTabs(source) { $0.remove(at: sourceIndex) }
        modifyTabs(destination) { tabs in
            let index = beforeID.flatMap { b in tabs.firstIndex { $0.id == b } } ?? tabs.count
            tabs.insert(tab, at: index)
        }
        if case .pinned(let spaceID) = destination, spaceID != activeSpaceID, activeTabID == id {
            selectedTabBySpace[activeSpaceID] = nil
        }
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let (location, _) = location(of: id) else { return }
        switch location {
        case .today(let spaceID): move(id, to: .pinned(spaceID))
        case .pinned(let spaceID): moveToTopOfToday(id, spaceID: spaceID)
        case .favorites: moveToTopOfToday(id, spaceID: activeSpaceID)
        }
    }

    func toggleFavorite(_ id: UUID) {
        guard let (location, _) = location(of: id) else { return }
        if case .favorites = location {
            moveToTopOfToday(id, spaceID: activeSpaceID)
        } else {
            move(id, to: .favorites)
        }
    }

    private func moveToTopOfToday(_ id: UUID, spaceID: UUID) {
        move(id, to: .today(spaceID), before: tabs(in: .today(spaceID)).first?.id)
    }

    /// Archives every Today tab in the active space (the sidebar's "Clear" button).
    func clearToday() {
        let tabs = activeSpace.today
        for tab in tabs {
            pool.discard(tab.id)
            if let url = tab.url { addToArchive(url: url, title: tab.displayTitle) }
        }
        spaces[activeSpaceIndex].today = []
        if let active = activeTabID, tabs.contains(where: { $0.id == active }) {
            selectedTabBySpace[activeSpaceID] = nil
        }
        scheduleSave()
    }

    /// ⌘1–⌘8 pick by position; ⌘9 always picks the last tab.
    func selectTab(atPosition position: Int) {
        let order = sidebarOrder
        guard !order.isEmpty else { return }
        let index = position == 9 ? order.count - 1 : position - 1
        if order.indices.contains(index) { select(order[index].id) }
    }

    func cycleTab(by delta: Int) {
        let order = sidebarOrder
        guard !order.isEmpty else { return }
        let current = activeTabID.flatMap { id in order.firstIndex { $0.id == id } } ?? -1
        select(order[(current + delta + order.count) % order.count].id)
    }

    // MARK: - Spaces

    func switchToSpace(_ id: UUID) {
        guard spaces.contains(where: { $0.id == id }) else { return }
        activeSpaceID = id
        scheduleSave()
    }

    func switchToSpace(atPosition position: Int) {
        if spaces.indices.contains(position - 1) { switchToSpace(spaces[position - 1].id) }
    }

    func cycleSpace(by delta: Int) {
        let n = spaces.count
        switchToSpace(spaces[(activeSpaceIndex + delta + n) % n].id)
    }

    func createSpace() {
        let n = spaces.count
        let space = Space(
            name: "Space \(n + 1)",
            emoji: Self.spaceEmoji[n % Self.spaceEmoji.count],
            hue: Self.spaceHues[n % Self.spaceHues.count]
        )
        spaces.append(space)
        switchToSpace(space.id)
    }

    func updateSpace(_ id: UUID, _ body: (inout Space) -> Void) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        body(&spaces[i])
        scheduleSave()
    }

    func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        for tab in spaces[i].pinned + spaces[i].today { pool.discard(tab.id) }
        spaces.remove(at: i)
        selectedTabBySpace[id] = nil
        if activeSpaceID == id { activeSpaceID = spaces[max(0, i - 1)].id }
        scheduleSave()
    }

    // MARK: - Command bar & chrome

    func openCommandBar(_ mode: CommandBarMode) {
        commandBar = mode
    }

    func toggleSidebar() {
        sidebarVisible.toggle()
    }

    // MARK: - History

    func recordVisit(url: URL, title: String) {
        guard url.scheme?.hasPrefix("http") == true else { return }
        if let last = history.first, last.url == url {
            if !title.isEmpty { history[0].title = title }
        } else {
            history.insert(HistoryEntry(url: url, title: title), at: 0)
            if history.count > 5000 { history.removeLast(history.count - 5000) }
        }
        scheduleSave()
    }

    private func addToArchive(url: URL, title: String) {
        archive.insert(HistoryEntry(url: url, title: title), at: 0)
        if archive.count > 1000 { archive.removeLast(archive.count - 1000) }
    }

    // MARK: - Saving

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        Persistence.save(PersistedState(
            spaces: spaces,
            favorites: favorites,
            activeSpaceID: activeSpaceID,
            selectedTabBySpace: selectedTabBySpace,
            archive: archive,
            history: history
        ))
    }
}
