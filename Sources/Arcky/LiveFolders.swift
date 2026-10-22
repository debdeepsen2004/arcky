import Foundation
import Observation
import Security

/// One entry from a live folder's source.
struct LiveItem: Equatable {
    var url: URL
    var title: String
}

enum LiveFeedError: LocalizedError {
    case http(Int)
    case notAFeed
    case needsToken

    var errorDescription: String? {
        switch self {
        case .http(401), .http(403): "GitHub refused the request. Check your token in Settings ▸ General."
        case .http(let code): "The server answered with error \(code)."
        case .notAFeed: "That address isn't an RSS or Atom feed."
        case .needsToken: "Add a GitHub token in Settings ▸ General to use this."
        }
    }
}

/// Fetches live folder items from RSS/Atom feeds and GitHub.
enum LiveFeedFetcher {
    static let itemLimit = 30

    static func fetch(_ source: LiveSource, githubToken: String?) async throws -> [LiveItem] {
        switch source {
        case .rss(let url):
            return try await fetchFeed(url)
        case .githubRepoPullRequests(let repo):
            return try await searchGitHub("repo:\(repo) is:pr is:open", token: githubToken, showRepo: false)
        case .githubMyPullRequests:
            guard let githubToken else { throw LiveFeedError.needsToken }
            return try await searchGitHub("is:pr is:open author:@me archived:false", token: githubToken, showRepo: true)
        case .githubReviewRequests:
            guard let githubToken else { throw LiveFeedError.needsToken }
            return try await searchGitHub("is:pr is:open review-requested:@me archived:false", token: githubToken, showRepo: true)
        }
    }

    // MARK: GitHub

    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            let title: String
            let number: Int
            let html_url: URL
            let repository_url: String
        }
        let items: [Item]
    }

    /// GitHub's issue search, newest updates first.
    private static func searchGitHub(_ query: String, token: String?, showRepo: Bool) async throws -> [LiveItem] {
        var components = URLComponents(string: "https://api.github.com/search/issues")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "sort", value: "updated"),
            URLQueryItem(name: "per_page", value: String(itemLimit)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw LiveFeedError.http(http.statusCode) }
        let result = try JSONDecoder().decode(SearchResponse.self, from: data)
        return result.items.map { item in
            // repository_url ends in /repos/owner/name.
            let repo = item.repository_url.split(separator: "/").suffix(2).joined(separator: "/")
            let suffix = showRepo ? "\(repo)#\(item.number)" : "#\(item.number)"
            return LiveItem(url: item.html_url, title: "\(item.title) · \(suffix)")
        }
    }

    // MARK: RSS and Atom

    private static func fetchFeed(_ url: URL) async throws -> [LiveItem] {
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw LiveFeedError.http(http.statusCode) }
        let parser = FeedParser(data: data)
        guard parser.parse() else { throw LiveFeedError.notAFeed }
        return Array(parser.items.prefix(itemLimit))
    }
}

/// A small RSS 2.0 / RDF / Atom reader: each item's (or entry's) title and link.
private final class FeedParser: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private(set) var items: [LiveItem] = []
    private var sawFeed = false
    private var inItem = false
    private var currentElement = ""
    private var title = ""
    private var link = ""

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() -> Bool {
        parser.parse()
        return sawFeed
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let name = elementName.lowercased()
        if ["rss", "feed", "rdf:rdf"].contains(name) { sawFeed = true }
        if name == "item" || name == "entry" {
            inItem = true
            title = ""
            link = ""
        }
        currentElement = name
        // Atom links are attributes; prefer the alternate (page) link.
        if inItem, name == "link", let href = attributes["href"], link.isEmpty || attributes["rel"] == "alternate" {
            link = href
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inItem else { return }
        if currentElement == "title" { title += string }
        if currentElement == "link" { link += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        guard inItem, currentElement == "title", let text = String(data: CDATABlock, encoding: .utf8) else { return }
        title += text
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        let name = elementName.lowercased()
        if name == "item" || name == "entry" {
            inItem = false
            let trimmedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmedLink), url.scheme?.hasPrefix("http") == true {
                let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                items.append(LiveItem(url: url, title: trimmedTitle.isEmpty ? url.absoluteString : trimmedTitle))
            }
        }
        currentElement = ""
    }
}

/// Refreshes live folders on launch, every 15 minutes and on request, and tracks their status.
@MainActor @Observable
final class LiveFolderService {
    static let shared = LiveFolderService()

    enum Status: Equatable {
        case refreshing
        case updated(Date)
        case failed(String)
    }

    var status: [UUID: Status] = [:]
    @ObservationIgnored private var timer: Task<Void, Never>?

    func start() {
        timer = Task { [weak self] in
            while !Task.isCancelled {
                self?.refreshAll()
                try? await Task.sleep(for: .seconds(15 * 60))
            }
        }
    }

    func refreshAll() {
        for folder in BrowserStore.shared.liveFolders {
            refresh(folder.id)
        }
    }

    func refresh(_ folderID: UUID) {
        guard let source = BrowserStore.shared.folder(folderID)?.live, status[folderID] != .refreshing else { return }
        status[folderID] = .refreshing
        let token = GitHubToken.load()
        Task {
            do {
                let items = try await LiveFeedFetcher.fetch(source, githubToken: token)
                BrowserStore.shared.applyLiveItems(items, toFolder: folderID)
                status[folderID] = .updated(Date())
            } catch {
                status[folderID] = .failed(error.localizedDescription)
            }
        }
    }
}

/// The GitHub personal access token for live folders, kept in the login Keychain.
enum GitHubToken {
    private static let service = "dev.arcky.browser.github"
    private static let account = "token"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
        return token
    }

    /// Saves the token, or deletes it when empty.
    static func save(_ token: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var item = base
        item[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(item as CFDictionary, nil)
    }
}
