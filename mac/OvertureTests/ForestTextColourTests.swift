import Testing
import SwiftUI
import AppKit

// #2264, Dan looking at a source row in a running Debug build on 2026-08-07, dark theme: the two controls
// the row exists to get an answer from ("Name the venue", "Add address") were the two that looked LEAST
// available, while the row's neutral controls ("Read this one now", "Stop watching") were noticeably
// brighter. A dimmed control is the recognised convention for "you cannot press this", so the reading was
// not "I did not notice it" but "I am not allowed to", which is L49 one step worse than invisible.
//
// The issue asked whether the tint is under-contrasted generally or whether those two rows want a
// different emphasis, and asked for it to be MEASURED rather than adjusted by eye, the way
// `ConflictNoteColourTests` settled gold and rust. Measured, it is general: forest as text fails on every
// dark background in the app.
@Suite("Forest as text, measured (#2264)")
struct ForestTextColourTests {

    private let darkBackgrounds: [(String, Color)] = [
        ("canvas", OVColor.canvas), ("surface", OVColor.surface), ("surfaceSunk", OVColor.surfaceSunk),
    ]

    // The finding, kept as a test rather than only in a comment: this is why the token exists, and if the
    // fill colour is ever "fixed" by lightening it, this fails and says so.
    @Test func plainForestIsUnreadableAsTextInTheDarkTheme() {
        let ratio = contrast(OVColor.forest, on: OVColor.canvas, under: .darkAqua)
        #expect(ratio < 3.0, """
            plain forest now measures \(String(format: "%.2f", ratio)) to 1 as text on the dark canvas. \
            If it has been lightened, `onForest` (white drawn ON it) needs re-measuring, and forestText \
            may no longer be needed.
            """)
    }

    // The token, against every background the app draws a row on, in both themes.
    @Test func forestTextIsReadableEverywhereItIsDrawn() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, background) in darkBackgrounds {
                let ratio = contrast(OVColor.forestText, on: background, under: appearance)
                #expect(ratio >= 4.5, """
                    forest text measures \(String(format: "%.2f", ratio)) to 1 on \(name) under \
                    \(appearance.rawValue), below the 4.5 to 1 that text this size needs.
                    """)
            }
        }
    }

    // The light theme was already fine, and lifting it there would only wash it out, so it is deliberately
    // unchanged. Pinned, because "changed only the half that failed" is the decision, not an accident.
    @Test func theLightThemeIsUntouched() {
        #expect(srgb(OVColor.forestText, .aqua) == srgb(OVColor.forest, .aqua))
        #expect(srgb(OVColor.forestText, .darkAqua) != srgb(OVColor.forest, .darkAqua))
    }

    // The defect in Dan's own words: the row's positive actions must not be dimmer than its neutral ones.
    // Comparing the two rather than checking each against a bar, because "these look switched off beside
    // those" is a comparison, and a pair of ratios that both pass could still read that way.
    @Test func aPositiveControlIsNoDimmerThanTheNeutralOnesBesideIt() {
        let positive = contrast(OVColor.forestText, on: OVColor.surfaceSunk, under: .darkAqua)
        let neutral = contrast(OVColor.inkSoft, on: OVColor.surfaceSunk, under: .darkAqua)

        #expect(positive >= neutral * 0.55, """
            the row's positive controls measure \(String(format: "%.2f", positive)) to 1 while the neutral \
            ones beside them measure \(String(format: "%.2f", neutral)), which is the gap that read as \
            "you cannot press this".
            """)
    }

    // The capsule button every one of those asks is drawn with defaults to the readable token, so a
    // control added next year is readable without anybody knowing this issue happened.
    @Test func theSharedCapsuleButtonDefaultsToTheReadableToken() {
        let source = SourceGuardHelper.source("Overture/UI/OVCapsuleButton.swift")
        #expect(!source.isEmpty)
        #expect(source.contains("var tint: Color = OVColor.forestText"))
    }

    // And nothing draws plain `forest` as text any more. Its remaining uses are fills, which is what it
    // is for: `onForest` is measured against it as a fill and would break if it were lightened.
    @Test func nothingDrawsPlainForestAsText() {
        let offenders = AppSourceWalk.appFiles().flatMap { file -> [String] in
            SwiftSource.scannableLines(in: file.text, skipping: .scaffolding).compactMap { entry in
                guard entry.code.contains("OVColor.forest"),
                      !entry.code.contains("OVColor.forestText") else { return nil }
                let isFill = entry.code.contains("fill(") || entry.code.contains("background(")
                    || entry.code.contains("strokeBorder") || entry.code.contains("opacity")
                    || entry.code.contains("Fill(")
                guard !isFill else { return nil }
                return "\(file.name):\(entry.line) \(entry.code.trimmingCharacters(in: .whitespaces))"
            }
        }
        #expect(offenders.isEmpty, """
            These draw the FILL token where text is meant, which measures 2.53 to 1 in the dark theme. \
            Use OVColor.forestText:
            \(offenders.joined(separator: "\n"))
            """)
    }

    // MARK: measuring
    //
    // The same seam and the same arithmetic as ConflictNoteColourTests, which is deliberate: two
    // implementations of a WCAG ratio would eventually disagree, and the one that disagreed quietly would
    // be the one holding the bar.

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
