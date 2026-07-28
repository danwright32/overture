import Testing
import SwiftUI
import AppKit
@testable import Overture

// #1527: #1501/#1522 changed the conflict pill's WORDS but deliberately not its colour, so a run Dan can
// still book on seven of its eight nights was drawn in the same filled rust capsule as a show he cannot
// make at all. Rust is this app's colour for something that FAILED; a partly booked run has not failed.
//
// The colour now comes off the SAME two-case decision as the label (ConflictScope), so the pill can never
// say "Partly booked" in the failure colour again.
//
// The second half of this suite is the part that has teeth. #1522 did not move the colour because there was
// no `onGold` foreground token, and picking one "by eye" is how the incumbent `onRust` was chosen: measured
// afterwards, white on the dark-mode rust fill came to 3.45 to 1, under the 4.5 to 1 that 11pt semibold text
// needs. So the readability of EVERY pill this file draws is measured here rather than judged, which is what
// makes it a guard instead of a preference. Dan's call, 2026-07-28, after seeing both badges mocked up:
// fix the incumbent in the same change rather than hold only the new pill to a bar the old one fails.
@Suite("The conflict pill's colour, and whether its label is readable on it (#1527)")
struct ConflictPillColourTests {

    // MARK: which colour each case gets

    // Unchanged. A show Dan genuinely cannot make keeps the failure colour it has always had (#901).
    @Test func aShowHeCannotMakeKeepsTheFailureColour() {
        expectSameColour(ConflictScope.thisNight.pillFill, OVColor.rust)
    }

    // THE fix. A run with one blocked night inside it is bookable on its other nights, so it must not be
    // drawn in the colour this app uses for something that failed.
    @Test func aPartlyBookedRunIsNotDrawnInTheFailureColour() {
        expectSameColour(ConflictScope.laterInTheRun.pillFill, OVColor.gold)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(srgb(ConflictScope.laterInTheRun.pillFill, appearance)
                    != srgb(ConflictScope.thisNight.pillFill, appearance),
                    "the two cases draw the same fill under \(appearance.rawValue), which is the whole defect")
        }
    }

    // Each fill carries the foreground written for it. Pinned because the readable pairing is the entire
    // reason this issue could not be a one-line colour swap.
    @Test func eachFillCarriesItsOwnForeground() {
        expectSameColour(ConflictScope.thisNight.pillForeground, OVColor.onRust)
        expectSameColour(ConflictScope.laterInTheRun.pillForeground, OVColor.onGold)
    }

    // MARK: readability, measured rather than judged

    // The guard. Every pill this app can draw for a date conflict, in both themes, clears the WCAG AA bar
    // for text this size. Goes red if anyone gives `onGold` white text (2.09 to 1 on the dark gold), or
    // reverts `onRust` to a single white value (3.45 to 1 on the dark rust).
    @Test func everyConflictPillIsReadableInBothThemes() {
        for scope in [ConflictScope.thisNight, .laterInTheRun] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let ratio = contrast(scope.pillForeground, on: scope.pillFill, under: appearance)
                #expect(ratio >= 4.5,
                        """
                        \(scope.pillLabel) under \(appearance.rawValue) measures \
                        \(String(format: "%.2f", ratio)) to 1, below the 4.5 to 1 that 11pt semibold needs.
                        """)
            }
        }
    }

    // The incumbent, called out on its own so a regression names itself. Dark mode is the theme Dan uses,
    // and it is the half that was failing: white on the lighter dark-mode terracotta measured 3.45 to 1.
    @Test func theUnavailablePillIsReadableInTheDarkThemeDanUses() {
        #expect(contrast(OVColor.onRust, on: OVColor.rust, under: .darkAqua) >= 4.5)
    }

    // MARK: the hover text

    // #1501 made the pill's LABEL and the sentence under it honest about which night is blocked, but left
    // the hover text saying "that night" for both cases. On a run flagged for Jul 31 under a Jul 24 header,
    // "that night" points at the night Dan is free on, which is the exact misreading #1501 exists to stop.
    @Test func theHoverTextNamesTheRightNight() {
        #expect(ConflictScope.thisNight.pillHelp.contains("that night"))
        #expect(!ConflictScope.laterInTheRun.pillHelp.contains("that night"))
        #expect(ConflictScope.laterInTheRun.pillHelp.contains("run"))
    }

    // Both hover texts end on the same override, because the way out of the pill is identical in both cases
    // and two hand-written copies of one sentence drift (#863/#885).
    @Test func bothHoverTextsOfferTheSameWayOut() {
        let tail = "Tap if you can shoot it after all."
        #expect(ConflictScope.thisNight.pillHelp.hasSuffix(tail))
        #expect(ConflictScope.laterInTheRun.pillHelp.hasSuffix(tail))
        #expect(ConflictScope.thisNight.pillHelp != ConflictScope.laterInTheRun.pillHelp)
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
