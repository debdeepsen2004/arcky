import AppKit
import SwiftUI

struct SidebarView: View {
    static let horizontalPadding: CGFloat = 10
    static let topBarHeight: CGFloat = 28

    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SidebarTopBar()
            AddressPill()
            if !store.favorites.isEmpty {
                FavoritesGrid()
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SpaceHeader(space: store.activeSpace)
                    PinnedSection(space: store.activeSpace)
                    TodayDivider(space: store.activeSpace)
                    NewTabRow()
                    ForEach(store.activeSpace.today) { tab in
                        TabRow(tab: tab, location: .today(store.activeSpaceID))
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.never)
            .offset(x: store.swipeOffset)
            .id(store.activeSpaceID)
            // Slides in from the side being moved towards, like flipping between pages.
            .transition(.asymmetric(
                insertion: .move(edge: store.spaceSwitchForward ? .trailing : .leading).combined(with: .opacity),
                removal: .move(edge: store.spaceSwitchForward ? .leading : .trailing).combined(with: .opacity)
            ))
            .clipped()
            SpaceSwitcher()
        }
        .background(SidebarFrameReporter())
        .padding(.horizontal, SidebarView.horizontalPadding)
        // The top row's middle sits level with the traffic lights.
        .padding(.top, max(4, WindowChrome.shared.trafficLightsCenterY - SidebarView.topBarHeight / 2))
        .padding(.bottom, 10)
        .foregroundStyle(theme.primaryText)
    }
}

/// Traffic-light row with sidebar toggle and navigation buttons. Dragging it moves the window.
private struct SidebarTopBar: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        let runtime = store.activeTabID.map { store.pool.runtime(for: $0) }
        let webView = store.pool.existingWebView(for: store.activeTabID)
        HStack(spacing: 4) {
            // Clear of the traffic lights, whatever their size on this macOS version.
            Spacer().frame(width: max(0, WindowChrome.shared.trafficLightsMaxX - SidebarView.horizontalPadding + 8))
            IconButton(systemName: "sidebar.left", help: "Hide Sidebar (⌘S)") { store.toggleSidebar() }
            Spacer()
            IconButton(systemName: "arrow.left", help: "Back (⌘[)") { webView?.goBack() }
                .disabled(!(runtime?.canGoBack ?? false))
            IconButton(systemName: "arrow.right", help: "Forward (⌘])") { webView?.goForward() }
                .disabled(!(runtime?.canGoForward ?? false))
            if runtime?.isLoading == true {
                IconButton(systemName: "xmark", help: "Stop") { webView?.stopLoading() }
            } else {
                IconButton(systemName: "arrow.clockwise", help: "Reload (⌘R)") { webView?.reload() }
                    .disabled(webView == nil)
            }
        }
        .frame(height: SidebarView.topBarHeight)
        .background(Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture()))
        .foregroundStyle(theme.secondaryText)
    }
}

struct IconButton: View {
    let systemName: String
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.spaceTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 28, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(hovering && isEnabled ? theme.hoverFill : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Arc's URL field: shows the host, opens the command bar on click.
private struct AddressPill: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme
    @State private var hovering = false

    var body: some View {
        let document = ArckyDocument(url: store.activeTab?.url)
        let host = document == nil ? store.activeTab?.url?.host()?.strippingWWW : nil
        HStack(spacing: 6) {
            if let document {
                Image(systemName: document.systemImage).font(.system(size: 11)).foregroundStyle(theme.secondaryText)
            } else if store.activeTab?.url?.scheme == "https" {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(theme.secondaryText)
            }
            Text(document?.kindName ?? host ?? "Search or Enter URL…")
                .font(.system(size: 13))
                .foregroundStyle(host == nil && document == nil ? theme.secondaryText : theme.primaryText)
                .lineLimit(1)
            Spacer()
            if host != nil, store.contentBlocking {
                let blocking = store.isBlocking(onHost: store.activeHost)
                Button { store.toggleBlockingForActiveSite() } label: {
                    Image(systemName: blocking ? "shield.lefthalf.filled" : "shield.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.secondaryText)
                }
                .buttonStyle(.plain)
                .opacity(hovering || !blocking ? 1 : 0)
                .help(blocking ? "Ads and trackers blocked. Click to allow on this site" : "Blocking is off for this site. Click to turn it on")
            }
            if host != nil {
                // Arc's Boost bolt: filled when this site has an enabled Boost.
                let boost = store.boost(forHost: store.activeHost)
                Button { store.editBoostForActiveSite() } label: {
                    Image(systemName: boost?.isEnabled == true ? "bolt.fill" : "bolt")
                        .font(.system(size: 11))
                        .foregroundStyle(boost?.isEnabled == true ? Color.pink : theme.secondaryText)
                }
                .buttonStyle(.plain)
                .opacity(hovering || boost != nil ? 1 : 0)
                .help(boost == nil ? "Boost This Site" : "Edit Boost")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .glassSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), style: .clear, interactive: true,
                      fallback: hovering ? theme.selectedFill.opacity(0.8) : theme.tileFill)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.openCommandBar(.editCurrent) }
    }
}

private struct FavoritesGrid: View {
    @Environment(BrowserStore.self) private var store

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(store.favorites) { tab in
                FavoriteTile(tab: tab)
            }
        }
    }
}

private struct FavoriteTile: View {
    let tab: BrowserTab
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme
    @State private var hovering = false

    var body: some View {
        let selected = store.activeTabID == tab.id
        Favicon(tab: tab, size: 20)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background {
                // The open favorite is a solid tile; the rest are glass over the space's colour.
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(theme.selectedFill)
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                }
            }
            .glassSurface(RoundedRectangle(cornerRadius: 12, style: .continuous), style: .clear, interactive: true,
                          fallback: selected ? Color.clear : (hovering ? theme.selectedFill.opacity(0.6) : theme.tileFill))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture { store.handleClick(on: tab.id, modifiers: currentClickModifiers()) }
            .help(tab.displayTitle)
            .draggable(dragPayload(for: tab.id, store: store))
            .dropDestination(for: String.self) { items, _ in
                dropTabs(items, store: store, to: .favorites(store.activeProfileID), before: tab.id)
            }
            .contextMenu { TabContextMenu(tab: tab, location: .favorites(store.activeProfileID)) }
    }
}

/// Space name above the pinned section. Dropping on it pins at the end; hovering shows "New Folder".
private struct SpaceHeader: View {
    let space: Space
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Text(space.emoji)
            Text(space.name).font(.system(size: 12, weight: .semibold))
            if store.profiles.count > 1 {
                let profile = store.profiles.first { $0.id == store.profileID(of: space) }
                Text(profile.map { "\($0.emoji) \($0.name)" } ?? "")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .glassSurface(Capsule(), style: .clear, fallback: theme.tileFill)
                    .help("This space's profile")
            }
            Spacer()
            if hovering {
                Button { store.newFolder(in: .pinned(space.id)) } label: {
                    Image(systemName: "folder.badge.plus").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("New Folder (⌥⌘N)")
            }
        }
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 6)
        .frame(height: 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .dropDestination(for: String.self) { items, _ in
            dropTabs(items, store: store, to: .pinned(space.id))
        }
        .contextMenu {
            Button("New Folder") { store.newFolder(in: .pinned(space.id)) }
        }
    }
}

private struct PinnedSection: View {
    let space: Space
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        if space.pinned.isEmpty {
            Text("Drag tabs here to pin them")
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.secondaryText.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4])))
                .dropDestination(for: String.self) { items, _ in
                    dropTabs(items, store: store, to: .pinned(space.id))
                }
        } else {
            ForEach(space.pinned) { node in
                SidebarNodeView(node: node, container: .pinned(space.id), depth: 0)
            }
        }
    }
}

/// The line between pinned and Today tabs, with Arc's "Clear" button.
private struct TodayDivider: View {
    let space: Space
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(theme.secondaryText.opacity(0.25)).frame(height: 1)
            if !space.today.isEmpty {
                Button { store.clearToday() } label: {
                    Label("Clear", systemImage: "arrow.down")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help("Archive all Today tabs")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 24)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            dropTabs(items, store: store, to: .today(space.id), before: space.today.first?.id)
        }
    }
}

private struct NewTabRow: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 16)
            Text("New Tab").font(.system(size: 13))
            Spacer()
        }
        .foregroundStyle(theme.secondaryText)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? theme.hoverFill : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.openCommandBar(.newTab) }
        .contextMenu {
            Button("New Tab") { store.openCommandBar(.newTab) }
            Button("New Note") { store.newNote() }
            Button("New Easel") { store.newEasel() }
        }
    }
}

/// Handles a sidebar drop of dragged tab IDs.
@MainActor
func dropTabs(_ items: [String], store: BrowserStore, to destination: TabLocation, before beforeID: UUID? = nil) -> Bool {
    // Each item is one ID, or several comma-separated when a selection was dragged.
    let ids = items.flatMap { $0.split(separator: ",") }.compactMap { UUID(uuidString: String($0)) }
    store.moveTabs(ids, to: destination, before: beforeID)
    return !ids.isEmpty
}
