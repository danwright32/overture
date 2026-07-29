import Testing
import SwiftUI
import AppKit
@testable import Overture

// #1527: #1501/#1522 changed the conflict pill's WORDS but deliberately not its colour, so a run Dan can
// still book on seven of its eight nights was drawn in the same filled rust capsule as a show he cannot
// make at all. Rust is this app's colour for something that FAILED; a partly booked run has not failed.
//
// #1583 then retired the pill itself: Keep is the acceptance now, so the badge had nothing left to do and
// the sentence beneath it carries the clash alone. The two-case colour decision survived the badge, which
// is what this file still measures. `pillForeground` did not: nothing draws text ON a warm fill for a
// clash any more, so the pairing it existed for is gone.
//
// The part with teeth is that readability is MEASURED here rather than judged. #1522 did not move the
// colour because there was no gold foreground token, and picking one "by eye" is how the incumbent
// `onRust` was chosen: measured afterwards, white on the dark-mode rust fill came to 3.45 to 1, under the
// 4.5 to 1 that 11pt semibold text needs.
@Suite("The colour a date clash is drawn in, and whether it is readable (#1527/#1583)")
struct ConflictNoteColourTests {

    // MARK: which colour each case gets

    // Unchanged. A show Dan genuinely cannot make keeps the failure colour it has always had (#901).
    @Test func aShowHeCannotMakeKeepsTheFailureColour() {
        expectSameColour(ConflictScope.thisNight.noteTint, OVColor.rust)
    }

    // THE #1527 fix, and it outlived the pill. A run with one blocked night inside it is bookable on its
    // other nights, so it must not be drawn in the colour this app uses for something that failed.
    @Test func aPartlyBookedRunIsNotDrawnInTheFailureColour() {
        expectSameColour(ConflictScope.laterInTheRun.noteTint, OVColor.gold)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(srgb(ConflictScope.laterInTheRun.noteTint, appearance)
                    != srgb(ConflictScope.thisNight.noteTint, appearance),
                    "the two cases draw the same colour under \(appearance.rawValue), which is the whole defect")
        }
    }

    // MARK: readability, measured rather than judged

    // The date-group header still draws a filled rust capsule with text on it ("Unavailable", in
    // QueueView.dateSection), so this pairing outlives the card's pill and is still worth measuring. Dark
    // mode is the theme Dan uses, and it is the half that was failing: white on the lighter dark-mode
    // terracotta measured 3.45 to 1 before #1527 split the token by theme.
    @Test func theUnavailableDateHeaderIsReadableInTheDarkThemeDanUses() {
        #expect(contrast(OVColor.onRust, on: OVColor.rust, under: .darkAqua) >= 4.5)
    }

    // The clash SENTENCE, which since #1583 is the only thing on the card carrying the clash, measured
    // against the card it sits on rather than against the capsule it used to sit under.
    //
    // This records a known gap rather than asserting it away. The rust case clears AA comfortably. The gold
    // case does NOT: `gold` on `surface` measures about 3.2 to 1 in the light theme, under the 4.5 to 1 that
    // text this size needs. That is not something #1583 introduced (the sentence has been gold on the card
    // since #1527) and fixing it means changing a colour Dan looks at, which is his call, not a change to
    // smuggle into an issue about what Keep means. So the floor is pinned at what is actually on screen
    // today: the number cannot silently get WORSE while the decision is open, and it names itself when it
    // moves. Raise this to 4.5 in both themes the moment the tint is settled.
    @Test func theClashSentenceIsNoLessReadableThanItIsToday() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(contrast(ConflictScope.thisNight.noteTint, on: OVColor.surface, under: appearance) >= 4.5,
                    "the rust clash sentence fell below AA under \(appearance.rawValue)")

            let gold = contrast(ConflictScope.laterInTheRun.noteTint, on: OVColor.surface, under: appearance)
            #expect(gold >= 3.2,
                    """
                    the gold clash sentence measures \(String(format: "%.2f", gold)) to 1 under \
                    \(appearance.rawValue), worse than the 3.2 it read when #1583 left it alone.
                    """)
        }
    }

    // MARK: measuring

    private func expectSameColour(_ lhs: Color, _ rhs: Color,
                                  sourceLocation: SourceLocation = #_sourceLocation) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(srgb(lhs, appearance) == srgb(rhs, appearance), sourceLocation: sourceLocation)
        }
    }

    /// The colour actually drawn, resolved through the same dynamic-provider path the app draws with
    /// (#1444's `OVColorResolutionTests` uses this same seam), rounded so float noise cannot fail an
    /// equality check.
    private func srgb(_ color: Color, _ name: NSAppearance.Name) -> [Int] {
        let components = resolved(color, under: name)
        return [components.red, components.green, components.blue].map { Int(($0 * 1000).rounded()) }
    }

    private func resolved(_ color: Color,
                          under name: NSAppearance.Name) -> (red: Double, green: Double, blue: Double, alpha: Double) {
        let nsColor = NSColor(color)
        var out = nsColor
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            out = nsColor.usingColorSpace(.sRGB) ?? nsColor
        }
        return (Double(out.redComponent), Double(out.greenComponent), Double(out.blueComponent),
                Double(out.alphaComponent))
    }

    /// WCAG 2.1 contrast ratio of a foreground over a fill. The foreground is composited onto the fill
    /// first: `onRust` is white at 96% opacity, so measuring it as flat white would report a ratio the
    /// screen never shows.
    private func contrast(_ foreground: Color, on fill: Color, under name: NSAppearance.Name) -> Double {
        let back = resolved(fill, under: name)
        let front = resolved(foreground, under: name)
        let a = front.alpha
        let composited = (red: front.red * a + back.red * (1 - a),
                          green: front.green * a + back.green * (1 - a),
                          blue: front.blue * a + back.blue * (1 - a))

        let l1 = luminance(composited.red, composited.green, composited.blue)
        let l2 = luminance(back.red, back.green, back.blue)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    private func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
        func channel(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }
}
