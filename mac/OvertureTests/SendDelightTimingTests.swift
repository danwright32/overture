import Testing
@testable import Overture

// #361: the post-send delight (a gold "Sent" seal, a thin gold line drawing once, then the row
// gliding up and fading). The phase timing and the Reduced Motion decision live here, in a tested
// value, not computed inside the SwiftUI view, so the "honor Reduced Motion" and "under one second"
// rules can't silently drift under a green suite.
@Suite("Send delight timing")
struct SendDelightTimingTests {
    @Test func normalMotionDrawsTheLineAndGlidesUp() {
        let t = SendDelightTiming.plan(reduceMotion: false)
        #expect(t.lineDraw > 0)      // the gold line actually draws
        #expect(t.translateUp)       // the row glides up as it leaves
    }

    @Test func reducedMotionDropsTheLineAndTheGlide() {
        let t = SendDelightTiming.plan(reduceMotion: true)
        #expect(t.lineDraw == 0)     // no drawn line
        #expect(!t.translateUp)      // no glide, opacity fade only
    }

    // The issue's hard constraint: the whole moment finishes under one second, in both modes, and it
    // always actually leaves (a non-zero exit), so a send can never appear to hang mid-animation.
    @Test func everyPlanFinishesUnderOneSecondAndActuallyExits() {
        for reduce in [false, true] {
            let t = SendDelightTiming.plan(reduceMotion: reduce)
            #expect(t.exit > 0)
            #expect(t.holdBeforeExit >= 0)
            #expect(t.total <= 1.0, "the send delight must finish under a second (reduceMotion: \(reduce))")
        }
    }
}
