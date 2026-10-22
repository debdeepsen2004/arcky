import Foundation
import Observation

/// App-wide browser state: spaces, sidebar tabs and folders, selection and history.
@MainActor @Observable
final class BrowserStore {
    static let shared = BrowserStore()

    var spaces: [Space]
    var favorites: [BrowserTab]
    var activeSpaceID: UUID
    var selectedTabBySpace: [UUID: UUID]
    var archive: [HistoryEntry]
    var history: [HistoryEntry]
    var autoArchiveInterval: AutoArchiveInterval
    var sidebarVisible = true
    var commandBar: CommandBarMode?
    /// The tab or folder whose name is being edited inline.
    var renamingID: UUID?
    var showingArchive = false
    var showingDownloads = false

    @ObservationIgnored let pool = WebViewPool()
    @ObservationIgnored let downloads = DownloadManager()
    @ObservationIgnored private var closedTabs: [(tab: BrowserTab, location: TabLocation, index: Int)] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var autoArchiveTask: Task<Void, Never>?

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
            autoArchiveInterval = saved.autoArchive ?? .hours12
        } else {
            let home = Space(name: "Home", emoji: Self.spaceEmoji[0], hue: Self.spaceHues[0])
            spaces = [home]
            favorites = []
            activeSpaceID = home.id
            selectedTabBySpace = [:]
            archive = []
            history = []
            autoArchiveInterval = .hours12
        }
        pool.store = self
        startAutoArchive()
    }

    // MARK: - Lookup

    var activeSpaceIndex: Int { spaces.firstIndex { $0.id == activeSpaceID } ?? 0 }
    var activeSpace: Space { spaces[activeSpaceIndex] }
    var activeTabID: UUID? { selectedTabBySpace[activeSpaceID] }
    var activeTab: BrowserTab? { tab(activeTabID) }

    /// Tabs reachable from the active space, in sidebar order.
    var sidebarOrder: [BrowserTab] { favorites + activeSpace.pinned.flatMap(\.allTabs) + activeSpace.today }

    var allTabs: [BrowserTab] { favorites + spaces.flatMap { $0.pinned.flatMap(\.allTabs) + $0.today } }

    func tab(_ id: UUID?) -> BrowserTab? {
        guard let id, let (location, index) = location(of: id) else { return nil }
        return nodes(in: location)[index].tab
    }

    func folder(_ id: UUID) -> Folder? {
        guard let (location, index) = location(of: id) else { return nil }
        return nodes(in: location)[index].folder
    }

    /// The container holding a tab or folder, and its index there.
    func location(of id: UUID) -> (TabLocation, Int)? {
        if let i = favorites.firstIndex(where: { $0.id == id }) { return (.favorites, i) }
        for space in spaces {
            if let found = Self.find(id, in: space.pinned, container: .pinned(space.id)) { return found }
            if let i = space.today.firstIndex(where: { $0.id == id }) { return (.today(space.id), i) }
        }
        return nil
    }

    /// The space a container belongs to; nil for Favorites, which every space shares.
    func spaceID(of location: TabLocation) -> UUID? {
        switch location {
        case .favorites: nil
        case .pinned(let spaceID), .today(let spaceID): spaceID
        case .folder(let folderID): spaces.first { Self.findFolder(folderID, in: $0.pinned) != nil }?.id
        }
    }

    /// Read-only access. Views call this, so it must not go through `modifyNodes`,
    /// whose inout access counts as a mutation and would re-render forever.
    func nodes(in location: TabLocation) -> [SidebarNode] {
        switch location {
        case .favorites:
            return favorites.map(SidebarNode.tab)
        case .pinned(let spaceID):
            return spaces.first { $0.id == spaceID }?.pinned ?? []
        case .today(let spaceID):
            return (spaces.first { $0.id == spaceID }?.today ?? []).map(SidebarNode.tab)
        case .folder(let folderID):
            for space in spaces {
                if let folder = Self.findFolder(folderID, in: space.pinned) { return folder.children }
            }
            return []
        }
    }

    /// Mutates a container. Favorites and Today only hold tabs, so folders put there are dropped.
    @discardableResult
    private func modifyNodes<R>(_ location: TabLocation, _ body: (inout [SidebarNode]) -> R) -> R? {
        switch location {
        case .favorites:
            var nodes = favorites.map(SidebarNode.tab)
            let result = body(&nodes)
            favorites = nodes.compactMap(\.tab)
            return result
        case .today(let spaceID):
            guard let i = spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
            var nodes = spaces[i].today.map(SidebarNode.tab)
            let result = body(&nodes)
            spaces[i].today = nodes.compactMap(\.tab)
            return result
        case .pinned(let spaceID):
            guard let i = spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
            return body(&spaces[i].pinned)
        case .folder(let folderID):
            guard let spaceID = spaceID(of: location), let i = spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }
            return Self.mutateFolder(folderID, in: &spaces[i].pinned) { body(&$0.children) }
        }
    }

    private static func find(_ id: UUID, in nodes: [SidebarNode], container: TabLocation) -> (TabLocation, Int)? {
        for (index, node) in nodes.enumerated() {
            if node.id == id { return (container, index) }
            if case .folder(let folder) = node, let found = find(id, in: folder.children, container: .folder(folder.id)) {
                return found
            }
        }
        return nil
    }

    private static func findFolder(_ id: UUID, in nodes: [SidebarNode]) -> Folder? {
        for node in nodes {
            guard case .folder(let folder) = node else { continue }
            if folder.id == id { return folder }
            if let nested = findFolder(id, in: folder.children) { return nested }
        }
        return nil
    }

    private static func mutateFolder<R>(_ id: UUID, in nodes: inout [SidebarNode], _ body: (inout Folder) -> R) -> R? {
        for i in nodes.indices {
            guard case .folder(var folder) = nodes[i] else { continue }
            if folder.id == id {
                let result = body(&folder)
                nodes[i] = .folder(folder)
                return result
            }
            if let result = mutateFolder(id, in: &folder.children, body) {
                nodes[i] = .folder(folder)
                return result
            }
        }
        return nil
    }

    func updateTab(_ id: UUID, _ body: (inout BrowserTab) -> Void) {
        guard let (location, index) = location(of: id) else { return }
        modifyNodes(location) { nodes in
            guard case .tab(var tab) = nodes[index] else { return }
            body(&tab)
            nodes[index] = .tab(tab)
        }
        scheduleSave()
    }

    // MARK: - Tabs

    func select(_ id: UUID) {
        guard let (location, _) = location(of: id) else { return }
        // Auto-archive counts from when a tab was last left, so stamp the tab being left too.
        if let previous = activeTabID, previous != id {
            updateTab(previous) { $0.lastActive = Date() }
        }
        if let spaceID = spaceID(of: location) { activeSpaceID = spaceID }
        selectedTabBySpace[activeSpaceID] = id
        updateTab(id) { $0.lastActive = Date() }
    }

    /// New tabs go to the top of Today, like Arc.
    @discardableResult
    func newTab(_ url: URL?, select shouldSelect: Bool = true) -> UUID {
        let tab = BrowserTab(url: url)
        modifyNodes(.today(activeSpaceID)) { $0.insert(.tab(tab), at: 0) }
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

    /// Closes a tab. Today tabs are removed (and archived unless `archiving` is false);
    /// pinned and favorite tabs are unloaded and reset to their pinned URL, as in Arc.
    func close(_ id: UUID, archiving: Bool = true) {
        guard let (location, index) = location(of: id), let tab = tab(id) else { return }
        let wasActive = activeTabID == id
        pool.discard(id)
        if location.isToday {
            modifyNodes(location) { $0.remove(at: index) }
            closedTabs.append((tab, location, index))
            if archiving, let url = tab.url { addToArchive(url: url, title: tab.displayTitle) }
            if wasActive {
                let remaining = nodes(in: location)
                selectedTabBySpace[activeSpaceID] = remaining.isEmpty ? nil : remaining[min(index, remaining.count - 1)].id
            }
        } else {
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
        let stillExists = spaceID(of: closed.location) != nil
        let location = stillExists ? closed.location : .today(activeSpaceID)
        modifyNodes(location) { $0.insert(.tab(closed.tab), at: min(closed.index, $0.count)) }
        select(closed.tab.id)
    }

    func duplicate(_ id: UUID) {
        guard let tab = tab(id) else { return }
        newTab(tab.url)
    }

    func renameTab(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateTab(id) { $0.customTitle = trimmed.isEmpty ? nil : trimmed }
    }

    /// Moves a tab or folder into `destination`, before `beforeID` (or at the end).
    func move(_ id: UUID, to destination: TabLocation, before beforeID: UUID? = nil) {
        guard id != beforeID, let (source, sourceIndex) = location(of: id) else { return }
        var node = nodes(in: source)[sourceIndex]
        switch node {
        case .folder(let folder):
            guard destination.acceptsFolders else { return }
            // A folder can't move into itself or one of its own subfolders.
            if case .folder(let target) = destination,
               target == folder.id || Self.findFolder(target, in: folder.children) != nil {
                return
            }
        case .tab(var tab):
            if destination.isToday {
                tab.homeURL = nil
            } else if tab.homeURL == nil {
                tab.homeURL = tab.url
            }
            node = .tab(tab)
        }
        modifyNodes(source) { $0.remove(at: sourceIndex) }
        modifyNodes(destination) { nodes in
            let index = beforeID.flatMap { b in nodes.firstIndex { $0.id == b } } ?? nodes.count
            nodes.insert(node, at: index)
        }
        if activeTabID == id, let spaceID = spaceID(of: destination), spaceID != activeSpaceID {
            selectedTabBySpace[activeSpaceID] = nil
        }
        scheduleSave()
    }

    func togglePin(_ id: UUID) {
        guard let (location, _) = location(of: id) else { return }
        switch location {
        case .today(let spaceID): move(id, to: .pinned(spaceID))
        case .pinned, .folder: moveToTopOfToday(id, spaceID: spaceID(of: location) ?? activeSpaceID)
        case .favorites: moveToTopOfToday(id, spaceID: activeSpaceID)
        }
    }

    func toggleFavorite(_ id: UUID) {
        guard let (location, _) = location(of: id) else { return }
        if location == .favorites {
            moveToTopOfToday(id, spaceID: activeSpaceID)
        } else {
            move(id, to: .favorites)
        }
    }

    private func moveToTopOfToday(_ id: UUID, spaceID: UUID) {
        move(id, to: .today(spaceID), before: nodes(in: .today(spaceID)).first?.id)
    }

    /// Archives every Today tab in the active space (the sidebar's "Clear" button).
    func clearToday() {
        for tab in activeSpace.today { close(tab.id) }
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

    // MARK: - Folders

    /// Creates a folder (at the end of `container`, by default the active space's pinned section),
    /// moves `tabIDs` into it and starts renaming it.
    @discardableResult
    func newFolder(in container: TabLocation? = nil, containing tabIDs: [UUID] = []) -> UUID {
        let folder = Folder(name: "New Folder")
        let destination = container ?? .pinned(activeSpaceID)
        modifyNodes(destination) { $0.append(.folder(folder)) }
        for id in tabIDs { move(id, to: .folder(folder.id)) }
        renamingID = folder.id
        scheduleSave()
        return folder.id
    }

    func updateFolder(_ id: UUID, _ body: (inout Folder) -> Void) {
        guard let (location, index) = location(of: id) else { return }
        modifyNodes(location) { nodes in
            guard case .folder(var folder) = nodes[index] else { return }
            body(&folder)
            nodes[index] = .folder(folder)
        }
        scheduleSave()
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateFolder(id) { $0.name = trimmed.isEmpty ? "Untitled" : trimmed }
    }

    func toggleFolder(_ id: UUID) {
        updateFolder(id) { $0.isOpen.toggle() }
    }

    /// Replaces a folder with its contents.
    func ungroupFolder(_ id: UUID) {
        guard let (location, index) = location(of: id), let folder = folder(id) else { return }
        modifyNodes(location) { $0.replaceSubrange(index...index, with: folder.children) }
        scheduleSave()
    }

    /// Deletes a folder and archives the tabs inside it.
    func deleteFolder(_ id: UUID) {
        guard let (location, index) = location(of: id), let folder = folder(id) else { return }
        for tab in folder.allTabs {
            pool.discard(tab.id)
            if let url = tab.url { addToArchive(url: url, title: tab.displayTitle) }
            for (space, selected) in selectedTabBySpace where selected == tab.id {
                selectedTabBySpace[space] = nil
            }
        }
        modifyNodes(location) { $0.remove(at: index) }
        scheduleSave()
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
        for tab in spaces[i].pinned.flatMap(\.allTabs) + spaces[i].today { pool.discard(tab.id) }
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

    func showDownloads() {
        sidebarVisible = true
        showingDownloads = true
    }

    // MARK: - Archive

    func setAutoArchive(_ interval: AutoArchiveInterval) {
        autoArchiveInterval = interval
        scheduleSave()
        archiveStaleTabs()
    }

    /// Archives Today tabs that haven't been looked at within the auto-archive interval.
    /// The selected tab of each space is never archived.
    func archiveStaleTabs(now: Date = Date()) {
        guard autoArchiveInterval != .never else { return }
        let cutoff = now.addingTimeInterval(-autoArchiveInterval.rawValue)
        for space in spaces {
            let selected = selectedTabBySpace[space.id]
            for tab in space.today where tab.id != selected && tab.lastActive < cutoff {
                close(tab.id)
            }
        }
    }

    private func startAutoArchive() {
        autoArchiveTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.archiveStaleTabs()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func restoreFromArchive(_ entry: HistoryEntry) {
        archive.removeAll { $0.id == entry.id }
        newTab(entry.url)
    }

    func removeFromArchive(_ id: UUID) {
        archive.removeAll { $0.id == id }
        scheduleSave()
    }

    func clearArchive() {
        archive.removeAll()
        scheduleSave()
    }

    private func addToArchive(url: URL, title: String) {
        archive.insert(HistoryEntry(url: url, title: title), at: 0)
        if archive.count > 1000 { archive.removeLast(archive.count - 1000) }
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
            history: history,
            autoArchive: autoArchiveInterval
        ))
    }
}
