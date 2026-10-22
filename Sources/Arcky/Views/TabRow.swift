import AppKit
import SwiftUI

struct TabRow: View {
    let tab: BrowserTab
    let location: TabLocation
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme
    @State private var hovering = false
    @State private var showingHoverCard = false
    @State private var hoverCardTask: Task<Void, Never>?
    @AppStorage("hoverCards") private var hoverCardsEnabled = true

    var body: some View {
        let selected = store.activeTabID == tab.id
        let multiSelected = store.multiSelection.contains(tab.id)
        HStack(spacing: 8) {
            Favicon(tab: tab, size: 16)
                .overlay(alignment: .topTrailing) {
                    if tab.isUnread == true {
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 7, height: 7)
                            .offset(x: 3, y: -3)
                            .help("New")
                    }
                }
            if store.renamingID == tab.id {
                InlineRenameField(initial: tab.displayTitle) { store.renameTab(tab.id, to: $0) }
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if store.split(containing: tab.id) != nil, !hovering {
                Image(systemName: "rectangle.split.2x1")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.secondaryText)
                    .help("In Split View")
            }
            if hovering {
                Button { store.close(tab.id) } label: {
                    Image(systemName: isPinned ? "minus" : "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryText)
                .help(isPinned ? "Close and keep pinned" : "Close Tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? theme.selectedFill : multiSelected ? theme.selectedFill.opacity(0.55) : (hovering ? theme.hoverFill : .clear))
                .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 2, y: 1)
        )
        .overlay {
            if multiSelected {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.accent.opacity(0.6), lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            hoverCardTask?.cancel()
            if inside {
                hoverCardTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled, hoverCardsEnabled, store.renamingID != tab.id else { return }
                    showingHoverCard = true
                }
            } else {
                showingHoverCard = false
            }
        }
        .popover(isPresented: $showingHoverCard, arrowEdge: .trailing) {
            HoverCard(tab: tab)
        }
        .onTapGesture {
            showingHoverCard = false
            store.handleClick(on: tab.id, modifiers: currentClickModifiers())
        }
        .draggable(dragPayload(for: tab.id, store: store)) {
            let count = store.actionTargets(for: tab.id).count
            Label(count > 1 ? "\(count) tabs" : tab.displayTitle, systemImage: count > 1 ? "square.stack" : "globe").padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            dropTabs(items, store: store, to: location, before: tab.id)
        }
        .contextMenu { TabContextMenu(tab: tab, location: location) }
    }

    private var isPinned: Bool { !location.isToday }
}

/// Dragging a tab that's part of the selection drags the whole selection.
@MainActor
func dragPayload(for id: UUID, store: BrowserStore) -> String {
    store.actionTargets(for: id).map(\.uuidString).joined(separator: ",")
}

struct TabContextMenu: View {
    let tab: BrowserTab
    let location: TabLocation
    @Environment(BrowserStore.self) private var store

    var body: some View {
        let targets = store.actionTargets(for: tab.id)
        if targets.count > 1 {
            MultiTabMenu(ids: targets)
        } else {
            singleTabMenu
        }
    }

    @ViewBuilder private var singleTabMenu: some View {
        Button("Copy Link") {
            guard let url = tab.url else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.absoluteString, forType: .string)
        }
        Button("Rename…") { store.renamingID = tab.id }
        Divider()
        switch location {
        case .today:
            Button("Pin Tab") { store.togglePin(tab.id) }
            Button("Add to Favorites") { store.toggleFavorite(tab.id) }
        case .pinned, .folder:
            Button("Unpin Tab") { store.togglePin(tab.id) }
            Button("Add to Favorites") { store.toggleFavorite(tab.id) }
        case .favorites:
            Button("Remove from Favorites") { store.toggleFavorite(tab.id) }
        }
        if !location.isFavorites {
            Button("Add to New Folder") {
                let container = location.acceptsFolders ? location : .pinned(store.spaceID(of: location) ?? store.activeSpaceID)
                store.newFolder(in: container, containing: [tab.id])
            }
        }
        if store.spaces.count > 1, !location.isFavorites {
            Menu("Move to Space") {
                ForEach(store.spaces.filter { $0.id != store.activeSpaceID }) { space in
                    Button("\(space.emoji) \(space.name)") {
                        store.move(tab.id, to: .today(space.id), before: space.today.first?.id)
                    }
                }
            }
        }
        if store.split(containing: tab.id) != nil {
            Button("Remove from Split View") { store.removeFromSplit(tab.id) }
        } else if store.activeTabID != nil, store.activeTabID != tab.id {
            Button("Open in Split View") { store.splitWithActive(tab.id) }
        }
        Button("Duplicate") { store.duplicate(tab.id) }
        Divider()
        Button("Close Tab") { store.close(tab.id) }
    }
}

/// The context menu for several selected tabs.
private struct MultiTabMenu: View {
    let ids: [UUID]
    @Environment(BrowserStore.self) private var store

    var body: some View {
        Text("\(ids.count) Tabs")
        Button("Copy Links") {
            let links = ids.compactMap { store.tab($0)?.url?.absoluteString }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
        }
        Divider()
        let anyToday = ids.contains { store.location(of: $0)?.0.isToday == true }
        Button(anyToday ? "Pin Tabs" : "Unpin Tabs") { store.togglePinTabs(ids) }
        Button("New Folder from Selection") { store.newFolder(containing: ids) }
        if ids.count <= TabSplit.maxPanes {
            Button("Open in Split View") { store.splitTabs(ids) }
        }
        if store.spaces.count > 1 {
            Menu("Move to Space") {
                ForEach(store.spaces.filter { $0.id != store.activeSpaceID }) { space in
                    Button("\(space.emoji) \(space.name)") {
                        store.moveTabs(ids, to: .today(space.id), before: space.today.first?.id)
                    }
                }
            }
        }
        Divider()
        Button("Close \(ids.count) Tabs") { store.closeTabs(ids) }
    }
}

struct Favicon: View {
    let tab: BrowserTab
    let size: CGFloat
    @Environment(\.spaceTheme) private var theme

    var body: some View {
        if let document = ArckyDocument(url: tab.url) {
            Image(systemName: document.systemImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(theme.accent)
                .frame(width: size, height: size)
        } else {
            webFavicon
        }
    }

    private var webFavicon: some View {
        AsyncImage(url: tab.resolvedFaviconURL) { phase in
            if let image = phase.image {
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "globe")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(theme.secondaryText)
                    .padding(size * 0.06)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2))
    }
}

/// Modifier keys of the click being handled. The click event carries them, which is more
/// reliable than the live keyboard state (a quick ⌘-click can release ⌘ before SwiftUI runs).
@MainActor
func currentClickModifiers() -> NSEvent.ModifierFlags {
    NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
}

/// Arc's hover card: a bigger look at a sidebar tab, with how the page looked when you left it.
private struct HoverCard: View {
    let tab: BrowserTab
    @Environment(BrowserStore.self) private var store
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 300, height: 170, alignment: .top)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            }
            HStack(alignment: .top, spacing: 8) {
                Favicon(tab: tab, size: 18)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab.displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(store.activeTabID == tab.id ? "Open now" : "Viewed \(tab.lastActive.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(12)
        .frame(width: 324, alignment: .leading)
        .task { thumbnail = await store.pool.thumbnail(for: tab.id) }
    }

    private var subtitle: String {
        if let document = ArckyDocument(url: tab.url) { return document.kindName }
        guard let url = tab.url else { return "New Tab" }
        let host = url.host()?.strippingWWW ?? ""
        let path = url.path(percentEncoded: false)
        return path.isEmpty || path == "/" ? host : host + path
    }
}
