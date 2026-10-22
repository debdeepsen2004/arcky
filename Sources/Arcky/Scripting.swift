import AppKit
import WebKit

// AppleScript object model (see Support/Arcky.sdef). Scripting objects are thin, short-lived
// wrappers that look up the live tab or space by ID on every access.

/// The application's script-visible windows: just the main browser window.
extension AppDelegate {
    func application(_ sender: NSApplication, delegateHandlesKey key: String) -> Bool {
        ["scriptWindows", "scriptTabs"].contains(key)
    }

    @objc var scriptWindows: [ScriptWindow] {
        MainActor.assumeIsolated { [ScriptWindow.shared] }
    }

    @objc var scriptTabs: [ScriptTab] {
        MainActor.assumeIsolated { ScriptWindow.shared.tabs }
    }
}

@MainActor @objc(ScriptWindow)
final class ScriptWindow: NSObject {
    static let shared = ScriptWindow()

    private var store: BrowserStore { .shared }

    @objc var uniqueID: String { "main" }
    @objc var name: String { store.activeTab?.displayTitle ?? "Arcky" }
    @objc var index: Int { 1 }
    @objc var incognito: Bool { false }
    @objc var mode: String { "normal" }

    /// The tabs of the active space in sidebar order: favorites, pinned, then Today.
    @objc var tabs: [ScriptTab] { store.sidebarOrder.map { ScriptTab(tabID: $0.id) } }
    @objc var spaces: [ScriptSpace] { store.spaces.map { ScriptSpace(spaceID: $0.id) } }
    @objc var activeTab: ScriptTab? { store.activeTabID.map(ScriptTab.init(tabID:)) }
    @objc var activeSpace: ScriptSpace? { ScriptSpace(spaceID: store.activeSpaceID) }

    /// `make new tab with properties {URL:…}` ends up here.
    @objc(insertObject:inTabsAtIndex:)
    func insert(_ tab: ScriptTab, inTabsAt index: Int) {
        tab.materialize()
    }

    @objc(insertInTabs:)
    func insertInTabs(_ tab: ScriptTab) {
        tab.materialize()
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        // NSApp.classDescription is empty here; ask for the scripting description directly.
        guard let appDescription = NSScriptClassDescription(for: NSApplication.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: appDescription, containerSpecifier: nil, key: "scriptWindows", uniqueID: uniqueID)
    }
}

@MainActor @objc(ScriptTab)
final class ScriptTab: NSObject {
    /// nil until a `make` command creates the real tab.
    private(set) var tabID: UUID?
    /// The URL set by `make … with properties` before the tab exists.
    private var pendingURL: URL?

    private var store: BrowserStore { .shared }
    private var webView: WKWebView? { store.pool.existingWebView(for: tabID) }

    /// Cocoa scripting creates new objects with plain init.
    override init() {
        super.init()
    }

    init(tabID: UUID) {
        self.tabID = tabID
        super.init()
    }

    /// Creates the real tab for a `make` command.
    func materialize() {
        guard tabID == nil else { return }
        let id = store.newTab(pendingURL)
        tabID = id
        // Start loading now rather than when the window next draws, so a script's next
        // command finds the page.
        if let tab = store.tab(id) { _ = store.pool.webView(for: tab) }
    }

    @objc var uniqueID: String { tabID?.uuidString ?? "" }
    @objc var title: String { store.tab(tabID)?.displayTitle ?? "" }
    @objc var loading: Bool { tabID.map { store.pool.runtime(for: $0).isLoading } ?? false }

    @objc var location: String {
        guard let id = tabID, let (location, _) = store.location(of: id) else { return "" }
        switch location {
        case .favorites: return "topApp"
        case .pinned, .folder: return "pinned"
        case .today: return "unpinned"
        }
    }

    @objc var url: String {
        get { store.tab(tabID)?.url?.absoluteString ?? pendingURL?.absoluteString ?? "" }
        set {
            guard let url = URLResolver.resolve(newValue) else { return }
            guard let id = tabID else {
                pendingURL = url
                return
            }
            store.updateTab(id) { $0.url = url }
            store.pool.load(url, tabID: id)
        }
    }

    @objc func handleSelectCommand(_ command: NSScriptCommand) -> Any? {
        guard let id = tabID else { return nil }
        store.select(id)
        store.mainWindow?.makeKeyAndOrderFront(nil)
        return nil
    }

    @objc func handleGoBackCommand(_ command: NSScriptCommand) -> Any? {
        webView?.goBack()
        return nil
    }

    @objc func handleGoForwardCommand(_ command: NSScriptCommand) -> Any? {
        webView?.goForward()
        return nil
    }

    @objc func handleReloadCommand(_ command: NSScriptCommand) -> Any? {
        webView?.reload()
        return nil
    }

    @objc func handleStopCommand(_ command: NSScriptCommand) -> Any? {
        webView?.stopLoading()
        return nil
    }

    @objc func handleCloseScriptCommand(_ command: NSScriptCommand) -> Any? {
        if let id = tabID { store.close(id) }
        return nil
    }

    /// Runs JavaScript and replies with the result as text. If the page is still loading,
    /// it waits (up to 10 seconds) so the script sees the finished page.
    @objc func handleExecuteCommand(_ command: NSScriptCommand) -> Any? {
        guard let javascript = command.evaluatedArguments?["javascript"] as? String else {
            command.scriptErrorNumber = errAEParamMissed
            command.scriptErrorString = "Missing the javascript parameter."
            return nil
        }
        guard let webView else {
            command.scriptErrorNumber = errAEEventFailed
            command.scriptErrorString = "The tab isn't loaded. Select it first."
            return nil
        }
        command.suspendExecution()
        Task { @MainActor in
            let deadline = Date().addingTimeInterval(10)
            // Right after a load starts, isLoading can still be false, so also wait for full progress.
            while (webView.isLoading || webView.estimatedProgress < 1) && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            Self.evaluate(javascript, in: webView, for: command)
        }
        return nil
    }

    private static func evaluate(_ javascript: String, in webView: WKWebView, for command: NSScriptCommand) {
        webView.evaluateJavaScript(javascript) { result, error in
            if let error {
                command.scriptErrorNumber = errAEEventFailed
                command.scriptErrorString = error.localizedDescription
                command.resumeExecution(withResult: nil)
                return
            }
            command.resumeExecution(withResult: Self.text(for: result))
        }
    }

    private static func text(for result: Any?) -> String {
        switch result {
        case nil, is NSNull: return ""
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default:
            if let result, JSONSerialization.isValidJSONObject(result),
               let data = try? JSONSerialization.data(withJSONObject: result),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return String(describing: result!)
        }
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let window = ScriptWindow.shared.objectSpecifier,
              let windowDescription = NSScriptClassDescription(for: ScriptWindow.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: windowDescription, containerSpecifier: window, key: "tabs", uniqueID: uniqueID)
    }
}

@MainActor @objc(ScriptSpace)
final class ScriptSpace: NSObject {
    let spaceID: UUID

    init(spaceID: UUID) {
        self.spaceID = spaceID
        super.init()
    }

    private var store: BrowserStore { .shared }
    private var space: Space? { store.spaces.first { $0.id == spaceID } }

    @objc var uniqueID: String { spaceID.uuidString }
    @objc var title: String { space?.name ?? "" }

    @objc var tabs: [ScriptTab] {
        guard let space else { return [] }
        let favorites = store.favoritesByProfile[store.profileID(of: space)] ?? []
        return (favorites + space.pinned.flatMap(\.allTabs) + space.today).map { ScriptTab(tabID: $0.id) }
    }

    @objc func handleFocusCommand(_ command: NSScriptCommand) -> Any? {
        store.switchToSpace(spaceID)
        return nil
    }

    override var objectSpecifier: NSScriptObjectSpecifier? {
        guard let window = ScriptWindow.shared.objectSpecifier,
              let windowDescription = NSScriptClassDescription(for: ScriptWindow.self) else { return nil }
        return NSUniqueIDSpecifier(containerClassDescription: windowDescription, containerSpecifier: window, key: "spaces", uniqueID: uniqueID)
    }
}
