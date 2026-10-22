import AppKit
import Observation
import WebKit

/// App-wide browser state: spaces, sidebar tabs and folders, selection and history.
@MainActor @Observable
final class BrowserStore {
    static let shared = BrowserStore()

    var spaces: [Space]
    /// The first profile is the default one, which uses WebKit's default data store.
    var profiles: [Profile]
    var favoritesByProfile: [UUID: [BrowserTab]]
    var boosts: [Boost]
    var contentBlocking: Bool
    /// Sites where the content blocker is turned off.
    var blockingAllowedSites: [String]
    var showingImport = false
    /// Tabs picked with ⌘- or ⇧-click, acted on together. Separate from the active tab.
    var multiSelection: Set<UUID> = []
    /// Whether the last space switch moved right, for the sidebar's slide direction.
    var spaceSwitchForward = true
    /// How far the sidebar follows a two-finger swipe, in points.
    var swipeOffset: CGFloat = 0
    /// The Boost whose editor sheet is open.
    var editingBoostID: UUID?
    /// The space whose theme editor is open.
    var editingThemeSpaceID: UUID?
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
    var splits: [TabSplit]
    /// Tabs outside the sidebar: the Peek overlay and Little Arc windows.
    var transientTabs: [UUID: BrowserTab] = [:]
    var peekTabID: UUID?
    var findBarVisible = false
    var findQuery = ""
    var findStatus: String?

    @ObservationIgnored let pool = WebViewPool()
    @ObservationIgnored let downloads = DownloadManager()
    @ObservationIgnored let miniPlayer = MiniPlayerController()
    @ObservationIgnored let littleArc = LittleArcController()
    @ObservationIgnored weak var mainWindow: NSWindow?
    /// Which profile a Peek or Little Arc tab browses as.
    @ObservationIgnored private var transientProfileIDs: [UUID: UUID] = [:]
    /// Where a ⇧-click range starts.
    @ObservationIgnored private var selectionAnchor: UUID?
    @ObservationIgnored private var closedTabs: [(tab: BrowserTab, location: TabLocation, index: Int)] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var autoArchiveTask: Task<Void, Never>?

    private static let spaceHues: [Double] = [0.60, 0.95, 0.38, 0.08, 0.75, 0.50, 0.15]
    private static let spaceEmoji = ["🏠", "💼", "🎨", "📚", "🚀", "🌿", "🎧"]

    private init() {
        if let saved = Persistence.load(), !saved.spaces.isEmpty {
            spaces = saved.spaces
            let profiles = saved.profiles.flatMap { $0.isEmpty ? nil : $0 } ?? [Self.makeDefaultProfile()]
            self.profiles = profiles
            favoritesByProfile = saved.favoritesByProfile ?? [profiles[0].id: saved.favorites]
            boosts = saved.boosts ?? []
            contentBlocking = saved.contentBlocking ?? true
            blockingAllowedSites = saved.blockingAllowedSites ?? []
            activeSpaceID = saved.spaces.contains { $0.id == saved.activeSpaceID } ? saved.activeSpaceID : saved.spaces[0].id
            selectedTabBySpace = saved.selectedTabBySpace
            archive = saved.archive
            history = saved.history
            autoArchiveInterval = saved.autoArchive ?? .hours12
            splits = saved.splits ?? []
        } else {
            let home = Space(name: "Home", emoji: Self.spaceEmoji[0], hue: Self.spaceHues[0])
            spaces = [home]
            let profile = Self.makeDefaultProfile()
            profiles = [profile]
            favoritesByProfile = [profile.id: []]
            boosts = []
            contentBlocking = true
            blockingAllowedSites = []
            activeSpaceID = home.id
            selectedTabBySpace = [:]
            archive = []
            history = []
            autoArchiveInterval = .hours12
            splits = []
        }
        pool.store = self
        miniPlayer.store = self
        littleArc.store = self
        pool.installBoosts(boosts)
        updateContentRules()
        startAutoArchive()
        LiveFolderService.shared.start()
        SyncEngine.shared.start()
    }

    private static func makeDefaultProfile() -> Profile {
        Profile(name: "Default", emoji: "🙂")
    }

    // MARK: - Lookup

    var activeSpaceIndex: Int { spaces.firstIndex { $0.id == activeSpaceID } ?? 0 }
    var activeSpace: Space { spaces[activeSpaceIndex] }
    var activeTabID: UUID? { selectedTabBySpace[activeSpaceID] }
    var activeTab: BrowserTab? { tab(activeTabID) }

    var defaultProfileID: UUID { profiles[0].id }
    var activeProfileID: UUID { profileID(of: activeSpace) }
    var activeProfile: Profile { profiles.first { $0.id == activeProfileID } ?? profiles[0] }

    /// The favorites shown in the sidebar: those of the active space's profile.
    var favorites: [BrowserTab] { favoritesByProfile[activeProfileID] ?? [] }

    /// Tabs reachable from the active space, in sidebar order.
    var sidebarOrder: [BrowserTab] { favorites + activeSpace.pinned.flatMap(\.allTabs) + activeSpace.today }

    var allTabs: [BrowserTab] {
        favoritesByProfile.values.flatMap { $0 } + spaces.flatMap { $0.pinned.flatMap(\.allTabs) + $0.today }
    }

    func profileID(of space: Space) -> UUID {
        guard let id = space.profileID, profiles.contains(where: { $0.id == id }) else { return defaultProfileID }
        return id
    }

    func profileID(of location: TabLocation) -> UUID {
        if case .favorites(let profileID) = location { return profileID }
        guard let spaceID = spaceID(of: location), let space = spaces.first(where: { $0.id == spaceID }) else {
            return defaultProfileID
        }
        return profileID(of: space)
    }

    /// The profile whose cookies and storage a tab's web view uses.
    func profileID(forTab id: UUID) -> UUID {
        if let (location, _) = location(of: id) { return profileID(of: location) }
        return transientProfileIDs[id] ?? activeProfileID
    }

    func tab(_ id: UUID?) -> BrowserTab? {
        guard let id else { return nil }
        guard let (location, index) = location(of: id) else { return transientTabs[id] }
        return nodes(in: location)[index].tab
    }

    func folder(_ id: UUID) -> Folder? {
        guard let (location, index) = location(of: id) else { return nil }
        return nodes(in: location)[index].folder
    }

    /// The container holding a tab or folder, and its index there.
    func location(of id: UUID) -> (TabLocation, Int)? {
        for (profileID, tabs) in favoritesByProfile {
            if let i = tabs.firstIndex(where: { $0.id == id }) { return (.favorites(profileID), i) }
        }
        for space in spaces {
            if let found = Self.find(id, in: space.pinned, container: .pinned(space.id)) { return found }
            if let i = space.today.firstIndex(where: { $0.id == id }) { return (.today(space.id), i) }
        }
        return nil
    }

    /// The space a container belongs to; nil for Favorites, which every space of a profile shares.
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
        case .favorites(let profileID):
            return (favoritesByProfile[profileID] ?? []).map(SidebarNode.tab)
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
        case .favorites(let profileID):
            var nodes = (favoritesByProfile[profileID] ?? []).map(SidebarNode.tab)
            let result = body(&nodes)
            favoritesByProfile[profileID] = nodes.compactMap(\.tab)
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
        guard let (location, index) = location(of: id) else {
            if var tab = transientTabs[id] {
                body(&tab)
                transientTabs[id] = tab
            }
            return
        }
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
        let previous = activeTabID
        // Auto-archive counts from when a tab was last left, so stamp the tab being left too.
        if let previous, previous != id {
            updateTab(previous) { $0.lastActive = Date() }
            // Remember how the page looked, for its hover card.
            pool.captureThumbnail(tabID: previous)
        }
        // Coming back to a tab ends its Picture-in-Picture.
        if miniPlayer.tabID == id { miniPlayer.close() }
        pool.exitPictureInPicture(tabID: id)

        if let spaceID = spaceID(of: location) { activeSpaceID = spaceID }
        selectedTabBySpace[activeSpaceID] = id
        updateTab(id) {
            $0.lastActive = Date()
            $0.isUnread = nil
        }

        // Leaving a playing video pops it out, unless it stays visible in the same split.
        if let previous, previous != id, split(containing: id)?.tabIDs.contains(previous) != true {
            pool.startPictureInPictureIfPlaying(tabID: previous)
        }
    }

    /// Unloads a tab's web view, closing its mini player first.
    private func unload(_ id: UUID) {
        if miniPlayer.tabID == id { miniPlayer.close() }
        pool.discard(id)
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
        unload(id)
        if location.isToday {
            modifyNodes(location) { $0.remove(at: index) }
            closedTabs.append((tab, location, index))
            if archiving, let url = tab.url { addToArchive(url: url, title: tab.displayTitle, profileID: profileID(of: location)) }
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
        // A live folder's contents come from its feed; nothing can be dropped into it.
        if case .folder(let target) = destination, folder(target)?.live != nil { return }
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
        // A web view can't change data store, so tabs crossing profiles reload in the new one.
        if profileID(of: source) != profileID(of: destination) {
            for tab in node.allTabs { unload(tab.id) }
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
        if location.isFavorites {
            moveToTopOfToday(id, spaceID: activeSpaceID)
        } else {
            move(id, to: .favorites(profileID(of: location)))
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

    // MARK: - Instant Links

    /// Goes straight to the top result for `text`, or opens the top N as tabs when it asks
    /// for several ("top 5 …"). A single result opens in the current tab unless `inNewTab`.
    func openInstantLinks(_ text: String, inNewTab: Bool) {
        let (count, query) = InstantLinks.parse(text)
        guard !query.isEmpty else { return }
        if count == 1 {
            // Show the tab at once; its page arrives when the result does.
            let tabID = (!inNewTab ? activeTabID : nil) ?? newTab(nil)
            updateTab(tabID) { $0.title = "Finding “\(query)”…" }
            Task {
                let url = (try? await InstantLinks.results(for: query, limit: 1))?.first ?? InstantLinks.luckyURL(query)
                updateTab(tabID) {
                    $0.url = url
                    $0.title = ""
                }
                pool.load(url, tabID: tabID)
            }
        } else {
            Task {
                let urls = (try? await InstantLinks.results(for: query, limit: count)) ?? []
                guard !urls.isEmpty else {
                    newTab(InstantLinks.luckyURL(query))
                    return
                }
                // New tabs go on top, so add them last-first to keep the results in order.
                var first: UUID?
                for url in urls.reversed() { first = newTab(url, select: false) }
                if let first { select(first) }
            }
        }
    }

    // MARK: - Live folders

    var showingNewLiveFolder = false

    /// Every live folder in every space.
    var liveFolders: [Folder] {
        func collect(_ nodes: [SidebarNode]) -> [Folder] {
            nodes.flatMap { node -> [Folder] in
                guard case .folder(let folder) = node else { return [] }
                return (folder.live == nil ? [] : [folder]) + collect(folder.children)
            }
        }
        return spaces.flatMap { collect($0.pinned) }
    }

    /// Adds a live folder to the active space's pinned section and fills it.
    func createLiveFolder(_ source: LiveSource, name: String? = nil) {
        var folder = Folder(name: name ?? source.defaultName)
        folder.live = source
        modifyNodes(.pinned(activeSpaceID)) { $0.append(.folder(folder)) }
        scheduleSave()
        LiveFolderService.shared.refresh(folder.id)
    }

    /// Replaces a live folder's tabs with fresh items. Tabs for items still in the feed keep
    /// their identity (and loaded page); new items are marked unread, except on the first fill.
    func applyLiveItems(_ items: [LiveItem], toFolder id: UUID) {
        guard let folder = folder(id) else { return }
        let firstFill = folder.children.isEmpty
        var existing: [URL: BrowserTab] = [:]
        for tab in folder.allTabs {
            if let key = tab.homeURL ?? tab.url { existing[key] = tab }
        }
        var seen = Set<URL>()
        let tabs: [BrowserTab] = items.compactMap { item in
            guard seen.insert(item.url).inserted else { return nil }
            if var tab = existing[item.url] {
                // Opened items show their page's title; others follow the feed (e.g. a renamed PR).
                if pool.existingWebView(for: tab.id) == nil { tab.title = item.title }
                return tab
            }
            var tab = BrowserTab(url: item.url, title: item.title)
            tab.homeURL = item.url
            tab.isUnread = firstFill ? nil : true
            return tab
        }
        let kept = Set(tabs.map(\.id))
        for tab in folder.allTabs where !kept.contains(tab.id) {
            unload(tab.id)
            for (space, selected) in selectedTabBySpace where selected == tab.id {
                selectedTabBySpace[space] = nil
            }
        }
        updateFolder(id) { $0.children = tabs.map(SidebarNode.tab) }
    }

    /// Finds the active page's RSS or Atom feed, if it advertises one.
    func detectFeedForActivePage() async -> URL? {
        guard let webView = pool.existingWebView(for: activeTabID) else { return nil }
        let script = """
        const link = document.querySelector('link[rel~="alternate"][type="application/rss+xml"], link[rel~="alternate"][type="application/atom+xml"]');
        return link ? link.href : null;
        """
        let result = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)
        return (result as? String).flatMap(URL.init(string:))
    }

    // MARK: - Notes & Easels

    /// Creates a Note as a new Today tab.
    func newNote() {
        let id = DocumentStore.shared.createNote()
        newTab(ArckyDocument.note(id).url)
        if let tabID = activeTabID { updateTab(tabID) { $0.title = "Untitled Note" } }
    }

    /// Creates an Easel as a new Today tab.
    func newEasel() {
        let id = DocumentStore.shared.createEasel()
        newTab(ArckyDocument.easel(id).url)
        if let tabID = activeTabID { updateTab(tabID) { $0.title = "Untitled Easel" } }
    }

    /// Keeps the sidebar title of every tab showing a document in step with its title.
    func syncDocumentTitle(_ document: ArckyDocument, title: String) {
        let url = document.url
        let fallback = "Untitled \(document.kindName)"
        for tab in allTabs where tab.url == url {
            updateTab(tab.id) { $0.title = title.isEmpty ? fallback : title }
        }
    }

    // MARK: - Multi-select

    /// A click on a sidebar tab: ⌘ toggles it in the selection, ⇧ selects a range from the
    /// last click, and a plain click clears the selection and opens the tab.
    func handleClick(on id: UUID, modifiers: NSEvent.ModifierFlags) {
        if modifiers.contains(.command) {
            // The first ⌘-click also picks up the tab you're on, as in Arc.
            if multiSelection.isEmpty, let active = activeTabID, active != id { multiSelection.insert(active) }
            if multiSelection.contains(id) { multiSelection.remove(id) } else { multiSelection.insert(id) }
            selectionAnchor = id
        } else if modifiers.contains(.shift), let anchor = selectionAnchor ?? activeTabID {
            let order = sidebarOrder.map(\.id)
            if let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: id) {
                multiSelection = Set(order[min(a, b)...max(a, b)])
            }
        } else {
            multiSelection = []
            selectionAnchor = id
            select(id)
        }
    }

    /// The tabs an action on `id` applies to: the whole selection if `id` is part of it.
    func actionTargets(for id: UUID) -> [UUID] {
        guard multiSelection.count > 1, multiSelection.contains(id) else { return [id] }
        return allTabs.map(\.id).filter(multiSelection.contains)
    }

    func closeTabs(_ ids: [UUID]) {
        for id in ids { close(id) }
        multiSelection.subtract(ids)
    }

    /// Moves tabs, keeping their order, into `destination` before `beforeID`.
    func moveTabs(_ ids: [UUID], to destination: TabLocation, before beforeID: UUID? = nil) {
        for id in ids where id != beforeID { move(id, to: destination, before: beforeID) }
        multiSelection = []
    }

    func togglePinTabs(_ ids: [UUID]) {
        // Unpinned tabs go to the top of Today one by one, so go in reverse to keep their order.
        let pinning = ids.contains { location(of: $0)?.0.isToday == true }
        for id in pinning ? ids : ids.reversed() {
            let isToday = location(of: id)?.0.isToday == true
            if isToday == pinning { togglePin(id) }
        }
        multiSelection = []
    }

    /// Shows up to four tabs side by side, focusing the first.
    func splitTabs(_ ids: [UUID]) {
        let panes = Array(ids.prefix(TabSplit.maxPanes))
        guard panes.count >= 2 else { return }
        for id in panes { removeFromSplit(id) }
        splits.append(TabSplit(tabIDs: panes))
        multiSelection = []
        select(panes[0])
        scheduleSave()
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
        if !tabIDs.isEmpty { multiSelection = [] }
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
        let profile = profileID(of: location)
        for tab in folder.allTabs {
            unload(tab.id)
            if let url = tab.url { addToArchive(url: url, title: tab.displayTitle, profileID: profile) }
            for (space, selected) in selectedTabBySpace where selected == tab.id {
                selectedTabBySpace[space] = nil
            }
        }
        modifyNodes(location) { $0.remove(at: index) }
        scheduleSave()
    }

    // MARK: - Spaces

    func switchToSpace(_ id: UUID) {
        guard let target = spaces.firstIndex(where: { $0.id == id }), id != activeSpaceID else { return }
        spaceSwitchForward = target > activeSpaceIndex
        multiSelection = []
        activeSpaceID = id
        scheduleSave()
    }

    /// Moves to the neighbouring space without wrapping around (swiping stops at the ends).
    /// Returns false at an end.
    @discardableResult
    func stepSpace(by delta: Int) -> Bool {
        let target = activeSpaceIndex + delta
        guard spaces.indices.contains(target) else { return false }
        switchToSpace(spaces[target].id)
        return true
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
        for tab in spaces[i].pinned.flatMap(\.allTabs) + spaces[i].today { unload(tab.id) }
        spaces.remove(at: i)
        selectedTabBySpace[id] = nil
        if activeSpaceID == id { activeSpaceID = spaces[max(0, i - 1)].id }
        scheduleSave()
    }

    // MARK: - Split View

    func split(containing tabID: UUID?) -> TabSplit? {
        guard let tabID else { return nil }
        return splits.first { $0.tabIDs.contains(tabID) }
    }

    /// Puts `tabID` in a split next to the active tab (joining the active tab's split if it has one).
    func splitWithActive(_ tabID: UUID) {
        guard let active = activeTabID, active != tabID, tab(tabID) != nil else { return }
        removeFromSplit(tabID)
        if let i = splits.firstIndex(where: { $0.tabIDs.contains(active) }) {
            guard splits[i].tabIDs.count < TabSplit.maxPanes else { return }
            let after = splits[i].tabIDs.firstIndex(of: active)! + 1
            splits[i].tabIDs.insert(tabID, at: after)
        } else {
            splits.append(TabSplit(tabIDs: [active, tabID]))
        }
        select(tabID)
        scheduleSave()
    }

    /// Opens `url` in a new tab shown as a split pane beside the active tab.
    func openSplitPane(_ url: URL) {
        guard activeTabID != nil else {
            newTab(url)
            return
        }
        let id = newTab(url, select: false)
        splitWithActive(id)
    }

    func removeFromSplit(_ tabID: UUID) {
        guard let i = splits.firstIndex(where: { $0.tabIDs.contains(tabID) }) else { return }
        splits[i].tabIDs.removeAll { $0 == tabID }
        if splits[i].tabIDs.count < 2 { splits.remove(at: i) }
        scheduleSave()
    }

    func separateSplit(containing tabID: UUID?) {
        guard let split = split(containing: tabID) else { return }
        splits.removeAll { $0.id == split.id }
        scheduleSave()
    }

    func rotateSplit(containing tabID: UUID?) {
        guard let i = splits.firstIndex(where: { tabID.map($0.tabIDs.contains) ?? false }) else { return }
        splits[i].vertical.toggle()
        scheduleSave()
    }

    /// Drops closed tabs from splits and splits left with a single pane.
    private func normalizeSplits() {
        let live = Set(allTabs.map(\.id))
        let cleaned = splits
            .map { split in
                var split = split
                split.tabIDs.removeAll { !live.contains($0) }
                return split
            }
            .filter { $0.tabIDs.count >= 2 }
        if cleaned != splits { splits = cleaned }
    }

    // MARK: - Peek & Little Arc

    /// Opens `url` in the Peek overlay above the current page.
    @discardableResult
    func peek(_ url: URL?) -> UUID {
        closePeek()
        let tab = BrowserTab(url: url)
        transientTabs[tab.id] = tab
        transientProfileIDs[tab.id] = activeProfileID
        peekTabID = tab.id
        return tab.id
    }

    func closePeek() {
        guard let id = peekTabID else { return }
        peekTabID = nil
        discardTransient(id)
    }

    /// Turns the peeked page into a regular Today tab.
    func expandPeek() {
        guard let id = peekTabID, let tab = transientTabs[id] else { return }
        peekTabID = nil
        adoptTransient(tab)
    }

    func openLittleArc(_ url: URL?) {
        let tab = BrowserTab(url: url)
        transientTabs[tab.id] = tab
        transientProfileIDs[tab.id] = activeProfileID
        littleArc.open(tabID: tab.id)
    }

    /// Moves a Little Arc page into the main window's Today list.
    func expandLittleArc(_ id: UUID) {
        guard let tab = transientTabs[id] else { return }
        littleArc.expand(id)
        adoptTransient(tab)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Closes the Peek or Little Arc window showing `id` (e.g. after `window.close()`).
    func closeTransient(_ id: UUID) {
        if peekTabID == id {
            closePeek()
        } else {
            littleArc.close(id)
        }
    }

    func discardTransient(_ id: UUID) {
        pool.discard(id)
        transientTabs[id] = nil
        transientProfileIDs[id] = nil
    }

    private func adoptTransient(_ tab: BrowserTab) {
        if transientProfileIDs.removeValue(forKey: tab.id) != activeProfileID {
            pool.discard(tab.id)
        }
        transientTabs[tab.id] = nil
        modifyNodes(.today(activeSpaceID)) { $0.insert(.tab(tab), at: 0) }
        select(tab.id)
        scheduleSave()
    }

    // MARK: - Find in page

    func showFindBar() {
        guard activeTabID != nil else { return }
        findBarVisible = true
    }

    func closeFindBar() {
        findBarVisible = false
        findQuery = ""
        findStatus = nil
        // WebKit only hides its yellow find indicator when a search fails, so search for something
        // that can't match. The selection it left behind is cleared separately.
        if let webView = pool.existingWebView(for: activeTabID) {
            webView.find("\u{2063}arcky-no-match\u{2063}", configuration: WKFindConfiguration()) { _ in
                webView.evaluateJavaScript("window.getSelection().removeAllRanges()")
            }
        }
    }

    /// Finds the next (or previous) match of `findQuery`, highlighting it, and updates `findStatus`.
    func find(backwards: Bool = false) {
        let query = findQuery
        guard let webView = pool.existingWebView(for: activeTabID), !query.isEmpty else {
            findStatus = nil
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        webView.find(query, configuration: configuration) { [weak self] result in
            guard let self, self.findQuery == query else { return }
            guard result.matchFound else {
                self.findStatus = "Not found"
                return
            }
            webView.callAsyncJavaScript(Self.countMatchesScript, arguments: ["query": query], in: nil, in: .defaultClient) { count in
                guard self.findQuery == query, case .success(let value) = count, let n = (value as? NSNumber)?.intValue else { return }
                self.findStatus = n == 1 ? "1 match" : "\(n) matches"
            }
        }
    }

    private static let countMatchesScript = """
    const text = document.body.innerText.toLowerCase();
    const needle = query.toLowerCase();
    let count = 0, index = 0;
    while ((index = text.indexOf(needle, index)) !== -1) { count++; index += needle.length; }
    return count;
    """

    // MARK: - Profiles

    @discardableResult
    func createProfile(name: String = "New Profile", emoji: String = "🧑‍💻") -> Profile {
        let profile = Profile(name: name, emoji: emoji)
        profiles.append(profile)
        favoritesByProfile[profile.id] = []
        scheduleSave()
        return profile
    }

    func updateProfile(_ id: UUID, _ body: (inout Profile) -> Void) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        body(&profiles[i])
        scheduleSave()
    }

    /// Moves a space to another profile. Its tabs reload with that profile's cookies.
    func setProfile(_ profileID: UUID, forSpace spaceID: UUID) {
        guard let space = spaces.first(where: { $0.id == spaceID }), self.profileID(of: space) != profileID else { return }
        for tab in space.pinned.flatMap(\.allTabs) + space.today { unload(tab.id) }
        updateSpace(spaceID) { $0.profileID = profileID == defaultProfileID ? nil : profileID }
    }

    /// Deletes a profile with its website data, history, Archive and download list. Its spaces
    /// move to the default profile and its favorites go to the default profile's Archive.
    /// The default profile can't be deleted.
    func deleteProfile(_ id: UUID) {
        guard id != defaultProfileID, profiles.contains(where: { $0.id == id }) else { return }
        for space in spaces where space.profileID == id {
            setProfile(defaultProfileID, forSpace: space.id)
        }
        history.removeAll { $0.profileID == id }
        archive.removeAll { $0.profileID == id }
        downloads.forgetProfile(id)
        for tab in favoritesByProfile[id] ?? [] {
            unload(tab.id)
            if let url = tab.url { addToArchive(url: url, title: tab.displayTitle, profileID: defaultProfileID) }
            for (space, selected) in selectedTabBySpace where selected == tab.id {
                selectedTabBySpace[space] = nil
            }
        }
        favoritesByProfile[id] = nil
        profiles.removeAll { $0.id == id }
        pool.removeDataStore(forProfile: id)
        scheduleSave()
    }

    // MARK: - Themes

    func editTheme(of spaceID: UUID) {
        editingThemeSpaceID = spaceID
    }

    func setStyle(_ style: SpaceStyle?, forSpace spaceID: UUID) {
        updateSpace(spaceID) { $0.style = style }
    }

    // MARK: - Boosts

    /// The Boost for a host, enabled or not.
    func boost(forHost host: String?) -> Boost? {
        guard let host else { return nil }
        return boosts.first { $0.matches(host: host) }
    }

    var activeHost: String? { activeTab?.url?.host()?.lowercased() }

    /// Opens the Boost editor for the current site, creating its Boost if needed.
    func editBoostForActiveSite() {
        guard let host = activeHost else { return }
        editingBoostID = boostForSite(host).id
    }

    func updateBoost(_ id: UUID, _ body: (inout Boost) -> Void) {
        guard let i = boosts.firstIndex(where: { $0.id == id }) else { return }
        body(&boosts[i])
        pool.installBoosts(boosts)
        scheduleSave()
    }

    func deleteBoost(_ id: UUID) {
        boosts.removeAll { $0.id == id }
        if editingBoostID == id { editingBoostID = nil }
        pool.installBoosts(boosts)
        scheduleSave()
    }

    /// Lets the user click elements on the current page to hide them.
    func startZapping() {
        guard let id = activeTabID else { return }
        editingBoostID = nil
        pool.startZapping(tabID: id)
    }

    /// Called by the zap tool with the selector of a clicked element.
    func addZap(_ selector: String, host: String) {
        // Hiding the root would blank the whole site.
        guard !["html", "body", ":root"].contains(selector.lowercased()) else { return }
        let boost = boostForSite(host)
        updateBoost(boost.id) { boost in
            if !boost.zappedSelectors.contains(selector) { boost.zappedSelectors.append(selector) }
        }
    }

    private func boostForSite(_ host: String) -> Boost {
        if let existing = boost(forHost: host) { return existing }
        let domain = host.strippingWWW
        let boost = Boost(domain: domain, name: domain)
        boosts.append(boost)
        scheduleSave()
        return boost
    }

    // MARK: - Import

    /// Adds imported spaces and favorites. Source profiles other than the default become
    /// new Arcky profiles (website data such as logins can't be carried over).
    func applyImport(_ result: ImportResult, from sourceName: String) {
        var profileIDs: [String: UUID] = [:]
        func profileID(for key: String?) -> UUID {
            guard let key else { return defaultProfileID }
            if let id = profileIDs[key] { return id }
            let profile = createProfile(name: "\(sourceName) \(profileIDs.count + 1)", emoji: "📥")
            profileIDs[key] = profile.id
            return profile.id
        }

        var firstSpaceID: UUID?
        for imported in result.spaces {
            var space = Space(name: imported.name, emoji: imported.emoji, hue: Self.spaceHues[spaces.count % Self.spaceHues.count])
            space.pinned = Self.settingHomeURLs(imported.pinned)
            space.today = imported.today
            let profile = profileID(for: imported.profileKey)
            space.profileID = profile == defaultProfileID ? nil : profile
            if let color = imported.color {
                space.style = SpaceStyle(colors: [color])
            }
            spaces.append(space)
            firstSpaceID = firstSpaceID ?? space.id
        }
        for (key, tabs) in result.favorites {
            let profile = profileID(for: key)
            let existing = Set((favoritesByProfile[profile] ?? []).compactMap(\.url))
            favoritesByProfile[profile, default: []] += tabs
                .filter { !existing.contains($0.url ?? URL(fileURLWithPath: "/")) }
                .map { var tab = $0; tab.homeURL = tab.url; return tab }
        }
        if let firstSpaceID { switchToSpace(firstSpaceID) }
        scheduleSave()
    }

    /// Pinned tabs remember the URL they reset to when closed.
    private static func settingHomeURLs(_ nodes: [SidebarNode]) -> [SidebarNode] {
        nodes.map { node in
            switch node {
            case .tab(var tab):
                tab.homeURL = tab.homeURL ?? tab.url
                return .tab(tab)
            case .folder(var folder):
                folder.children = settingHomeURLs(folder.children)
                return .folder(folder)
            }
        }
    }

    // MARK: - Content blocking

    /// Whether ads and trackers are blocked on a host (blocking on, and the site not allowed).
    func isBlocking(onHost host: String?) -> Bool {
        guard contentBlocking else { return false }
        guard let host else { return true }
        return !blockingAllowedSites.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    func setContentBlocking(_ enabled: Bool) {
        contentBlocking = enabled
        updateContentRules()
        scheduleSave()
    }

    /// Turns blocking off (or back on) for the current site and reloads it.
    func toggleBlockingForActiveSite() {
        guard let host = activeHost?.strippingWWW else { return }
        if let i = blockingAllowedSites.firstIndex(where: { host == $0 || host.hasSuffix("." + $0) }) {
            blockingAllowedSites.remove(at: i)
        } else {
            blockingAllowedSites.append(host)
        }
        scheduleSave()
        let tabID = activeTabID
        updateContentRules { [weak self] in
            self?.pool.existingWebView(for: tabID)?.reload()
        }
    }

    /// Recompiles the rule list and installs it; `then` runs once the new rules are in place.
    private func updateContentRules(then: (() -> Void)? = nil) {
        let enabled = contentBlocking
        let allowed = blockingAllowedSites
        Task { [weak self] in
            var ruleList: WKContentRuleList?
            if enabled {
                do {
                    ruleList = try await ContentBlocker.compile(allowedSites: allowed)
                } catch {
                    NSLog("Arcky: content blocker rules failed to compile: \(error)")
                }
            }
            self?.pool.setContentRules(ruleList)
            then?()
        }
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

    /// The Archive of the active space's profile.
    var activeArchive: [HistoryEntry] { archive.filter { belongsToActiveProfile($0) } }

    func restoreFromArchive(_ entry: HistoryEntry) {
        archive.removeAll { $0.id == entry.id }
        newTab(entry.url)
    }

    func removeFromArchive(_ id: UUID) {
        archive.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Empties the active profile's Archive.
    func clearArchive() {
        archive.removeAll { belongsToActiveProfile($0) }
        scheduleSave()
    }

    private func addToArchive(url: URL, title: String, profileID: UUID) {
        archive.insert(HistoryEntry(url: url, title: title, profileID: storedProfileKey(profileID)), at: 0)
        if archive.count > 1000 { archive.removeLast(archive.count - 1000) }
    }

    /// Entries store nil for the default profile, so older entries count as the default's.
    private func storedProfileKey(_ profileID: UUID) -> UUID? {
        profileID == defaultProfileID ? nil : profileID
    }

    private func belongsToActiveProfile(_ entry: HistoryEntry) -> Bool {
        (entry.profileID ?? defaultProfileID) == activeProfileID
    }

    // MARK: - History

    var showingHistory = false

    /// The history of the active space's profile, newest first.
    var activeHistory: [HistoryEntry] { history.filter { belongsToActiveProfile($0) } }

    /// Records a finished page load under the profile of the tab it happened in.
    func recordVisit(url: URL, title: String, tabID: UUID) {
        guard url.scheme?.hasPrefix("http") == true else { return }
        let profile = storedProfileKey(profileID(forTab: tabID))
        // A reload or title update of the page last visited in this profile updates that entry.
        if let i = history.firstIndex(where: { $0.profileID == profile }), history[i].url == url {
            if !title.isEmpty { history[i].title = title }
            history[i].date = Date()
        } else {
            history.insert(HistoryEntry(url: url, title: title, profileID: profile), at: 0)
            if history.count > 5000 { history.removeLast(history.count - 5000) }
        }
        scheduleSave()
    }

    func removeFromHistory(_ id: UUID) {
        history.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Clears the active profile's history (other profiles keep theirs).
    func clearHistory() {
        history.removeAll { belongsToActiveProfile($0) }
        scheduleSave()
    }

    // MARK: - Saving

    func scheduleSave() {
        normalizeSplits()
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
            favorites: favoritesByProfile[defaultProfileID] ?? [],
            profiles: profiles,
            favoritesByProfile: favoritesByProfile,
            boosts: boosts,
            contentBlocking: contentBlocking,
            blockingAllowedSites: blockingAllowedSites,
            activeSpaceID: activeSpaceID,
            selectedTabBySpace: selectedTabBySpace,
            archive: archive,
            history: history,
            autoArchive: autoArchiveInterval,
            splits: splits
        ))
        SyncEngine.shared.scheduleSync()
    }
}
