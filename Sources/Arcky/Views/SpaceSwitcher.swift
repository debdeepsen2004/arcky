import SwiftUI

/// Bottom-of-sidebar space icons and "+" button.
struct SpaceSwitcher: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme
    @State private var renaming: Space?
    /// The space icon a dragged tab is over.
    @State private var dropTargetSpace: UUID?
    @State private var hoverSwitch: Task<Void, Never>?
    @State private var draftName = ""

    private static let hues: [(String, Double)] = [
        ("Blue", 0.60), ("Purple", 0.75), ("Pink", 0.95), ("Red", 0.01),
        ("Orange", 0.08), ("Yellow", 0.15), ("Green", 0.38), ("Teal", 0.50),
    ]
    private static let emoji = ["🏠", "💼", "🎨", "📚", "🚀", "🌿", "🎧", "🧪", "🛒", "✈️", "🎮", "💡"]

    var body: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "archivebox", help: "Archive") { store.showingArchive = true }
                .foregroundStyle(theme.secondaryText)
            DownloadsButton()
            // Centred when they fit; scrollable when there are too many spaces for the sidebar.
            ViewThatFits(in: .horizontal) {
                spaceIcons
                ScrollView(.horizontal) { spaceIcons }
                    .scrollIndicators(.never)
            }
            .frame(maxWidth: .infinity)
            IconButton(systemName: "plus", help: "New Space") { store.createSpace() }
                .foregroundStyle(theme.secondaryText)
        }
        .frame(height: 30)
        .alert("Rename Space", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $draftName)
            Button("Rename") {
                if let space = renaming { store.updateSpace(space.id) { $0.name = draftName } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var spaceIcons: some View {
        HStack(spacing: 2) {
            ForEach(store.spaces) { space in
                let active = space.id == store.activeSpaceID
                let targeted = dropTargetSpace == space.id
                Button { store.switchToSpace(space.id) } label: {
                    Text(space.emoji)
                        .font(.system(size: active || targeted ? 15 : 13))
                        .frame(width: 26, height: 26)
                        .background {
                            if active || targeted {
                                Circle().fill(.clear).glassSurface(Circle(), style: .clear, fallback: theme.selectedFill)
                            }
                        }
                        .overlay { if targeted { Circle().strokeBorder(theme.accent, lineWidth: 1.5) } }
                        .opacity(active || targeted ? 1 : 0.6)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(space.name)
                .contextMenu { menu(for: space) }
                // Dropping tabs on a space moves them to the top of its Today list. Holding
                // them over it for a moment switches to it, so they can be dropped precisely.
                .dropDestination(for: String.self) { items, _ in
                    dropTargetSpace = nil
                    return dropTabs(items, store: store, to: .today(space.id), before: space.today.first?.id)
                } isTargeted: { isTargeted in
                    hoverSwitch?.cancel()
                    dropTargetSpace = isTargeted ? space.id : (dropTargetSpace == space.id ? nil : dropTargetSpace)
                    guard isTargeted, !active else { return }
                    hoverSwitch = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        guard !Task.isCancelled else { return }
                        store.switchToSpace(space.id)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func menu(for space: Space) -> some View {
        Button("Rename…") {
            draftName = space.name
            renaming = space
        }
        Menu("Icon") {
            ForEach(Self.emoji, id: \.self) { emoji in
                Button(emoji) { store.updateSpace(space.id) { $0.emoji = emoji } }
            }
        }
        Menu("Color") {
            ForEach(Self.hues, id: \.0) { name, hue in
                Button(name) {
                    store.updateSpace(space.id) {
                        $0.hue = hue
                        $0.style = nil
                    }
                }
            }
        }
        Button("Edit Theme…") { store.editTheme(of: space.id) }
        Menu("Profile") {
            ForEach(store.profiles) { profile in
                Toggle("\(profile.emoji) \(profile.name)", isOn: Binding(
                    get: { store.profileID(of: space) == profile.id },
                    set: { if $0 { store.setProfile(profile.id, forSpace: space.id) } }
                ))
            }
            Divider()
            Button("New Profile") {
                let profile = store.createProfile()
                store.setProfile(profile.id, forSpace: space.id)
            }
        }
        Divider()
        Button("Delete Space", role: .destructive) { store.deleteSpace(space.id) }
            .disabled(store.spaces.count == 1)
    }
}
