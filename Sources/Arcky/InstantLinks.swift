import Foundation

/// Arc's Instant Links: go straight to the best result for a search instead of a results
/// page, or open the top few results as tabs ("top 5 swift tutorials").
enum InstantLinks {
    static let maxResults = 8

    /// "top 5 swift tutorials" or "3 best ramen spots" ask for several results.
    /// Returns how many results to open and the query to search for.
    static func parse(_ text: String) -> (count: Int, query: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = try! NSRegularExpression(pattern: #"^(?:(?:open|show)\s+)?(?:the\s+)?(?:top\s+)?(\d{1,2})\s+(.+)$"#, options: .caseInsensitive)
        let ns = trimmed as NSString
        guard let match = pattern.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)),
              let count = Int(ns.substring(with: match.range(at: 1))), count >= 2 else {
            return (1, trimmed)
        }
        return (min(count, maxResults), ns.substring(with: match.range(at: 2)))
    }

    /// DuckDuckGo's "first result" redirect, used when results can't be read.
    static func luckyURL(_ query: String) -> URL {
        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: "\\" + query)]
        return components.url!
    }

    /// The top organic results for a query, ads skipped, duplicates removed.
    static func results(for query: String, limit: Int) async throws -> [URL] {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        var request = URLRequest(url: components.url!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        let (data, _) = try await URLSession.shared.data(for: request)
        return parseResults(String(decoding: data, as: UTF8.self), limit: limit)
    }

    /// Reads result links from DuckDuckGo's HTML results page. Links are either direct or
    /// wrapped as `//duckduckgo.com/l/?uddg=<url>`; ad links point back at duckduckgo.com.
    static func parseResults(_ html: String, limit: Int) -> [URL] {
        let link = try! NSRegularExpression(pattern: #"class="result__a"[^>]*href="([^"]+)""#)
        let ns = html as NSString
        var urls: [URL] = []
        var seen = Set<String>()
        for match in link.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            var href = ns.substring(with: match.range(at: 1)).replacingOccurrences(of: "&amp;", with: "&")
            if href.hasPrefix("//") { href = "https:" + href }
            guard var url = URL(string: href) else { continue }
            if url.host()?.hasSuffix("duckduckgo.com") == true {
                guard let target = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                        .queryItems?.first(where: { $0.name == "uddg" })?.value,
                      let decoded = URL(string: target) else { continue }
                url = decoded
            }
            guard url.scheme?.hasPrefix("http") == true, seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
            if urls.count == limit { break }
        }
        return urls
    }
}
