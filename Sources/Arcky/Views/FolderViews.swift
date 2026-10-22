import SwiftUI

/// One node of the pinned tree, recursing into open folders.
struct SidebarNodeView: View {
    let node: SidebarNode
    let container: TabLocation
    let depth: Int
    @Environment(BrowserStore.self) private var store

    var body: some View {
        switch node {
        case .tab(let tab):
            TabRow(tab: tab, location: container)
                .padding(.leading, indent)
        case .folder(let folder):
            FolderRow(folder: folder, container: container)
                .padding(.leading, indent)
            if folder.isOpen {
                // AnyView breaks the recursive opaque return type.
                AnyView(ForEach(folder.children) { child in
                    SidebarNodeView(node: child, container: .folder(folder.id), depth: depth + 1)
                })
            } else if let active = store.activeTab, folder.allTabs.contains(where: { $0.id == active.id }),
                      let (location, _) = store.location(of: active.id) {
                // Like Arc, a collapsed folder still shows the tab you're on.
                TabRow(tab: active, location: location)
                    .padding(.leading, indent + 14)
            }
        }
    }

    private var indent: CGFloat { CGFloat(depth) * 14 }
}

struct FolderRow: View {
    let folder: Folder
    let container: TabLocation
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme
    @State private var hovering = false
    @State private var dropTargeted = false

    var body: some View {
        let status = LiveFolderService.shared.status[folder.id]
        HStack(spacing: 8) {
            Image(systemName: folder.live?.systemImage ?? (folder.isOpen ? "folder" : "folder.fill"))
                .font(.system(size: 13))
                .frame(width: 16)
                .foregroundStyle(folder.live == nil ? theme.secondaryText : theme.accent)
            if store.renamingID == folder.id {
                InlineRenameField(initial: folder.name) { store.renameFolder(folder.id, to: $0) }
            } else {
                Text(folder.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if status == .refreshing {
                ProgressView().controlSize(.mini)
            } else if case .failed(let message) = status {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help(message)
            }
            if folder.unreadCount > 0 {
                Text("\(folder.unreadCount)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(theme.accent))
                    .help("New since you last looked")
            } else if !folder.isOpen, !folder.children.isEmpty {
                Text("\(folder.allTabs.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(dropTargeted ? theme.selectedFill.opacity(0.7) : (hovering ? theme.hoverFill : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.toggleFolder(folder.id) }
        .draggable(folder.id.uuidString) {
            Label(folder.name, systemImage: "folder").padding(6)
        }
        // Dropping onto a folder puts the item inside it (live folders fill themselves).
        .dropDestination(for: String.self) { items, _ in
            folder.live == nil && dropTabs(items, store: store, to: .folder(folder.id))
        } isTargeted: { dropTargeted = $0 && folder.live == nil }
        .contextMenu {
            Button("Rename…") { store.renamingID = folder.id }
            if folder.live != nil {
                Button("Refresh") { LiveFolderService.shared.refresh(folder.id) }
                if folder.unreadCount > 0 {
                    Button("Mark All as Read") {
                        store.updateFolder(folder.id) { folder in
                            folder.children = folder.children.map { node in
                                guard case .tab(var tab) = node else { return node }
                                tab.isUnread = nil
                                return .tab(tab)
                            }
                        }
                    }
                }
                if case .updated(let date) = status {
                    Text("Updated \(date.formatted(.relative(presentation: .named)))")
                }
            } else {
                Button("New Nested Folder") { store.newFolder(in: .folder(folder.id)) }
            }
            Divider()
            Button("Ungroup") { store.ungroupFolder(folder.id) }
            Button("Delete Folder", role: .destructive) { store.deleteFolder(folder.id) }
        }
    }
}

/// A text field that edits a tab or folder name in place. Return commits, Escape cancels.
struct InlineRenameField: View {
    let initial: String
    let onCommit: (String) -> Void
    @Environment(BrowserStore.self) private var store
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .focused($focused)
            .onAppear {
                text = initial
                focused = true
            }
            .onSubmit(commit)
            .onExitCommand { store.renamingID = nil }
            .onChange(of: focused) {
                if !focused, store.renamingID != nil { commit() }
            }
    }

    private func commit() {
        onCommit(text)
        store.renamingID = nil
    }
}
