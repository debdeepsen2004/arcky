import Foundation

/// What an import produced, before it is merged into the store.
struct ImportResult {
    struct ImportedSpace {
        var name: String
        var emoji: String
        var color: ThemeColor?
        var pinned: [SidebarNode]
        var today: [BrowserTab]
        /// The source browser's profile; nil is its default profile.
        var profileKey: String?
    }

    var spaces: [ImportedSpace] = []
    /// Favorites by source profile (nil key: default profile).
    var favorites: [String?: [BrowserTab]] = [:]

    var tabCount: Int {
        spaces.reduce(0) { $0 + $1.pinned.flatMap(\.allTabs).count + $1.today.count }
            + favorites.values.reduce(0) { $0 + $1.count }
    }
}

enum ImportError: LocalizedError {
    case notFound(String)
    case unreadable(String)
    case badFormat(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let what): "\(what) wasn't found on this Mac."
        case .unreadable(let what): "Arcky isn't allowed to read \(what)."
        case .badFormat(let what): "\(what) isn't in a format Arcky understands."
        }
    }
}

/// Reads spaces, tabs and bookmarks from other browsers.
enum BrowserImporter {
    enum Source: Identifiable, Hashable {
        case arc
        /// A Chromium browser's bookmarks file.
        case chromium(name: String, bookmarks: URL)
        case safari
        case bookmarksHTML(URL)

        var id: String {
            switch self {
            case .arc: "arc"
            case .chromium(let name, _): "chromium-\(name)"
            case .safari: "safari"
            case .bookmarksHTML(let url): "html-\(url.path)"
            }
        }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    static let arcSidebarFile = home.appending(path: "Library/Application Support/Arc/StorableSidebar.json")
    static let safariBookmarksFile = home.appending(path: "Library/Safari/Bookmarks.plist")

    private static let chromiumBrowsers: [(name: String, folder: String)] = [
        ("Chrome", "Google/Chrome"),
        ("Brave", "BraveSoftware/Brave-Browser"),
        ("Edge", "Microsoft Edge"),
        ("Vivaldi", "Vivaldi"),
        ("Chromium", "Chromium"),
    ]

    /// Browsers with data on this Mac, in the order they're offered.
    static func availableSources() -> [Source] {
        var sources: [Source] = []
        if FileManager.default.fileExists(atPath: arcSidebarFile.path(percentEncoded: false)) { sources.append(.arc) }
        for browser in chromiumBrowsers {
            let file = home.appending(path: "Library/Application Support/\(browser.folder)/Default/Bookmarks")
            if FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                sources.append(.chromium(name: browser.name, bookmarks: file))
            }
        }
        if FileManager.default.fileExists(atPath: safariBookmarksFile.path(percentEncoded: false)) { sources.append(.safari) }
        return sources
    }

    static func load(_ source: Source) throws -> ImportResult {
        switch source {
        case .arc: try importArc()
        case .chromium(let name, let file): try importChromium(name: name, bookmarks: file)
        case .safari: try importSafari()
        case .bookmarksHTML(let file): try importBookmarksHTML(file)
        }
    }

    private static func readData(_ url: URL, name: String) throws -> Data {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { throw ImportError.notFound(name) }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ImportError.unreadable(name)
        }
    }

    // MARK: Arc

    /// Arc's StorableSidebar.json: spaces point at "pinned" and "unpinned" container items;
    /// items form a tree through `childrenIds`. Lists of Swift dictionaries are encoded as
    /// alternating keys and values, so only the dictionaries are kept.
    static func importArc() throws -> ImportResult {
        let data = try readData(arcSidebarFile, name: "Arc's sidebar")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sidebar = root["sidebar"] as? [String: Any],
              let containers = sidebar["containers"] as? [[String: Any]],
              let main = containers.first(where: { $0["spaces"] != nil }) else {
            throw ImportError.badFormat("Arc's sidebar")
        }
        let itemList = (main["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        var items: [String: [String: Any]] = [:]
        for item in itemList {
            if let id = item["id"] as? String { items[id] = item }
        }

        func children(of id: String) -> [SidebarNode] {
            (items[id]?["childrenIds"] as? [String] ?? []).flatMap(nodes(for:))
        }

        func nodes(for id: String) -> [SidebarNode] {
            guard let item = items[id], let data = item["data"] as? [String: Any] else { return [] }
            let customTitle = item["title"] as? String
            if let tabData = data["tab"] as? [String: Any] {
                guard let urlString = tabData["savedURL"] as? String, let url = URL(string: urlString) else { return [] }
                var tab = BrowserTab(url: url, title: tabData["savedTitle"] as? String)
                if let customTitle, !customTitle.isEmpty, customTitle != tab.title { tab.customTitle = customTitle }
                return [.tab(tab)]
            }
            if data["list"] != nil {
                return [.folder(Folder(name: customTitle ?? "Folder", isOpen: false, children: children(of: id)))]
            }
            // Split views and containers: keep their tabs.
            return children(of: id)
        }

        func profileKey(_ profile: Any?) -> String? {
            guard let profile = profile as? [String: Any] else { return nil }
            if profile["default"] as? Bool == true { return nil }
            let custom = (profile["custom"] as? [String: Any])?["_0"] as? [String: Any]
            return custom?["directoryBasename"] as? String
        }

        var result = ImportResult()
        let spaceList = (main["spaces"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        for space in spaceList {
            let containerIDs = space["containerIDs"] as? [Any] ?? []
            func container(_ name: String) -> String? {
                guard let i = containerIDs.firstIndex(where: { $0 as? String == name }), i + 1 < containerIDs.count else { return nil }
                return containerIDs[i + 1] as? String
            }
            let info = space["customInfo"] as? [String: Any]
            let emoji = ((info?["iconType"] as? [String: Any])?["emoji_v2"] as? String) ?? "🌐"
            var color: ThemeColor?
            let theme = info?["windowTheme"] as? [String: Any]
            if let mid = (theme?["primaryColorPalette"] as? [String: Any])?["midTone"] as? [String: Any],
               let r = mid["red"] as? Double, let g = mid["green"] as? Double, let b = mid["blue"] as? Double {
                color = ThemeColor(red: r, green: g, blue: b)
            }
            result.spaces.append(ImportResult.ImportedSpace(
                name: space["title"] as? String ?? "Space",
                emoji: emoji,
                color: color,
                pinned: container("pinned").map(children(of:)) ?? [],
                today: (container("unpinned").map(children(of:)) ?? []).flatMap(\.allTabs),
                profileKey: profileKey(space["profile"])
            ))
        }

        // topAppsContainerIDs alternates a profile descriptor and that profile's favorites container.
        let topApps = main["topAppsContainerIDs"] as? [Any] ?? []
        var i = 0
        while i + 1 < topApps.count {
            if let id = topApps[i + 1] as? String {
                let tabs = children(of: id).flatMap(\.allTabs)
                if !tabs.isEmpty { result.favorites[profileKey(topApps[i]), default: []] += tabs }
            }
            i += 2
        }
        return result
    }

    // MARK: Chromium

    /// Chrome-style `Bookmarks` JSON: roots → bookmark_bar / other / synced, nodes of type url or folder.
    static func importChromium(name: String, bookmarks: URL) throws -> ImportResult {
        let data = try readData(bookmarks, name: "\(name)'s bookmarks")
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else {
            throw ImportError.badFormat("\(name)'s bookmarks")
        }
        func convert(_ node: [String: Any]) -> SidebarNode? {
            let title = node["name"] as? String ?? ""
            if node["type"] as? String == "url" {
                guard let url = (node["url"] as? String).flatMap(URL.init(string:)) else { return nil }
                return .tab(BrowserTab(url: url, title: title))
            }
            let children = (node["children"] as? [[String: Any]] ?? []).compactMap(convert)
            return children.isEmpty ? nil : .folder(Folder(name: title.isEmpty ? "Folder" : title, isOpen: false, children: children))
        }
        var pinned = ((roots["bookmark_bar"] as? [String: Any])?["children"] as? [[String: Any]] ?? []).compactMap(convert)
        for key in ["other", "synced"] {
            if let node = roots[key] as? [String: Any], case .folder(let folder)? = convert(node) {
                pinned.append(.folder(folder))
            }
        }
        return ImportResult(spaces: [.init(name: name, emoji: "🔖", color: nil, pinned: pinned, today: [], profileKey: nil)])
    }

    // MARK: Safari

    /// Safari's Bookmarks.plist (needs Full Disk Access). The Reading List is skipped.
    static func importSafari() throws -> ImportResult {
        let data = try readData(safariBookmarksFile, name: "Safari's bookmarks")
        guard let root = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw ImportError.badFormat("Safari's bookmarks")
        }
        func convert(_ node: [String: Any]) -> SidebarNode? {
            switch node["WebBookmarkType"] as? String {
            case "WebBookmarkTypeLeaf":
                guard let url = (node["URLString"] as? String).flatMap(URL.init(string:)) else { return nil }
                let title = (node["URIDictionary"] as? [String: Any])?["title"] as? String
                return .tab(BrowserTab(url: url, title: title))
            case "WebBookmarkTypeList":
                if node["Title"] as? String == "com.apple.ReadingList" { return nil }
                let children = (node["Children"] as? [[String: Any]] ?? []).compactMap(convert)
                let title = node["Title"] as? String ?? "Folder"
                let name = title == "BookmarksBar" ? "Favorites Bar" : title == "BookmarksMenu" ? "Bookmarks Menu" : title
                return children.isEmpty ? nil : .folder(Folder(name: name, isOpen: false, children: children))
            default:
                return nil
            }
        }
        let pinned = (root["Children"] as? [[String: Any]] ?? []).compactMap(convert)
        return ImportResult(spaces: [.init(name: "Safari", emoji: "🧭", color: nil, pinned: pinned, today: [], profileKey: nil)])
    }

    // MARK: Bookmarks HTML

    /// The Netscape bookmarks file every browser exports: nested <DL> lists of <H3> folders and <A> links.
    static func importBookmarksHTML(_ file: URL) throws -> ImportResult {
        let data = try readData(file, name: "That file")
        guard let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.badFormat("That file")
        }
        let token = try! NSRegularExpression(
            pattern: #"<H3[^>]*>(.*?)</H3>|<A\s[^>]*HREF="([^"]*)"[^>]*>(.*?)</A>|<DL>|</DL>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        )
        // A stack of open folders; the bottom one collects top-level items.
        var stack: [Folder] = [Folder(name: "root")]
        var pendingFolder: String?
        let ns = html as NSString
        for match in token.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let text = ns.substring(with: match.range)
            if match.range(at: 1).location != NSNotFound {
                pendingFolder = decodeEntities(ns.substring(with: match.range(at: 1)))
            } else if match.range(at: 2).location != NSNotFound {
                let href = decodeEntities(ns.substring(with: match.range(at: 2)))
                guard let url = URL(string: href), url.scheme?.hasPrefix("http") == true else { continue }
                let title = decodeEntities(ns.substring(with: match.range(at: 3)))
                stack[stack.count - 1].children.append(.tab(BrowserTab(url: url, title: title)))
            } else if text.uppercased() == "<DL>" {
                // The first <DL> is the file's outer list; later ones open the folder named just before.
                if let name = pendingFolder {
                    stack.append(Folder(name: name, isOpen: false))
                    pendingFolder = nil
                }
            } else if stack.count > 1 {
                let folder = stack.removeLast()
                if !folder.children.isEmpty { stack[stack.count - 1].children.append(.folder(folder)) }
            }
        }
        while stack.count > 1 {
            let folder = stack.removeLast()
            if !folder.children.isEmpty { stack[stack.count - 1].children.append(.folder(folder)) }
        }
        guard !stack[0].children.isEmpty else { throw ImportError.badFormat("That file") }
        let name = file.deletingPathExtension().lastPathComponent
        return ImportResult(spaces: [.init(name: name, emoji: "🔖", color: nil, pinned: stack[0].children, today: [], profileKey: nil)])
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
