import AppKit
import SwiftUI

struct RootView: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("sidebarWidth") private var sidebarWidth = 248.0
    /// The hidden sidebar is floating over the page because the pointer reached the left edge.
    @State private var peeking = false

    var body: some View {
        let theme = SpaceTheme(space: store.activeSpace, systemDark: colorScheme == .dark)
        ZStack(alignment: .leading) {
            theme.background
            HStack(spacing: 0) {
                if store.sidebarVisible {
                    SidebarView()
                        .environment(\.colorScheme, theme.dark ? .dark : .light)
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
                    // Floating over the page, the sidebar is glass that follows the system's light
                    // or dark appearance, tinted with the space's colour.
                    SidebarView()
                        .environment(\.spaceTheme, theme.appearance(dark: colorScheme == .dark))
                        .environment(\.floatingSidebar, true)
                        .frame(width: sidebarWidth)
                        .floatingSidebarSurface(RoundedRectangle(cornerRadius: 16, style: .continuous), tint: theme.accent)
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
        .onChange(of: peeking) { SpaceSwipeTracker.shared.floatingSidebarShown = peeking }
        // While peeking, the floating sidebar draws its own traffic lights so they move with it.
        .background(WindowConfigurator(showsTrafficLights: store.sidebarVisible))
        .sheet(isPresented: Binding(get: { store.showingArchive }, set: { store.showingArchive = $0 })) {
            ArchiveView().environment(store)
        }
        .sheet(isPresented: Binding(get: { store.showingHistory }, set: { store.showingHistory = $0 })) {
            ArchiveView(kind: .history).environment(store)
        }
        .sheet(item: Binding(get: { store.editingThemeSpaceID.map(IdentifiedID.init) }, set: { store.editingThemeSpaceID = $0?.id })) { item in
            ThemeEditorView(spaceID: item.id).environment(store)
        }
        .sheet(isPresented: Binding(get: { store.showingOnboarding }, set: { store.showingOnboarding = $0 })) {
            OnboardingView().environment(store)
        }
        .sheet(isPresented: Binding(get: { store.showingImport }, set: { store.showingImport = $0 })) {
            ImportView().environment(store)
        }
        .sheet(isPresented: Binding(get: { store.showingNewLiveFolder }, set: { store.showingNewLiveFolder = $0 })) {
            NewLiveFolderView().environment(store)
        }
        .sheet(item: Binding(get: { store.editingBoostID.map(IdentifiedID.init) }, set: { store.editingBoostID = $0?.id })) { item in
            BoostEditorView(boostID: item.id).environment(store)
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

/// The page area: one rounded card, or a Split View of several, plus find bar and Peek overlays.
private struct ContentArea: View {
    @Environment(BrowserStore.self) private var store

    var body: some View {
        ZStack(alignment: .top) {
            if let tab = store.activeTab {
                if let split = store.split(containing: tab.id) {
                    SplitContent(split: split)
                } else {
                    WebPane(tab: tab, focused: true, showsFocusRing: false)
                }
            } else {
                PaneBackground()
                EmptyTabView()
            }
            if store.findBarVisible {
                FindBar()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let id = store.peekTabID, let tab = store.transientTabs[id] {
                // Removal is instant so "Open as Tab" hands the page straight to the main pane.
                PeekView(tab: tab)
                    .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .identity))
            }
        }
        .animation(.spring(duration: 0.25), value: store.peekTabID)
        .animation(.easeOut(duration: 0.15), value: store.findBarVisible)
    }
}

private struct PaneBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .windowBackgroundColor))
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }
}

/// One page card. In a split, the focused pane gets an accent ring.
private struct WebPane: View {
    let tab: BrowserTab
    let focused: Bool
    let showsFocusRing: Bool
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        ZStack(alignment: .top) {
            PaneBackground()
            switch ArckyDocument(url: tab.url) {
            case .note(let id):
                NoteView(noteID: id)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .id(id)
            case .easel(let id):
                EaselView(easelID: id)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .id(id)
            case nil:
                WebContentView(tab: tab, pool: store.pool, takesFocus: focused)
            }
            LoadingBar(runtime: store.pool.runtime(for: tab.id))
        }
        .overlay {
            if showsFocusRing && focused {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.accent, lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Split View panes with draggable dividers. Clicking a pane focuses it (see AppDelegate).
private struct SplitContent: View {
    let split: TabSplit
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let panes = ForEach(split.tabIDs.compactMap { store.tab($0) }) { tab in
            WebPane(tab: tab, focused: tab.id == store.activeTabID, showsFocusRing: true)
                .padding(3)
        }
        if split.vertical {
            VSplitView { panes }
        } else {
            HSplitView { panes }
        }
    }
}

/// Arc's Peek: a page floating over the current one, which can be closed or kept as a tab.
private struct PeekView: View {
    let tab: BrowserTab
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        ZStack {
            Color.black.opacity(0.25)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onTapGesture { store.closePeek() }
            VStack(spacing: 10) {
                // The controls float above the page on their own piece of glass.
                HStack(spacing: 2) {
                    IconButton(systemName: "xmark", help: "Close (Esc)") { store.closePeek() }
                    Text(tab.url?.host()?.strippingWWW ?? tab.displayTitle)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                    IconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Open as Tab") { store.expandPeek() }
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .frame(height: 36)
                .readableGlassSurface(Capsule())
                WebContentView(tab: tab, pool: store.pool, takesFocus: true)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
            }
            .padding(.horizontal, 56)
            .padding(.top, 14)
            .padding(.bottom, 36)
        }
    }
}

/// ⌘F find bar. Return finds the next match; ⌘G / ⇧⌘G step through matches; Esc closes.
private struct FindBar: View {
    @Environment(BrowserStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in page", text: $store.findQuery)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($focused)
                .onSubmit { store.find() }
                .onExitCommand { store.closeFindBar() }
            if let status = store.findStatus {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(status == "Not found" ? .red : .secondary)
                    .fixedSize()
            }
            IconButton(systemName: "chevron.up", help: "Previous (⇧⌘G)") { store.find(backwards: true) }
            IconButton(systemName: "chevron.down", help: "Next (⌘G)") { store.find() }
            IconButton(systemName: "xmark", help: "Close (Esc)") { store.closeFindBar() }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 36)
        // Glass keeps its text legible over any page; before macOS 26 a plain material turned
        // mid-grey over white pages and hid the count, so the fallback is solid.
        .readableGlassSurface(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)
        .fixedSize()
        .onAppear { focused = true }
        .onChange(of: store.findQuery) { store.find() }
        .onChange(of: store.findBarVisible) { if store.findBarVisible { focused = true } }
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
            BrowserStore.shared.mainWindow = window
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(kind)?.isHidden = !showsTrafficLights
            }
            WindowChrome.shared.measure(window)
        }
    }
}

/// Where the window's traffic lights really are. Their size and position differ between
/// macOS versions, so the sidebar's top row lines up with them by measurement, not constants.
@MainActor @Observable
final class WindowChrome {
    static let shared = WindowChrome()

    /// From the window's top edge to the middle of the traffic lights.
    private(set) var trafficLightsCenterY: CGFloat = 22
    /// From the window's left edge to the right edge of the zoom (green) button.
    private(set) var trafficLightsMaxX: CGFloat = 70
    /// From the window's left edge to the left edge of the close (red) button.
    private(set) var trafficLightsMinX: CGFloat = 20
    /// One button's size, and the distance from one button's left edge to the next.
    private(set) var trafficLightSize: CGSize = CGSize(width: 14, height: 16)
    private(set) var trafficLightPitch: CGFloat = 20

    func measure(_ window: NSWindow) {
        guard let content = window.contentView,
              let close = window.standardWindowButton(.closeButton),
              let zoom = window.standardWindowButton(.zoomButton) else { return }
        let closeRect = close.convert(close.bounds, to: content)
        let zoomRect = zoom.convert(zoom.bounds, to: content)
        let pitch = (zoomRect.minX - closeRect.minX) / 2
        let centerY = content.isFlipped ? closeRect.midY : content.bounds.height - closeRect.midY
        // Only publish real changes, so measuring during a view update doesn't loop.
        if abs(centerY - trafficLightsCenterY) > 0.5 { trafficLightsCenterY = centerY }
        if abs(zoomRect.maxX - trafficLightsMaxX) > 0.5 { trafficLightsMaxX = zoomRect.maxX }
        if abs(closeRect.minX - trafficLightsMinX) > 0.5 { trafficLightsMinX = closeRect.minX }
        if closeRect.size != trafficLightSize { trafficLightSize = closeRect.size }
        if abs(pitch - trafficLightPitch) > 0.5 { trafficLightPitch = pitch }
    }
}
