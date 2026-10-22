import Foundation

/// Converts Adblock Plus / EasyList filter syntax into WebKit content blocker rules.
///
/// Supported: network rules (`||domain^`, `|https://…`, `/path*`, with `third-party`,
/// resource types, `domain=` and `match-case`), exceptions (`@@…`, including whole-site
/// `$document` / `$elemhide`), and element hiding (`##selector`, `example.com##selector`,
/// `~example.com##selector`). Everything WebKit can't express (regex rules, `redirect=`,
/// `csp=`, scriptlets, extended CSS, `#@#` exceptions…) is skipped and counted.
enum FilterListConverter {
    struct Result {
        var rules: [[String: Any]]
        var converted: Int
        var skipped: Int
    }

    /// WebKit refuses lists above this many rules.
    static let maxRules = 150_000

    private static let resourceTypes: [String: String] = [
        "script": "script", "image": "image", "stylesheet": "style-sheet", "font": "font",
        "media": "media", "xmlhttprequest": "fetch", "xhr": "fetch", "subdocument": "document",
        "popup": "popup", "ping": "ping", "websocket": "websocket", "other": "other",
    ]
    private static let allResourceTypes = Set(resourceTypes.values)

    /// Options that only adjust matching. Anything else not handled below makes us skip the rule.
    private static let harmlessOptions: Set<String> = ["important", "match-case"]

    static func convert(_ text: String, allowedSites: [String]) -> Result {
        var blocking: [[String: Any]] = []
        var exceptions: [[String: Any]] = []
        var genericSelectors: [String] = []
        var converted = 0
        var skipped = 0

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("!") || line.hasPrefix("[") { continue }
            guard line.allSatisfy(\.isASCII) else { skipped += 1; continue }

            if let cosmetic = cosmeticRule(line) {
                switch cosmetic {
                case .generic(let selector):
                    genericSelectors.append(selector)
                    converted += 1
                case .specific(let rule):
                    blocking.append(rule)
                    converted += 1
                case .unsupported:
                    skipped += 1
                }
                continue
            }

            guard let (rule, isException) = networkRule(line) else {
                skipped += 1
                continue
            }
            if isException { exceptions.append(rule) } else { blocking.append(rule) }
            converted += 1
        }

        // Generic hiding rules go in shared stylesheets that "ignore-previous-rules" can't undo,
        // so allowed sites are excluded from them directly. Small groups limit the damage
        // if WebKit rejects one selector.
        let allowedDomains = allowedSites.map { "*" + $0 }
        var rules = blocking
        for start in stride(from: 0, to: genericSelectors.count, by: 50) {
            let chunk = genericSelectors[start..<min(start + 50, genericSelectors.count)]
            var trigger: [String: Any] = ["url-filter": ".*"]
            if !allowedDomains.isEmpty { trigger["unless-domain"] = allowedDomains }
            rules.append(["trigger": trigger, "action": ["type": "css-display-none", "selector": chunk.joined(separator: ", ")]])
        }
        // Exceptions only cancel rules before them in the same list.
        rules += exceptions
        if !allowedDomains.isEmpty {
            rules.append(["trigger": ["url-filter": ".*", "if-domain": allowedDomains], "action": ["type": "ignore-previous-rules"]])
        }
        if rules.count > maxRules {
            skipped += rules.count - maxRules
            rules = Array(rules.prefix(maxRules))
        }
        return Result(rules: rules, converted: converted, skipped: skipped)
    }

    // MARK: Element hiding

    private enum Cosmetic {
        case generic(String)
        case specific([String: Any])
        case unsupported
    }

    private static func cosmeticRule(_ line: String) -> Cosmetic? {
        for marker in ["#@#", "#?#", "#$#", "#%#", "#@?#", "#@$#"] where line.contains(marker) {
            return .unsupported
        }
        guard let range = line.range(of: "##") else { return nil }
        let domainPart = String(line[..<range.lowerBound])
        let selector = String(line[range.upperBound...])
        let unsupportedSelector = [":-abp-", ":has-text", ":xpath", ":matches-css", ":upward", ":remove(", ":style(", ":contains(", ":nth-ancestor", ":watch-attr", ":min-text-length", ":matches-path", ":matches-attr", ":others(", "+js("]
        guard !selector.isEmpty, !unsupportedSelector.contains(where: selector.contains) else { return .unsupported }
        if domainPart.isEmpty { return .generic(selector) }

        let domains = domainPart.split(separator: ",").map { String($0).lowercased() }
        let included = domains.filter { !$0.hasPrefix("~") }.map { "*" + $0 }
        let excluded = domains.filter { $0.hasPrefix("~") }.map { "*" + $0.dropFirst() }
        var trigger: [String: Any] = ["url-filter": ".*"]
        // WebKit takes either an if-domain or an unless-domain list, not both.
        if !included.isEmpty {
            trigger["if-domain"] = included
        } else if !excluded.isEmpty {
            trigger["unless-domain"] = excluded
        }
        return .specific(["trigger": trigger, "action": ["type": "css-display-none", "selector": selector]])
    }

    // MARK: Network rules

    private static func networkRule(_ line: String) -> ([String: Any], Bool)? {
        var text = line
        let isException = text.hasPrefix("@@")
        if isException { text.removeFirst(2) }

        // Options follow the last "$".
        var options: [String] = []
        if let dollar = text.lastIndex(of: "$") {
            let optionText = String(text[text.index(after: dollar)...])
            // Values like "csp=script-src 'none'" contain spaces; anything with "=" is options too
            // (and unsupported ones then skip the rule instead of becoming part of the pattern).
            if !optionText.isEmpty, optionText.contains("=") || optionText.allSatisfy({ $0.isLetter || $0.isNumber || "~|-_.,*".contains($0) }) {
                options = optionText.lowercased().split(separator: ",").map(String.init)
                text = String(text[..<dollar])
            }
        }

        var trigger: [String: Any] = [:]
        var loadTypes: Set<String> = []
        var included: Set<String> = []
        var excluded: Set<String> = []
        var positiveTypes: Set<String> = []
        var negativeTypes: Set<String> = []
        var caseSensitive = false
        var wholeSite = false

        for option in options {
            let parts = option.split(separator: "=", maxSplits: 1).map(String.init)
            let name = parts[0]
            let negated = name.hasPrefix("~")
            let bare = negated ? String(name.dropFirst()) : name
            switch bare {
            case "third-party", "3p":
                loadTypes.insert(negated ? "first-party" : "third-party")
            case "first-party", "1p":
                loadTypes.insert(negated ? "third-party" : "first-party")
            case "domain":
                guard parts.count == 2 else { return nil }
                for domain in parts[1].split(separator: "|") {
                    if domain.hasPrefix("~") { excluded.insert("*" + domain.dropFirst()) } else { included.insert("*" + domain) }
                }
            case "match-case":
                caseSensitive = true
            case "document", "doc", "elemhide", "ehide", "generichide", "ghide":
                // Only meaningful as a whole-site exception; blocking a page outright is skipped.
                guard isException else { return nil }
                wholeSite = true
            default:
                if let type = resourceTypes[bare] {
                    if negated { negativeTypes.insert(type) } else { positiveTypes.insert(type) }
                } else if !harmlessOptions.contains(bare) {
                    return nil
                }
            }
        }

        // "~script" means every type but scripts.
        var types = positiveTypes
        if types.isEmpty, !negativeTypes.isEmpty { types = allResourceTypes.subtracting(negativeTypes) }

        if wholeSite {
            // "@@||example.com^$document": switch blocking off on that site.
            guard let domain = siteDomain(text) else { return nil }
            return (["trigger": ["url-filter": ".*", "if-domain": ["*" + domain]], "action": ["type": "ignore-previous-rules"]], true)
        }

        guard let filter = urlFilter(text) else { return nil }
        trigger["url-filter"] = filter
        if caseSensitive { trigger["url-filter-is-case-sensitive"] = true }
        if loadTypes.count == 1 { trigger["load-type"] = Array(loadTypes) }
        if !types.isEmpty { trigger["resource-type"] = types.sorted() }
        if !included.isEmpty {
            trigger["if-domain"] = included.sorted()
        } else if !excluded.isEmpty {
            trigger["unless-domain"] = excluded.sorted()
        }
        return (["trigger": trigger, "action": ["type": isException ? "ignore-previous-rules" : "block"]], isException)
    }

    /// The domain of a `||domain^` pattern.
    private static func siteDomain(_ pattern: String) -> String? {
        guard pattern.hasPrefix("||") else { return nil }
        let domain = pattern.dropFirst(2).prefix { $0 != "^" && $0 != "/" && $0 != "*" && $0 != "|" }
        return domain.isEmpty ? nil : domain.lowercased()
    }

    /// Turns an ABP pattern into the regular expression subset WebKit understands.
    private static func urlFilter(_ pattern: String) -> String? {
        var text = pattern
        // Regex rules ("/…/") can use syntax WebKit lacks.
        if text.count > 1, text.hasPrefix("/"), text.hasSuffix("/") { return nil }
        if text.isEmpty || text == "*" { return ".*" }

        var prefix = ""
        var suffix = ""
        if text.hasPrefix("||") {
            prefix = "^[^:]+://+([^:/]+\\.)?"
            text.removeFirst(2)
        } else if text.hasPrefix("|") {
            prefix = "^"
            text.removeFirst()
        }
        if text.hasSuffix("|") {
            suffix = "$"
            text.removeLast()
        }

        var body = ""
        for character in text {
            switch character {
            case "*": body += ".*"
            case "^": body += "[^a-zA-Z0-9_.%-]"
            case ".", "+", "?", "(", ")", "[", "]", "{", "}", "\\", "$", "|": body += "\\" + String(character)
            default: body.append(character)
            }
        }
        // A separator can't match the end of the URL here, but WebKit's URLs always have a "/"
        // after the host, so "||example.com^" still works.
        while body.hasPrefix(".*") && prefix.isEmpty { body.removeFirst(2) }
        let filter = prefix + body + suffix
        return filter.isEmpty ? ".*" : filter
    }
}
