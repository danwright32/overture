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

    // #1583: gold as TEXT on a card, which is a different question from gold as a FILL and had never been
    // asked. Every gold surface in this app until now was a capsule with dark ink drawn ON it, and a fill
    // carries no contrast bar of its own; only its label does. When #1583 retired the clash pill, the
    // sentence beneath it became the only thing carrying the clash, and plain `gold` as text measured 3.24
    // to 1 on the light-theme card, well under the 4.5 to 1 that text this size needs.
    //
    // Darkened in the LIGHT theme only, which is the half that failed: the dark theme's gold already
    // measures 7.15 to 1 on the dark card, and lifting it there would only make it glare. Deliberately not
    // `goldDim`, whose value would pass at 4.84: that token means a specific thing (#1628, found something
    // but could not stand behind it), and borrowing it for readability would leave the next person changing
    // one meaning and silently moving the other. `ConflictNoteColourTests` measures both themes.
    static let goldText = dynamic(
        light: NSColor(srgbRed: 0.533, green: 0.384, blue: 0.086, alpha: 1),
        dark: NSColor(srgbRed: 0.831, green: 0.643, blue: 0.282, alpha: 1)
    )

    // #1628: gold at lower intensity, for a state that found something but could not stand behind it.
    // Deliberately the SAME hue as `gold` rather than a new colour: it has to read as a dimmer member of
    // the found-something family, not as a fourth signal. Dan arrived at needing this after seeing the
    // alternative, rust, and saying "unverified email looks like no email, too similar".
    static let goldDim = dynamic(
        light: NSColor(srgbRed: 0.560, green: 0.404, blue: 0.094, alpha: 1),
        dark: NSColor(srgbRed: 0.659, green: 0.510, blue: 0.227, alpha: 1)
    )

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

    // #1527: the label on a filled WARM badge (rust or gold). Both fills are light enough in dark mode that
    // white text washes out on them, so the dark theme puts a near-black warm ink on the fill instead. The
    // one value, shared, because a second copy of "the dark text that goes on a warm capsule" would drift.
    private static let warmFillInk = NSColor(srgbRed: 0.102, green: 0.071, blue: 0.008, alpha: 1)

    // #901: text on a filled rust badge. #1527 split it by theme. The original note here read "white reads
    // on both", which was a by-eye call and measured 3.45 to 1 against the dark-mode terracotta, under the
    // 4.5 to 1 that 11pt semibold needs. Light mode keeps white (5.89 to 1 on the darker brick); dark mode
    // takes the warm ink (5.15 to 1). `ConflictPillColourTests` measures both, so this cannot silently
    // regress to a single value again.
    static let onRust = dynamic(
        light: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96),
        dark: warmFillInk
    )

    // #1527 added an `onGold` here, for text on a filled gold badge, which the "Partly booked" pill needed
    // and no token provided. #1583 retired that pill (Keep is the acceptance now, so the badge had nothing
    // left to do), and nothing else in the app draws text on a gold fill, so the token went with it rather
    // than resting unused waiting to be picked "by eye" for something it was not measured against.

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            OVAppearanceDarkness.shared.isDark(appearance) ? dark : light
        }))
    }
}

/// Memoizes the light/dark decision for an `NSAppearance` so a dynamic colour's provider closure does not
/// re-run `bestMatch(from:)` on every resolution (#1444). The decision depends only on the appearance's
/// name, which is stable, so the match runs once per distinct appearance and is reused for every colour on
/// every subsequent redraw. Callers hit `shared`; the initializer is left open only so tests can inject a
/// countable matcher. `@unchecked Sendable`: the dynamic-provider closure is `@Sendable` and AppKit may
/// resolve a colour off the main thread, so the cache is guarded by a lock rather than actor isolation.
final class OVAppearanceDarkness: @unchecked Sendable {
    private let lock = NSLock()
    private var byName: [NSAppearance.Name: Bool] = [:]
    private let match: (NSAppearance) -> Bool

    init(match: @escaping (NSAppearance) -> Bool = { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
    }) {
        self.match = match
    }

    func isDark(_ appearance: NSAppearance) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let cached = byName[appearance.name] { return cached }
        let resolved = match(appearance)
        byName[appearance.name] = resolved
        return resolved
    }

    static let shared = OVAppearanceDarkness()
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
