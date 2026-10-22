import AppKit
import SwiftUI
import WebKit

/// Arc's mini player: when native Picture-in-Picture isn't available, the tab's own web view
/// moves into a small floating panel with its video stretched to fill it.
@MainActor
final class MiniPlayerController: NSObject, NSWindowDelegate {
    weak var store: BrowserStore?
    private(set) var tabID: UUID?
    private var panel: NSPanel?
    private weak var webView: WKWebView?

    private static let enterScript = """
    (() => {
      const video = [...document.querySelectorAll('video')].find(v => !v.paused) || document.querySelector('video');
      if (!video) return;
      video.setAttribute('data-arcky-mini', '');
      let style = document.getElementById('arcky-mini-player');
      if (!style) {
        style = document.createElement('style');
        style.id = 'arcky-mini-player';
        document.documentElement.appendChild(style);
      }
      style.textContent = `
        video[data-arcky-mini] { position: fixed !important; inset: 0 !important; width: 100vw !important;
          height: 100vh !important; max-width: none !important; max-height: none !important;
          z-index: 2147483647 !important; background: #000 !important; object-fit: contain !important;
          transform: none !important; }
        html, body { overflow: hidden !important; }`;
    })()
    """

    private static let exitScript = """
    document.getElementById('arcky-mini-player')?.remove();
    document.querySelector('video[data-arcky-mini]')?.removeAttribute('data-arcky-mini');
    """

    func show(tabID: UUID, webView: WKWebView) {
        close()
        self.tabID = tabID
        self.webView = webView

        let size = NSSize(width: 420, height: 236)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(x: screen.maxX - size.width - 24, y: screen.minY + 24, width: size.width, height: size.height)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentAspectRatio = size
        panel.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        let controls = NSHostingView(rootView: MiniPlayerControls(
            backToTab: { [weak self] in self?.backToTab() },
            close: { [weak self] in self?.pauseAndClose() }
        ))
        controls.frame = NSRect(x: size.width - 76, y: size.height - 34, width: 70, height: 28)
        controls.autoresizingMask = [.minXMargin, .minYMargin]
        container.addSubview(controls)

        panel.contentView = container
        panel.orderFrontRegardless()
        self.panel = panel
        webView.evaluateJavaScript(Self.enterScript)
    }

    /// Restores the page and closes the panel. The web view is left for the main window to take back.
    func close() {
        guard let panel else { return }
        webView?.callAsyncJavaScript(Self.exitScript, arguments: [:], in: nil, in: .page)
        webView?.removeFromSuperview()
        self.panel = nil
        tabID = nil
        webView = nil
        panel.delegate = nil
        panel.close()
    }

    private func backToTab() {
        guard let tabID, let store else { return }
        store.select(tabID)
        store.mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func pauseAndClose() {
        webView?.evaluateJavaScript("document.querySelectorAll('video').forEach(v => v.pause())")
        close()
    }

    func windowWillClose(_ notification: Notification) {
        // Closed from the title bar.
        pauseAndClose()
    }
}

private struct MiniPlayerControls: View {
    let backToTab: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: backToTab) { Image(systemName: "arrow.up.backward.and.arrow.down.forward") }
                .help("Back to Tab")
            Button(action: close) { Image(systemName: "xmark") }
                .help("Close Mini Player")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .glassSurface(Capsule(), tint: .black.opacity(0.3), interactive: true, fallback: Color.black.opacity(0.55))
    }
}
