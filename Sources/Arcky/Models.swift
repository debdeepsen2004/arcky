import Foundation

/// A tab in the sidebar. Mirrors Arc's `SidebarItem` of kind tab.
struct BrowserTab: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL?
    var title: String
    var faviconURL: URL?
    /// For pinned and favorite tabs: the URL the tab resets to when it is closed.
    var homeURL: URL?
    var lastActive = Date()

    init(url: URL?, title: String? = nil) {
        self.url = url
        self.title = title ?? ""
    }

    var displayTitle: String {
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

/// A Space: its own pinned section, Today tabs and theme colour.
struct Space: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var emoji: String
    var hue: Double
    var pinned: [BrowserTab] = []
    var today: [BrowserTab] = []
}

/// A visited or archived page.
struct HistoryEntry: Identifiable, Codable, Hashable {
    var id = UUID()
    var url: URL
    var title: String
    var date = Date()
}

/// Where a tab lives in the sidebar.
enum TabLocation: Hashable {
    case favorites
    case pinned(UUID)
    case today(UUID)
}

enum CommandBarMode: Equatable {
    case newTab
    case editCurrent
}

extension String {
    var strippingWWW: String { hasPrefix("www.") ? String(dropFirst(4)) : self }
}
