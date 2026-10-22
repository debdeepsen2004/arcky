import AppKit
import SwiftUI

/// Colours for the window chrome, from a space's hue or its custom theme.
struct SpaceTheme {
    var dark: Bool
    /// Background gradient stops, top-leading to bottom-trailing.
    var gradient: [Color]
    var accent: Color
    var grain: Double

    private init(dark: Bool, gradient: [Color], accent: Color, grain: Double) {
        self.dark = dark
        self.gradient = gradient
        self.accent = accent
        self.grain = grain
    }

    /// The simple theme from a hue (spaces without a custom theme).
    init(hue: Double, dark: Bool) {
        let shifted = (hue + 0.04).truncatingRemainder(dividingBy: 1)
        self.init(
            dark: dark,
            gradient: [
                Color(hue: hue, saturation: dark ? 0.45 : 0.28, brightness: dark ? 0.24 : 0.94),
                Color(hue: shifted, saturation: dark ? 0.50 : 0.40, brightness: dark ? 0.15 : 0.84),
            ],
            accent: Color(hue: hue, saturation: 0.65, brightness: dark ? 0.9 : 0.6),
            grain: 0
        )
    }

    /// The theme a space shows, given whether the system is in dark mode.
    init(space: Space, systemDark: Bool) {
        guard let style = space.style, !style.colors.isEmpty else {
            self.init(hue: space.hue, dark: systemDark)
            return
        }
        let dark = switch style.appearance {
        case .auto: systemDark
        case .light: false
        case .dark: true
        }
        // Intensity decides how far the colours pull away from a neutral base.
        let base = dark ? ThemeColor.night : .white
        let strength = dark ? 0.15 + 0.5 * style.intensity : 0.2 + 0.6 * style.intensity
        var stops = style.colors.map { base.mixed(with: $0, strength) }
        if stops.count == 1 {
            // A single colour still gets a gentle gradient towards a deeper shade.
            stops.append(stops[0].mixed(with: dark ? .night : style.colors[0], 0.25))
        }
        let first = style.colors[0]
        self.init(
            dark: dark,
            gradient: stops.map(\.color),
            accent: (dark ? first.mixed(with: .white, 0.25) : first.mixed(with: .night, 0.2)).color,
            grain: style.grain
        )
    }

    var background: some View {
        LinearGradient(colors: gradient, startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                if grain > 0 {
                    // Overlay blending leaves mid-grey neutral, so grain adds texture without
                    // darkening or washing out the colours.
                    Image(nsImage: NoiseTexture.image)
                        .resizable(resizingMode: .tile)
                        .opacity(grain * 0.6)
                        .blendMode(.overlay)
                        .allowsHitTesting(false)
                }
            }
    }

    var selectedFill: Color { dark ? .white.opacity(0.16) : .white.opacity(0.92) }
    var hoverFill: Color { .white.opacity(dark ? 0.08 : 0.35) }
    var tileFill: Color { .white.opacity(dark ? 0.08 : 0.4) }
    var primaryText: Color { dark ? .white.opacity(0.92) : .black.opacity(0.82) }
    var secondaryText: Color { dark ? .white.opacity(0.55) : .black.opacity(0.5) }
}

/// A small tile of grey noise for the grain effect, made once.
enum NoiseTexture {
    static let image: NSImage = {
        let size = 128
        var generator = SystemRandomNumberGenerator()
        var pixels = [UInt8](repeating: 0, count: size * size)
        for i in pixels.indices {
            // Centre the noise on mid-grey with a modest spread.
            pixels[i] = UInt8(clamping: 128 + Int(UInt8.random(in: 0...90, using: &generator)) - 45)
        }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
            samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
            bytesPerRow: size, bitsPerPixel: 8
        )!
        pixels.withUnsafeBufferPointer { buffer in
            rep.bitmapData!.update(from: buffer.baseAddress!, count: buffer.count)
        }
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }()
}

extension EnvironmentValues {
    @Entry var spaceTheme = SpaceTheme(hue: 0.6, dark: false)
}
