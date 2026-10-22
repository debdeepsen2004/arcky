import SwiftUI

/// Wraps an ID so optional IDs can drive `.sheet(item:)`.
struct IdentifiedID: Identifiable {
    let id: UUID
}

/// Arc's space theme editor: up to three gradient colours, intensity, grain and light/dark.
/// Changes apply live.
struct ThemeEditorView: View {
    let spaceID: UUID
    @Environment(BrowserStore.self) private var store
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    private static let presets: [[ThemeColor]] = [
        [ThemeColor(hue: 0.60, saturation: 0.55, brightness: 0.95)],
        [ThemeColor(hue: 0.95, saturation: 0.50, brightness: 0.95)],
        [ThemeColor(hue: 0.38, saturation: 0.45, brightness: 0.85)],
        [ThemeColor(hue: 0.08, saturation: 0.60, brightness: 0.98)],
        [ThemeColor(hue: 0.75, saturation: 0.45, brightness: 0.92), ThemeColor(hue: 0.92, saturation: 0.45, brightness: 0.95)],
        [ThemeColor(hue: 0.55, saturation: 0.60, brightness: 0.90), ThemeColor(hue: 0.40, saturation: 0.50, brightness: 0.88)],
        [ThemeColor(hue: 0.02, saturation: 0.55, brightness: 0.98), ThemeColor(hue: 0.12, saturation: 0.65, brightness: 0.98), ThemeColor(hue: 0.95, saturation: 0.45, brightness: 0.90)],
        [ThemeColor(red: 0.55, green: 0.55, blue: 0.58)],
    ]

    var body: some View {
        if let space = store.spaces.first(where: { $0.id == spaceID }) {
            let style = space.style ?? SpaceStyle(colors: [ThemeColor(hue: space.hue, saturation: 0.55, brightness: 0.95)])
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("\(space.emoji) \(space.name) Theme").font(.title3.weight(.semibold))
                    Spacer()
                    Button("Reset") { store.setStyle(nil, forSpace: spaceID) }
                        .disabled(space.style == nil)
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }

                preview(for: space)

                HStack(spacing: 8) {
                    ForEach(Self.presets.indices, id: \.self) { i in
                        let colors = Self.presets[i]
                        Button { update(space) { $0.colors = colors } } label: {
                            Circle()
                                .fill(LinearGradient(colors: colors.map(\.color) + (colors.count == 1 ? [colors[0].color] : []),
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 28, height: 28)
                                .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Form {
                    LabeledContent("Colors") {
                        HStack(spacing: 10) {
                            ForEach(style.colors.indices, id: \.self) { i in
                                ColorPicker("Color \(i + 1)", selection: Binding(
                                    get: { style.colors[i].color },
                                    set: { newValue in update(space) { if $0.colors.indices.contains(i) { $0.colors[i] = ThemeColor(newValue) } } }
                                ), supportsOpacity: false)
                                .labelsHidden()
                            }
                            if style.colors.count < SpaceStyle.maxColors {
                                Button { update(space) { $0.colors.append($0.colors.last!.mixed(with: .white, 0.3)) } } label: {
                                    Image(systemName: "plus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Add a color")
                            }
                            if style.colors.count > 1 {
                                Button { update(space) { $0.colors.removeLast() } } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove the last color")
                            }
                        }
                    }
                    Slider(value: Binding(get: { style.intensity }, set: { v in update(space) { $0.intensity = v } }), in: 0...1) {
                        Text("Intensity")
                    }
                    Slider(value: Binding(get: { style.grain }, set: { v in update(space) { $0.grain = v } }), in: 0...1) {
                        Text("Grain")
                    }
                    Picker("Appearance", selection: Binding(get: { style.appearance }, set: { v in update(space) { $0.appearance = v } })) {
                        ForEach(ThemeAppearance.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
            }
            .padding(20)
            .frame(width: 460)
        }
    }

    private func preview(for space: Space) -> some View {
        let theme = SpaceTheme(space: space, systemDark: colorScheme == .dark)
        return ZStack(alignment: .leading) {
            theme.background
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<4) { i in
                        RoundedRectangle(cornerRadius: 5)
                            .fill(i == 1 ? theme.selectedFill : theme.tileFill)
                            .frame(height: 14)
                    }
                    Spacer()
                }
                .frame(width: 90)
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor))
            }
            .padding(10)
        }
        .frame(height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.primary.opacity(0.1)))
    }

    /// Edits the space's custom theme, creating one from its hue the first time.
    private func update(_ space: Space, _ body: (inout SpaceStyle) -> Void) {
        var style = space.style ?? SpaceStyle(colors: [ThemeColor(hue: space.hue, saturation: 0.55, brightness: 0.95)])
        body(&style)
        store.setStyle(style, forSpace: space.id)
    }
}
