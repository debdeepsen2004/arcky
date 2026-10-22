import AppKit
import SwiftUI

struct RootView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("sidebarWidth") private var sidebarWidth = 248.0
    /// The hidden sidebar is floating over the page because the pointer reached the left edge.
    @State private var peeking = false

    var body: some View {
        let theme = SpaceTheme(hue: store.activeSpace.hue, dark: colorScheme == .dark)
        ZStack(alignment: .leading) {
            theme.background
            HStack(spacing: 0) {
                if store.sidebarVisible {
                    SidebarView()
                        .frame(width: sidebarWidth)
                        .overlay(alignment: .trailing) { SidebarResizeHandle(width: $sidebarWidth) }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ContentArea()
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                    .padding(.leading, store.sidebarVisible ? 0 : 8)
            }
            if !store.sidebarVisible {
                // Hot zone along the left edge that reveals the sidebar.
                Color.clear
                    .frame(width: 10)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { if $0 { peeking = true } }
                if peeking {
                    SidebarView()
                        .frame(width: sidebarWidth)
                        .background(theme.background)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.3), radius: 16, x: 4)
                        .padding(6)
                        .onHover { if !$0 { peeking = false } }
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            if let mode = store.commandBar {
                CommandBarView(mode: mode)
            }
        }
        .ignoresSafeArea()
        .environment(\.spaceTheme, theme)
        .animation(.spring(duration: 0.28), value: store.sidebarVisible)
        .animation(.spring(duration: 0.25), value: peeking)
        .animation(.easeInOut(duration: 0.25), value: store.activeSpaceID)
        .onChange(of: store.sidebarVisible) { peeking = false }
        .background(WindowConfigurator(showsTrafficLights: store.sidebarVisible || peeking))
        .sheet(isPresented: Binding(get: { store.showingArchive }, set: { store.showingArchive = $0 })) {
            ArchiveView().environment(store)
        }
    }
}

/// Drag the sidebar's right edge to resize it.
private struct SidebarResizeHandle: View {
    @Binding var width: Double
    @State private var startWidth: Double?

    var body: some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width
                        startWidth = start
                        width = min(440, max(200, start + value.translation.width))
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .offset(x: 4)
    }
}

/// The rounded "card" holding the active web page.
private struct ContentArea: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        ZStack(alignment: .top) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            if let tab = store.activeTab {
                WebContentView(tab: tab, pool: store.pool)
                LoadingBar(runtime: store.pool.runtime(for: tab.id))
            } else {
                EmptyTabView()
            }
        }
    }
}

private struct LoadingBar: View {
    let runtime: TabRuntime
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            Rectangle()
                .fill(theme.accent)
                .frame(width: proxy.size.width * runtime.progress, height: 2)
                .opacity(runtime.isLoading ? 1 : 0)
                .animation(.easeOut(duration: 0.2), value: runtime.progress)
        }
        .frame(height: 2)
        .padding(.horizontal, 8)
        .allowsHitTesting(false)
    }
}

private struct EmptyTabView: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        VStack(spacing: 12) {
            Text(store.activeSpace.emoji).font(.system(size: 44))
            Text(store.activeSpace.name).font(.title2.weight(.semibold))
            Button("New Tab  ⌘T") { store.openCommandBar(.newTab) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Configures the hosting NSWindow: transparent titlebar, traffic lights hidden with the sidebar.
struct WindowConfigurator: NSViewRepresentable {
    var showsTrafficLights: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = !showsTrafficLights
            }
        }
    }
}
