import AppKit
import SwiftUI

/// Little Arc: small, quick windows for links opened from other apps. A page can be
/// promoted into the main window, or closed and forgotten.
@MainActor
final class LittleArcController: NSObject, NSWindowDelegate {
    weak var store: BrowserStore?
    private var windows: [UUID: NSWindow] = [:]
    /// Windows closing because their page moved to the main window; their tab must survive.
    private var expanding: Set<UUID> = []

    func open(tabID: UUID) {
        guard let store else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 300)
        window.contentView = NSHostingView(rootView: LittleArcView(tabID: tabID).environment(store))
        window.delegate = self
        if let last = windows.values.first(where: \.isVisible) {
            window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: last.frame.minX, y: last.frame.maxY)))
        } else {
            window.center()
        }
        windows[tabID] = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func close(_ id: UUID) {
        windows[id]?.close()
    }

    func expand(_ id: UUID) {
        expanding.insert(id)
        windows[id]?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows[id] = nil
        if expanding.remove(id) == nil {
            store?.discardTransient(id)
        }
    }
}

struct LittleArcView: View {
    let tabID: UUID
    @Environment(BrowserStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @State private var address = ""
    @FocusState private var editingAddress: Bool

    var body: some View {
        let theme = SpaceTheme(space: store.activeSpace, systemDark: colorScheme == .dark)
        let tab = store.transientTabs[tabID]
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Spacer().frame(width: 64)
                IconButton(systemName: "arrow.clockwise", help: "Reload") {
                    store.pool.existingWebView(for: tabID)?.reload()
                }
                TextField("Search or Enter URL…", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.tileFill))
                    .focused($editingAddress)
                    .onSubmit(load)
                IconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Open in Arcky") {
                    store.expandLittleArc(tabID)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .foregroundStyle(theme.secondaryText)
            .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
            if let tab {
                WebContentView(tab: tab, pool: store.pool, takesFocus: true)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding([.horizontal, .bottom], 6)
            }
        }
        .background(theme.background)
        .ignoresSafeArea()
        .environment(\.spaceTheme, theme)
        .onAppear { address = tab?.url?.absoluteString ?? "" }
        .onChange(of: tab?.url) { _, url in
            if !editingAddress { address = url?.absoluteString ?? "" }
        }
    }

    private func load() {
        guard let url = URLResolver.resolve(address) else { return }
        store.updateTab(tabID) { $0.url = url }
        store.pool.load(url, tabID: tabID)
        editingAddress = false
    }
}
