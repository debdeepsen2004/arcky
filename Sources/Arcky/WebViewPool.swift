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

    // MARK: Hosting

    private struct WeakHost {
        weak var view: NSView?
    }

    /// Views that have asked to show each tab, oldest first. A web view can only live in one
    /// of them; when that one goes away (say Peek animating out after "Open as Tab"), it moves
    /// to the newest host that is left.
    private var hosts: [UUID: [WeakHost]] = [:]

    func attach(_ tab: BrowserTab, to host: NSView, focus: Bool) {
        let webView = webView(for: tab)
        var list = (hosts[tab.id] ?? []).filter { $0.view != nil && $0.view !== host }
        list.append(WeakHost(view: host))
        hosts[tab.id] = list
        guard webView.superview !== host else { return }
        install(webView, in: host)
        if focus { host.window?.makeFirstResponder(webView) }
    }

    func detach(_ host: NSView) {
        for (id, list) in hosts {
            let remaining = list.filter { $0.view != nil && $0.view !== host }
            hosts[id] = remaining
            if let webView = webViews[id], webView.superview === host, let next = remaining.last?.view {
                install(webView, in: next)
            }
        }
    }

    private func install(_ webView: WKWebView, in host: NSView) {
        host.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = host.bounds
        webView.autoresizingMask = [.width, .height]
        host.addSubview(webView)
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
        hosts[id] = nil
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

    func tabID(of webView: WKWebView) -> UUID? {
        tabIDs[ObjectIdentifier(webView)]
    }

    // MARK: Picture-in-Picture

    /// Tries native Picture-in-Picture for a playing video and answers "native", "fallback" or "none".
    /// Scripts run through the WebKit API count as a user gesture, so no click is needed.
    private static let startPictureInPictureScript = """
    const video = [...document.querySelectorAll('video')].find(v => !v.paused && !v.ended && v.readyState > 2);
    if (!video) return 'none';
    if (document.pictureInPictureEnabled && !video.disablePictureInPicture) {
      try { await video.requestPictureInPicture(); return 'native'; } catch (e) {}
    }
    if (video.webkitSupportsPresentationMode && video.webkitSupportsPresentationMode('picture-in-picture')) {
      video.webkitSetPresentationMode('picture-in-picture');
      return 'native';
    }
    return 'fallback';
    """

    private static let exitPictureInPictureScript = """
    if (document.pictureInPictureElement) { await document.exitPictureInPicture(); }
    for (const v of document.querySelectorAll('video')) {
      if (v.webkitPresentationMode === 'picture-in-picture') v.webkitSetPresentationMode('inline');
    }
    """

    static var autoPictureInPictureEnabled: Bool {
        UserDefaults.standard.object(forKey: "autoPictureInPicture") as? Bool ?? true
    }

    /// Called when leaving a tab: pops a playing video out, natively or into Arcky's mini player.
    func startPictureInPictureIfPlaying(tabID: UUID) {
        guard Self.autoPictureInPictureEnabled else { return }
        startPictureInPicture(tabID: tabID, fallbackToMiniPlayer: true)
    }

    /// ⌃⌘P: pops out the active tab's playing video. Only native PiP works here,
    /// because the mini player would have to take the web view out of the main window.
    func startPictureInPicture(tabID: UUID, fallbackToMiniPlayer: Bool) {
        guard let webView = webViews[tabID] else { return }
        webView.callAsyncJavaScript(Self.startPictureInPictureScript, arguments: [:], in: nil, in: .page) { [weak self] result in
            guard fallbackToMiniPlayer, case .success(let value) = result, value as? String == "fallback",
                  let store = self?.store, store.activeTabID != tabID else { return }
            store.miniPlayer.show(tabID: tabID, webView: webView)
        }
    }

    func exitPictureInPicture(tabID: UUID) {
        webViews[tabID]?.callAsyncJavaScript(Self.exitPictureInPictureScript, arguments: [:], in: nil, in: .page)
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
        if shouldPeek(navigationAction, in: webView), let url = navigationAction.request.url {
            store?.peek(url)
            return .cancel
        }
        if navigationAction.shouldPerformDownload { return .download }
        return .allow
    }

    /// Arc's Peek: links that leave a pinned tab's or favorite's site open in an overlay,
    /// so the pinned tab stays where it is. ⇧-clicking any link peeks too.
    private func shouldPeek(_ action: WKNavigationAction, in webView: WKWebView) -> Bool {
        guard action.navigationType == .linkActivated, action.targetFrame?.isMainFrame != false,
              let store, let id = tabID(of: webView), store.peekTabID != id,
              let target = action.request.url, target.scheme?.hasPrefix("http") == true else { return false }
        if action.modifierFlags.contains(.shift) { return true }
        guard let (location, _) = store.location(of: id), !location.isToday else { return false }
        return Self.siteKey(target) != Self.siteKey(webView.url)
    }

    /// Host without "www." and subdomains, so docs.github.com and github.com count as one site.
    private static func siteKey(_ url: URL?) -> String? {
        guard let host = url?.host()?.lowercased() else { return nil }
        return host.split(separator: ".").suffix(2).joined(separator: ".")
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
        // New windows from pinned tabs and favorites open in Peek, like their links do.
        let opener = tabID(of: webView).flatMap { store.location(of: $0)?.0 }
        let id: UUID
        if let opener, !opener.isToday {
            id = store.peek(navigationAction.request.url)
        } else {
            id = store.newTab(navigationAction.request.url, select: true)
        }
        return makeWebView(configuration: configuration, tabID: id)
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let id = tabID(of: webView), let store else { return }
        if store.transientTabs[id] != nil {
            store.closeTransient(id)
        } else {
            store.close(id)
        }
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
