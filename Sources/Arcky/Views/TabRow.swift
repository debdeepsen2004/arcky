import AppKit
import SwiftUI

struct TabRow: View {
    let tab: BrowserTab
    let location: TabLocation
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme
    @State private var hovering = false

    var body: some View {
        let selected = store.activeTabID == tab.id
        HStack(spacing: 8) {
            Favicon(tab: tab, size: 16)
            if store.renamingID == tab.id {
                InlineRenameField(initial: tab.displayTitle) { store.renameTab(tab.id, to: $0) }
            } else {
                Text(tab.displayTitle)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
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
                .fill(selected ? theme.selectedFill : (hovering ? theme.hoverFill : .clear))
                .shadow(color: .black.opacity(selected ? 0.1 : 0), radius: 2, y: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.select(tab.id) }
        .draggable(tab.id.uuidString) {
            Label(tab.displayTitle, systemImage: "globe").padding(6)
        }
        .dropDestination(for: String.self) { items, _ in
            dropTabs(items, store: store, to: location, before: tab.id)
        }
        .contextMenu { TabContextMenu(tab: tab, location: location) }
    }

    private var isPinned: Bool { !location.isToday }
}

struct TabContextMenu: View {
    let tab: BrowserTab
    let location: TabLocation
    @Environment(BrowserStore.self) private var store

    var body: some View {
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
        if location != .favorites {
            Button("Add to New Folder") {
                let container = location.acceptsFolders ? location : .pinned(store.spaceID(of: location) ?? store.activeSpaceID)
                store.newFolder(in: container, containing: [tab.id])
            }
        }
        if store.spaces.count > 1, location != .favorites {
            Menu("Move to Space") {
                ForEach(store.spaces.filter { $0.id != store.activeSpaceID }) { space in
                    Button("\(space.emoji) \(space.name)") {
                        store.move(tab.id, to: .today(space.id), before: space.today.first?.id)
                    }
                }
            }
        }
        Button("Duplicate") { store.duplicate(tab.id) }
        Divider()
        Button("Close Tab") { store.close(tab.id) }
    }
}

struct Favicon: View {
    let tab: BrowserTab
    let size: CGFloat
    @Environment(\.spaceTheme) private var theme

    var body: some View {
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
