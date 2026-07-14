import SwiftUI
import AppKit

// Overture's own brand: deep forest green field, warm gold signal, warm paper.
// Drawn from the app icon (gold paper plane circling a glowing O on forest green).
// Mirrors Downbeat's token discipline (one definitions file, no ad-hoc values) but
// NOT its achromatic palette: Overture keeps its colour identity.

enum OVColor {
    // Surfaces
    static let canvas = dynamic(
        light: NSColor(srgbRed: 0.957, green: 0.945, blue: 0.910, alpha: 1),
        dark: NSColor(srgbRed: 0.055, green: 0.094, blue: 0.071, alpha: 1)
    )
    static let surface = dynamic(
        light: NSColor(srgbRed: 0.984, green: 0.976, blue: 0.953, alpha: 1),
        dark: NSColor(srgbRed: 0.082, green: 0.137, blue: 0.102, alpha: 1)
    )
    static let surfaceSunk = dynamic(
        light: NSColor(srgbRed: 0.929, green: 0.914, blue: 0.875, alpha: 1),
        dark: NSColor(srgbRed: 0.063, green: 0.110, blue: 0.082, alpha: 1)
    )

    // Forest-green ink
    static let ink = dynamic(
        light: NSColor(srgbRed: 0.114, green: 0.204, blue: 0.149, alpha: 1),
        dark: NSColor(srgbRed: 0.910, green: 0.902, blue: 0.847, alpha: 1)
    )
    static let inkSoft = dynamic(
        light: NSColor(srgbRed: 0.298, green: 0.357, blue: 0.318, alpha: 1),
        dark: NSColor(srgbRed: 0.702, green: 0.722, blue: 0.667, alpha: 1)
    )
    static let inkFaint = dynamic(
        light: NSColor(srgbRed: 0.467, green: 0.498, blue: 0.467, alpha: 1),
        dark: NSColor(srgbRed: 0.522, green: 0.553, blue: 0.510, alpha: 1)
    )

    static let forest = dynamic(
        light: NSColor(srgbRed: 0.180, green: 0.322, blue: 0.224, alpha: 1),
        dark: NSColor(srgbRed: 0.220, green: 0.388, blue: 0.275, alpha: 1)
    )

    // Warm gold accent (the single signal colour)
    static let gold = dynamic(
        light: NSColor(srgbRed: 0.706, green: 0.510, blue: 0.118, alpha: 1),
        dark: NSColor(srgbRed: 0.831, green: 0.643, blue: 0.282, alpha: 1)
    )
    static let goldBright = Color(.sRGB, red: 0.870, green: 0.690, blue: 0.310, opacity: 1)

    static let line = dynamic(
        light: NSColor(srgbRed: 0.882, green: 0.863, blue: 0.812, alpha: 1),
        dark: NSColor(srgbRed: 0.176, green: 0.243, blue: 0.196, alpha: 1)
    )
    static let lineStrong = dynamic(
        light: NSColor(srgbRed: 0.792, green: 0.776, blue: 0.722, alpha: 1),
        dark: NSColor(srgbRed: 0.255, green: 0.333, blue: 0.275, alpha: 1)
    )

    // Imminent-timing warning (warm rust, not alarm red)
    static let rust = dynamic(
        light: NSColor(srgbRed: 0.604, green: 0.286, blue: 0.180, alpha: 1),
        dark: NSColor(srgbRed: 0.776, green: 0.439, blue: 0.318, alpha: 1)
    )

    static let onForest = Color.white.opacity(0.96)
    // #901: text on a filled rust badge. Rust is a dark brick in light mode and a lighter terracotta in
    // dark; white reads on both, where `canvas` would go near-black on the dark-mode fill.
    static let onRust = Color.white.opacity(0.96)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark ? dark : light
        }))
    }
}

enum OVSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let hero: CGFloat = 64
}

// System serif (New York) for the editorial personality; no bundled font yet.
enum OVType {
    static let wordmark = Font.system(size: 30, weight: .semibold, design: .serif)
    static let dateHeading = Font.system(size: 19, weight: .medium, design: .serif)
    static let groupName = Font.system(size: 21, weight: .medium, design: .serif)
    static let fitNumber = Font.system(size: 27, weight: .regular, design: .serif)
    static let reason = Font.system(size: 15, weight: .regular, design: .serif).italic()
    static let body = Font.system(size: 13, weight: .regular)
    static let meta = Font.system(size: 11, weight: .semibold)
    static let tag = Font.system(size: 11, weight: .medium)
}
