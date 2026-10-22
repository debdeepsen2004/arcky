import Foundation
import Observation
import WebKit

/// A subscribed EasyList-style filter list.
struct FilterListSubscription: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var url: URL
    var enabled = true
    var lastUpdated: Date?
    var converted = 0
    var skipped = 0
    var lastError: String?
    /// The allowed sites baked into the compiled rules; recompile when they change.
    var compiledAllowedSites: [String]?

    var ruleListIdentifier: String { "ArckyFilter-\(id.uuidString)" }
}

/// Downloads, converts and compiles filter list subscriptions, and refreshes them weekly.
@MainActor @Observable
final class FilterListManager {
    static let shared = FilterListManager()

    static let presets: [(name: String, url: String, detail: String)] = [
        ("EasyList", "https://easylist.to/easylist/easylist.txt", "Ads"),
        ("EasyPrivacy", "https://easylist.to/easylist/easyprivacy.txt", "Trackers"),
        ("Fanboy's Annoyance List", "https://secure.fanboy.co.nz/fanboy-annoyance.txt", "Pop-ups, newsletters, social widgets"),
        ("EasyList Cookie List", "https://secure.fanboy.co.nz/fanboy-cookiemonster.txt", "Cookie notices"),
        ("AdGuard Base", "https://filters.adtidy.org/extension/safari/filters/2.txt", "Ads (AdGuard)"),
    ]
    static let refreshInterval: TimeInterval = 7 * 24 * 60 * 60

    var subscriptions: [FilterListSubscription] = []
    var updating: Set<UUID> = []

    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Arcky/FilterLists")
    }
    private static var metadataFile: URL { folder.appending(path: "subscriptions.json") }
    private static func listFile(_ id: UUID) -> URL { folder.appending(path: "\(id.uuidString).txt") }

    private init() {
        if let data = try? Data(contentsOf: Self.metadataFile),
           let saved = try? JSONDecoder().decode([FilterListSubscription].self, from: data) {
            subscriptions = saved
        }
    }

    func isSubscribed(to url: URL) -> Bool {
        subscriptions.contains { $0.url == url }
    }

    func subscribe(name: String, url: URL) {
        guard !isSubscribed(to: url) else { return }
        let subscription = FilterListSubscription(name: name, url: url)
        subscriptions.append(subscription)
        save()
        update(subscription.id)
    }

    func remove(_ id: UUID) {
        guard let subscription = subscriptions.first(where: { $0.id == id }) else { return }
        subscriptions.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: Self.listFile(id))
        WKContentRuleListStore.default().removeContentRuleList(forIdentifier: subscription.ruleListIdentifier) { _ in }
        save()
        BrowserStore.shared.refreshContentRules()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        modify(id) { $0.enabled = enabled }
        BrowserStore.shared.refreshContentRules()
    }

    /// Refreshes lists last updated more than a week ago.
    func updateStaleLists() {
        for subscription in subscriptions where subscription.enabled {
            if Date().timeIntervalSince(subscription.lastUpdated ?? .distantPast) > Self.refreshInterval {
                update(subscription.id)
            }
        }
    }

    func updateAll() {
        for subscription in subscriptions where subscription.enabled { update(subscription.id) }
    }

    /// Downloads a list, converts and compiles it, then reinstalls the content rules.
    func update(_ id: UUID) {
        guard let subscription = subscriptions.first(where: { $0.id == id }), !updating.contains(id) else { return }
        updating.insert(id)
        let allowed = BrowserStore.shared.blockingAllowedSites
        Task {
            defer { updating.remove(id) }
            do {
                var request = URLRequest(url: subscription.url)
                request.timeoutInterval = 30
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw FilterListError.http(http.statusCode)
                }
                let text = String(decoding: data, as: UTF8.self)
                guard text.contains("\n"), !text.lowercased().contains("<html") else { throw FilterListError.notAList }
                try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
                try data.write(to: Self.listFile(id), options: .atomic)
                let stats = try await Self.compile(text, identifier: subscription.ruleListIdentifier, allowedSites: allowed)
                modify(id) {
                    $0.lastUpdated = Date()
                    $0.converted = stats.converted
                    $0.skipped = stats.skipped
                    $0.lastError = nil
                    $0.compiledAllowedSites = allowed
                }
            } catch {
                modify(id) { $0.lastError = error.localizedDescription }
            }
            BrowserStore.shared.refreshContentRules()
        }
    }

    /// The compiled rule lists of enabled subscriptions. Lists compiled for a different set of
    /// allowed sites are recompiled from their saved text.
    func ruleLists(allowedSites: [String]) async -> [WKContentRuleList] {
        var lists: [WKContentRuleList] = []
        for subscription in subscriptions where subscription.enabled && subscription.lastUpdated != nil {
            do {
                if subscription.compiledAllowedSites != allowedSites {
                    let text = try String(contentsOf: Self.listFile(subscription.id), encoding: .utf8)
                    _ = try await Self.compile(text, identifier: subscription.ruleListIdentifier, allowedSites: allowedSites)
                    modify(subscription.id) { $0.compiledAllowedSites = allowedSites }
                }
                if let list = try await WKContentRuleListStore.default().contentRuleList(forIdentifier: subscription.ruleListIdentifier) {
                    lists.append(list)
                }
            } catch {
                modify(subscription.id) { $0.lastError = error.localizedDescription }
            }
        }
        return lists
    }

    /// Converts off the main thread, then compiles with WebKit.
    private static func compile(_ text: String, identifier: String, allowedSites: [String]) async throws -> FilterListConverter.Result {
        let (result, json) = try await Task.detached(priority: .utility) {
            let result = FilterListConverter.convert(text, allowedSites: allowedSites)
            let data = try JSONSerialization.data(withJSONObject: result.rules)
            return (FilterListConverter.Result(rules: [], converted: result.converted, skipped: result.skipped), String(decoding: data, as: UTF8.self))
        }.value
        guard result.converted > 0 else { throw FilterListError.noRules }
        _ = try await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json)
        return result
    }

    private func modify(_ id: UUID, _ body: (inout FilterListSubscription) -> Void) {
        guard let i = subscriptions.firstIndex(where: { $0.id == id }) else { return }
        body(&subscriptions[i])
        save()
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(subscriptions).write(to: Self.metadataFile, options: .atomic)
        } catch {
            NSLog("Arcky: could not save filter list subscriptions: \(error)")
        }
    }
}

enum FilterListError: LocalizedError {
    case http(Int)
    case notAList
    case noRules

    var errorDescription: String? {
        switch self {
        case .http(let code): "The server answered with error \(code)."
        case .notAList: "That address isn't a filter list."
        case .noRules: "The list had no rules Arcky can use."
        }
    }
}
