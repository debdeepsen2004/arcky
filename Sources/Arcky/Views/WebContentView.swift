import AppKit
import SwiftUI
import WebKit

/// Hosts a tab's WKWebView. The pool decides which host holds it when several want the same tab.
struct WebContentView: NSViewRepresentable {
    let tab: BrowserTab
    let pool: WebViewPool
    /// Make the web view first responder when it is swapped in. Only the focused split pane should.
    var takesFocus = true

    func makeCoordinator() -> WebViewPool { pool }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        pool.attach(tab, to: container, focus: takesFocus)
    }

    static func dismantleNSView(_ container: NSView, coordinator pool: WebViewPool) {
        pool.detach(container)
    }
}
