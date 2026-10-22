import Foundation

/// A tab in the sidebar. Mirrors Arc's `SidebarItem` of kind tab.
struct BrowserTab: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL?
    var title: String
    /// A name the user gave the tab; overrides the page title.
    var customTitle: String?
    var faviconURL: URL?
    /// For pinned and favorite tabs: the URL the tab resets to when it is closed.
    var homeURL: URL?
    /// When the tab was last selected or left; drives auto-archive.
    var lastActive = Date()

    init(url: URL?, title: String? = nil) {
        self.url = url
        self.title = title ?? ""
    }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        if !title.isEmpty { return title }
        if let host = url?.host() { return host.strippingWWW }
        return "New Tab"
    }

    /// `/favicon.ico` on the tab's own host, used until the page reports a better icon.
    var resolvedFaviconURL: URL? {
        if let faviconURL { return faviconURL }
        guard let url, let scheme = url.scheme, scheme.hasPrefix("http"), let host = url.host() else { return nil }
        return URL(string: "\(scheme)://\(host)/favicon.ico")
    }
}

/// A folder in a space's pinned section. Folders can nest.
struct Folder: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var isOpen = true
    var children: [SidebarNode] = []

    var allTabs: [BrowserTab] { children.flatMap(\.allTabs) }
}

/// An entry in the pinned tree: a tab or a folder.
enum SidebarNode: Identifiable, Codable, Hashable {
    case tab(BrowserTab)
    case folder(Folder)

    var id: UUID {
        switch self {
        case .tab(let tab): tab.id
        case .folder(let folder): folder.id
        }
    }

    var tab: BrowserTab? {
        if case .tab(let tab) = self { return tab }
        return nil
    }

    var folder: Folder? {
        if case .folder(let folder) = self { return folder }
        return nil
    }

    /// Every tab in this node, depth first.
    var allTabs: [BrowserTab] {
        switch self {
        case .tab(let tab): [tab]
        case .folder(let folder): folder.allTabs
        }
    }
}

/// A Space: its own pinned tree, Today tabs and theme colour.
struct Space: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var emoji: String
    var hue: Double
    var pinned: [SidebarNode] = []
    var today: [BrowserTab] = []

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, hue, pinned, today
    }
}

extension Space {
    /// Reads Stage 1 files too, where `pinned` was a flat list of tabs.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        emoji = try c.decode(String.self, forKey: .emoji)
        hue = try c.decode(Double.self, forKey: .hue)
        if let nodes = try? c.decode([SidebarNode].self, forKey: .pinned) {
            pinned = nodes
        } else {
            pinned = try c.decode([BrowserTab].self, forKey: .pinned).map(SidebarNode.tab)
        }
        today = try c.decode([BrowserTab].self, forKey: .today)
    }
}

/// A visited or archived page.
struct HistoryEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL
    var title: String
    var date = Date()
}

/// The container a sidebar node lives in.
enum TabLocation: Hashable {
    case favorites
    case pinned(UUID)
    case today(UUID)
    case folder(UUID)

    var isToday: Bool {
        if case .today = self { return true }
        return false
    }

    /// Pinned containers hold folders as well as tabs.
    var acceptsFolders: Bool {
        switch self {
        case .pinned, .folder: true
        case .favorites, .today: false
        }
    }
}

/// How long an unvisited Today tab lives before it is archived. Options match Arc's.
enum AutoArchiveInterval: Double, Codable, CaseIterable, Identifiable {
    case hours12 = 43_200
    case day = 86_400
    case week = 604_800
    case month = 2_592_000
    case never = 0

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .hours12: "12 hours"
        case .day: "24 hours"
        case .week: "7 days"
        case .month: "30 days"
        case .never: "Never"
        }
    }
}

enum CommandBarMode: Equatable {
    case newTab
    case editCurrent
}

extension String {
    var strippingWWW: String { hasPrefix("www.") ? String(dropFirst(4)) : self }
}
