import AppKit
import SwiftUI
import WebKit

/// Hosts the active tab's WKWebView, swapping it in when the selection changes.
struct WebContentView: NSViewRepresentable {
    let tab: BrowserTab
    let pool: WebViewPool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let webView = pool.webView(for: tab)
        guard webView.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        container.window?.makeFirstResponder(webView)
    }
}
