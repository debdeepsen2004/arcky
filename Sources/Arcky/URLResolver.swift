import Foundation

/// Turns command bar input into a URL: a full URL, a bare host, or a search.
enum URLResolver {
    private static let schemes: Set<String> = ["http", "https", "file", "about", "data"]

    static func resolve(_ raw: String) -> URL? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), schemes.contains(scheme) {
            return url
        }
        if looksLikeHost(text) {
            let isLocal = text.hasPrefix("localhost") || text.hasPrefix("127.") || text.hasPrefix("0.0.0.0")
            return URL(string: (isLocal ? "http://" : "https://") + text)
        }
        return searchURL(text)
    }

    static func isLikelyURL(_ raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let scheme = URL(string: text)?.scheme?.lowercased(), schemes.contains(scheme) { return true }
        return looksLikeHost(text)
    }

    static func searchURL(_ query: String) -> URL {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        return components.url!
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        guard !text.contains(" ") else { return false }
        if text.hasPrefix("localhost") { return true }
        let host = text.split(separator: "/", maxSplits: 1).first.map(String.init) ?? text
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        let tld = parts.last!.split(separator: ":").first ?? ""
        return tld.count >= 2 && (tld.allSatisfy(\.isLetter) || tld.allSatisfy(\.isNumber))
    }
}
