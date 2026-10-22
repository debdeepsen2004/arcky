import SwiftUI

/// Colours derived from the active space's hue.
struct SpaceTheme {
    var hue: Double
    var dark: Bool

    private func shifted(_ delta: Double) -> Double {
        (hue + delta).truncatingRemainder(dividingBy: 1)
    }

    var background: LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: hue, saturation: dark ? 0.45 : 0.28, brightness: dark ? 0.24 : 0.94),
                Color(hue: shifted(0.04), saturation: dark ? 0.50 : 0.40, brightness: dark ? 0.15 : 0.84),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var selectedFill: Color { dark ? .white.opacity(0.16) : .white.opacity(0.92) }
    var hoverFill: Color { .white.opacity(dark ? 0.08 : 0.35) }
    var tileFill: Color { .white.opacity(dark ? 0.08 : 0.4) }
    var primaryText: Color { dark ? .white.opacity(0.92) : .black.opacity(0.82) }
    var secondaryText: Color { dark ? .white.opacity(0.55) : .black.opacity(0.5) }
    var accent: Color { Color(hue: hue, saturation: 0.65, brightness: dark ? 0.9 : 0.6) }
}

extension EnvironmentValues {
    @Entry var spaceTheme = SpaceTheme(hue: 0.6, dark: false)
}
