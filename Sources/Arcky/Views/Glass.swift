import SwiftUI

// Liquid Glass (macOS 26 and later) for surfaces that float above the page or the sidebar's
// colour, with the materials Arcky used before as the fallback on macOS 15.

enum GlassStyle {
    /// The standard glass: frosted, legible over anything.
    case regular
    /// More see-through, for small controls over the space's own colours.
    case clear
}

extension View {
    /// Puts the view on glass shaped like `shape`. `tint` colours the glass lightly;
    /// `interactive` makes it react to the pointer, for controls.
    @ViewBuilder
    func glassSurface<S: Shape>(
        _ shape: S,
        style: GlassStyle = .regular,
        tint: Color? = nil,
        interactive: Bool = false,
        fallback: some ShapeStyle = .regularMaterial
    ) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(Self.glass(style, tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(fallback, in: shape)
        }
    }

    @available(macOS 26, *)
    private static func glass(_ style: GlassStyle, tint: Color?, interactive: Bool) -> Glass {
        var glass: Glass = style == .clear ? .clear : .regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }

    /// Glass buttons on macOS 26 and later; the default bordered styles before.
    @ViewBuilder
    func glassButtonStyle(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else {
            if prominent {
                self.buttonStyle(.borderedProminent)
            } else {
                self.buttonStyle(.bordered)
            }
        }
    }

    /// Glass for text-heavy panels (command bar, find bar): a mostly opaque backing inside the
    /// glass keeps text readable over busy pages, which glass alone refracts right through.
    func readableGlassSurface<S: Shape>(_ shape: S) -> some View {
        background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: shape)
            .glassSurface(shape, fallback: Color(nsColor: .windowBackgroundColor))
    }

    /// Groups nearby glass shapes so they blend into each other, on macOS 26 and later.
    @ViewBuilder
    func glassGroup(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }
}

