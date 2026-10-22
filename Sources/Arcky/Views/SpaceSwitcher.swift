import SwiftUI

/// Bottom-of-sidebar space icons and "+" button.
struct SpaceSwitcher: View {
    @Environment(BrowserStore.self) private var store
    @Environment(\.spaceTheme) private var theme
    @State private var renaming: Space?
    @State private var draftName = ""

    private static let hues: [(String, Double)] = [
        ("Blue", 0.60), ("Purple", 0.75), ("Pink", 0.95), ("Red", 0.01),
        ("Orange", 0.08), ("Yellow", 0.15), ("Green", 0.38), ("Teal", 0.50),
    ]
    private static let emoji = ["🏠", "💼", "🎨", "📚", "🚀", "🌿", "🎧", "🧪", "🛒", "✈️", "🎮", "💡"]

    var body: some View {
        HStack(spacing: 2) {
            Spacer()
            ForEach(store.spaces) { space in
                let active = space.id == store.activeSpaceID
                Button { store.switchToSpace(space.id) } label: {
                    Text(space.emoji)
                        .font(.system(size: active ? 15 : 13))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(active ? theme.selectedFill : .clear))
                        .opacity(active ? 1 : 0.6)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(space.name)
                .contextMenu { menu(for: space) }
            }
            IconButton(systemName: "plus", help: "New Space") { store.createSpace() }
                .foregroundStyle(theme.secondaryText)
            Spacer()
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
                Button(name) { store.updateSpace(space.id) { $0.hue = hue } }
            }
        }
        Divider()
        Button("Delete Space", role: .destructive) { store.deleteSpace(space.id) }
            .disabled(store.spaces.count == 1)
    }
}
