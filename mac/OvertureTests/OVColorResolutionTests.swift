import Testing
import SwiftUI
import AppKit
@testable import Overture

// #1444: OVColor's dynamic colours used to re-run NSAppearance.bestMatch inside their provider closure on
// every resolution, so every redraw re-decided each colour's light/dark value. The decision depends only on
// the appearance (which is stable within a pass), so it is now memoized per appearance. Three things to pin:
// (1) the decision is correct for each appearance, so nothing about light/dark rendering changes,
// (2) the expensive match runs once per distinct appearance rather than once per resolution, and
// (3) the real tokens still resolve to their declared light/dark colours end-to-end.
@Suite("OVColor appearance-darkness cache (#1444)")
struct OVColorResolutionTests {

    @Test func darkAppearancesResolveDark_andLightOnesDoNot() {
        let cache = OVAppearanceDarkness()
        #expect(cache.isDark(NSAppearance(named: .darkAqua)!) == true)
        #expect(cache.isDark(NSAppearance(named: .vibrantDark)!) == true)
        #expect(cache.isDark(NSAppearance(named: .aqua)!) == false)
        #expect(cache.isDark(NSAppearance(named: .vibrantLight)!) == false)
    }

    @Test func theExpensiveMatchRunsOncePerDistinctAppearance() {
        var matchCalls = 0
        let cache = OVAppearanceDarkness(match: { appearance in
            matchCalls += 1
            return appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        })
        let dark = NSAppearance(named: .darkAqua)!
        let light = NSAppearance(named: .aqua)!

        // What a layout pass does: resolve the same appearance many times. The match must run once.
        for _ in 0..<50 { _ = cache.isDark(dark) }
        #expect(matchCalls == 1)

        // A second, distinct appearance costs exactly one more match, then is likewise reused.
        for _ in 0..<50 { _ = cache.isDark(light) }
        #expect(matchCalls == 2)
    }

    // End-to-end guard on a real token: a redraw through the cache must still hand back the declared
    // light value under a light appearance and the declared dark value under a dark one (no visual change).
    @Test func canvasStillResolvesToItsDeclaredLightAndDarkColours() {
        let light = resolved(OVColor.canvas, under: .aqua)
        #expect(abs(light.redComponent - 0.957) < 0.002)
        #expect(abs(light.greenComponent - 0.945) < 0.002)
        #expect(abs(light.blueComponent - 0.910) < 0.002)

        let dark = resolved(OVColor.canvas, under: .darkAqua)
        #expect(abs(dark.redComponent - 0.055) < 0.002)
        #expect(abs(dark.greenComponent - 0.094) < 0.002)
        #expect(abs(dark.blueComponent - 0.071) < 0.002)
    }

    private func resolved(_ color: Color, under name: NSAppearance.Name) -> NSColor {
        let nsColor = NSColor(color)
        var out = nsColor
        NSAppearance(named: name)!.performAsCurrentDrawingAppearance {
            out = nsColor.usingColorSpace(.sRGB) ?? nsColor
        }
        return out
    }
}
