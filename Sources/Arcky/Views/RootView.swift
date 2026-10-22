import AppKit
import SwiftUI

struct RootView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let theme = SpaceTheme(hue: store.activeSpace.hue, dark: colorScheme == .dark)
        ZStack {
            theme.background
            HStack(spacing: 0) {
                if store.sidebarVisible {
                    SidebarView()
                        .frame(width: 248)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
                ContentArea()
                    .padding(.vertical, 8)
                    .padding(.trailing, 8)
                    .padding(.leading, store.sidebarVisible ? 0 : 8)
            }
            if let mode = store.commandBar {
                CommandBarView(mode: mode)
            }
        }
        .ignoresSafeArea()
        .environment(\.spaceTheme, theme)
        .animation(.spring(duration: 0.28), value: store.sidebarVisible)
        .animation(.easeInOut(duration: 0.25), value: store.activeSpaceID)
        .background(WindowConfigurator(showsTrafficLights: store.sidebarVisible))
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
