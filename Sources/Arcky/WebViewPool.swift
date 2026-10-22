import AppKit
import Observation
import WebKit

/// Live, non-persisted state of a loaded tab.
@MainActor @Observable
final class TabRuntime {
    var isLoading = false
    var progress: Double = 0
    var canGoBack = false
    var canGoForward = false
}

/// Owns one WKWebView per loaded tab. Tabs load lazily when first shown.
@MainActor
final class WebViewPool: NSObject {
    weak var store: BrowserStore?

    private var webViews: [UUID: WKWebView] = [:]
    private var tabIDs: [ObjectIdentifier: UUID] = [:]
    private var runtimes: [UUID: TabRuntime] = [:]
    private var observations: [UUID: [NSKeyValueObservation]] = [:]

    private lazy var configuration: WKWebViewConfiguration = {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        // Sites serve their full experience to Safari's user agent.
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        config.preferences.isElementFullscreenEnabled = true
        return config
    }()

    private static let faviconScript = """
    (() => {
      const icon = document.querySelector('link[rel~="icon"]') || document.querySelector('link[rel="apple-touch-icon"]');
      return icon ? icon.href : null;
    })()
    """

    func runtime(for id: UUID) -> TabRuntime {
        if let runtime = runtimes[id] { return runtime }
        let runtime = TabRuntime()
        runtimes[id] = runtime
        return runtime
    }

    func existingWebView(for id: UUID?) -> WKWebView? {
        id.flatMap { webViews[$0] }
    }

    func webView(for tab: BrowserTab) -> WKWebView {
        if let webView = webViews[tab.id] { return webView }
        let webView = makeWebView(configuration: configuration, tabID: tab.id)
        if let url = tab.url { webView.load(URLRequest(url: url)) }
        return webView
    }

    /// Loads `url` if the tab is live; otherwise it loads from the tab's URL when first shown.
    func load(_ url: URL, tabID: UUID) {
        webViews[tabID]?.load(URLRequest(url: url))
    }

    func discard(_ id: UUID) {
        observations.removeValue(forKey: id)?.forEach { $0.invalidate() }
        if let webView = webViews.removeValue(forKey: id) {
            tabIDs[ObjectIdentifier(webView)] = nil
            webView.stopLoading()
            webView.removeFromSuperview()
        }
        runtimes[id] = nil
    }

    private func makeWebView(configuration: WKWebViewConfiguration, tabID: UUID) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.isInspectable = true
        webViews[tabID] = webView
        tabIDs[ObjectIdentifier(webView)] = tabID

        let runtime = runtime(for: tabID)
        observations[tabID] = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let title = webView.title, !title.isEmpty else { return }
                    self?.store?.updateTab(tabID) { $0.title = title }
                }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                MainActor.assumeIsolated {
                    guard let url = webView.url else { return }
                    self?.store?.updateTab(tabID) { tab in
                        if tab.url?.host() != url.host() { tab.faviconURL = nil }
                        tab.url = url
                    }
                }
            },
            webView.observe(\.isLoading, options: [.new]) { webView, _ in
                MainActor.assumeIsolated { runtime.isLoading = webView.isLoading }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { webView, _ in
                MainActor.assumeIsolated { runtime.progress = webView.estimatedProgress }
            },
            webView.observe(\.canGoBack, options: [.new]) { webView, _ in
                MainActor.assumeIsolated { runtime.canGoBack = webView.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { webView, _ in
                MainActor.assumeIsolated { runtime.canGoForward = webView.canGoForward }
            },
        ]
        return webView
    }

    private func tabID(of webView: WKWebView) -> UUID? {
        tabIDs[ObjectIdentifier(webView)]
    }
}

extension WebViewPool: WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let flags = navigationAction.modifierFlags
        if navigationAction.navigationType == .linkActivated, flags.contains(.command), let url = navigationAction.request.url {
            // ⌘-click opens a background tab; ⇧⌘-click opens and focuses it.
            store?.newTab(url, select: flags.contains(.shift))
            return .cancel
        }
        if navigationAction.shouldPerformDownload { return .download }
        return .allow
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if !navigationResponse.canShowMIMEType { return .download }
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.lowercased().hasPrefix("attachment") {
            return .download
        }
        return .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        startDownload(download, in: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        startDownload(download, in: webView)
    }

    private func startDownload(_ download: WKDownload, in webView: WKWebView) {
        store?.downloads.attach(download)
        store?.showingDownloads = true
        // A tab opened only to fetch a file (e.g. a target=_blank download link) has nothing to show.
        if webView.backForwardList.currentItem == nil, let id = tabID(of: webView) {
            store?.close(id, archiving: false)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let id = tabID(of: webView) else { return }
        if let url = webView.url { store?.recordVisit(url: url, title: webView.title ?? "") }
        webView.evaluateJavaScript(Self.faviconScript) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let href = result as? String, let icon = URL(string: href) else { return }
                self?.store?.updateTab(id) { $0.faviconURL = icon }
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        NSLog("Arcky: provisional navigation failed: \(error)")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("Arcky: navigation failed: \(error)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("Arcky: web content process terminated")
        webView.reload()
    }
}

extension WebViewPool: WKUIDelegate {
    /// `target=_blank` links and `window.open` become new tabs that keep their opener.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let store else { return nil }
        let id = store.newTab(navigationAction.request.url, select: true)
        return makeWebView(configuration: configuration, tabID: id)
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let id = tabID(of: webView) { store?.close(id) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.runModal()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        let alert = NSAlert()
        alert.messageText = frame.securityOrigin.host
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return panel.runModal() == .OK ? panel.urls : nil
    }
}
