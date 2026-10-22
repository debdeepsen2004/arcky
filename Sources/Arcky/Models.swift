import AppKit
import SwiftUI

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

/// A browsing identity with its own cookies, storage and favorites. Spaces belong to one.
struct Profile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var emoji: String
}

/// An sRGB colour that survives encoding.
struct ThemeColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(hue: Double, saturation: Double, brightness: Double) {
        let ns = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        self.init(red: ns.redComponent, green: ns.greenComponent, blue: ns.blueComponent)
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// Linear mix towards `other`; `amount` 0 keeps self, 1 gives `other`.
    func mixed(with other: ThemeColor, _ amount: Double) -> ThemeColor {
        ThemeColor(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount
        )
    }

    static let white = ThemeColor(red: 1, green: 1, blue: 1)
    static let night = ThemeColor(red: 0.07, green: 0.07, blue: 0.09)
}

enum ThemeAppearance: String, Codable, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

/// A space's custom theme from the theme editor: a gradient of up to three colours.
struct SpaceStyle: Codable, Hashable {
    static let maxColors = 3

    var colors: [ThemeColor]
    /// How strongly the colours show through, 0 (nearly neutral) to 1 (vivid).
    var intensity = 0.6
    /// Film-grain noise over the background, 0 to 1.
    var grain = 0.0
    var appearance = ThemeAppearance.auto
}

/// A Space: its own pinned tree, Today tabs and theme.
struct Space: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var emoji: String
    var hue: Double
    var pinned: [SidebarNode] = []
    var today: [BrowserTab] = []
    /// nil means the default profile.
    var profileID: UUID?
    /// nil means the simple theme derived from `hue`.
    var style: SpaceStyle?

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, hue, pinned, today, profileID, style
    }
}

/// Arc's Boosts: per-site customisations.
struct Boost: Identifiable, Codable, Hashable {
    var id = UUID()
    /// The site it applies to, e.g. "github.com" (subdomains included).
    var domain: String
    var name: String
    var isEnabled = true
    var css = ""
    var js = ""
    /// Elements hidden with the zap tool, as CSS selectors.
    var zappedSelectors: [String] = []
    /// Replaces the page's fonts (code blocks keep theirs).
    var fontFamily: String?

    func matches(host: String) -> Bool {
        let host = host.lowercased()
        return host == domain || host.hasSuffix("." + domain)
    }

    var isEmpty: Bool {
        css.isEmpty && js.isEmpty && zappedSelectors.isEmpty && fontFamily == nil
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
        profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        style = try c.decodeIfPresent(SpaceStyle.self, forKey: .style)
    }
}

/// Two to four tabs shown side by side (Arc's Split View).
struct TabSplit: Identifiable, Codable, Hashable {
    static let maxPanes = 4

    var id = UUID()
    var tabIDs: [UUID]
    /// Panes stacked top to bottom instead of left to right.
    var vertical = false
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
    /// The favorites of the given profile.
    case favorites(UUID)
    case pinned(UUID)
    case today(UUID)
    case folder(UUID)

    var isToday: Bool {
        if case .today = self { return true }
        return false
    }

    var isFavorites: Bool {
        if case .favorites = self { return true }
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
    /// Picks the page for a new Split View pane next to the active tab.
    case splitPane
}

extension String {
    var strippingWWW: String { hasPrefix("www.") ? String(dropFirst(4)) : self }
}
