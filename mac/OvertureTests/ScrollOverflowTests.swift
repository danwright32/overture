import Testing
import Foundation

// #2159: whether a height-capped scrolling box is hiding anything below its bottom edge.
//
// The decision lives here rather than inline in the view because it is the whole feature: macOS hides
// scrollbars until a gesture starts, so an overflowing panel and a complete one look identical at rest,
// and the only thing that can tell them apart is this comparison. Both sides matter equally. A panel that
// fails to say more is below loses the rest of an email Dan is answering; a panel that says it while
// showing everything teaches him to ignore the cue on the panels that mean it.
@Suite("Scroll overflow cue (#2159)")
struct ScrollOverflowTests {

    @Test func contentThatFitsInsideTheBoxHidesNothing() {
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: 120, visibleHeight: 160, scrolledBy: 0) == false)
    }

    @Test func contentTallerThanTheBoxSaysSoBeforeAnyoneTouchesIt() {
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: 420, visibleHeight: 160, scrolledBy: 0))
    }

    @Test func theCueSurvivesScrollingPartWayDown() {
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: 420, visibleHeight: 160, scrolledBy: 100))
    }

    @Test func reachingTheBottomClearsTheCue() {
        // 420 of content in a 160 box scrolls 260 before the last line is on screen.
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: 420, visibleHeight: 160, scrolledBy: 260) == false)
    }

    // Rubber-band overscroll past the top reports a negative offset. It means MORE is below, never less.
    @Test func overscrollingPastTheTopKeepsTheCue() {
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: 420, visibleHeight: 160, scrolledBy: -30))
    }

    // Overscroll past the BOTTOM reports more than the real maximum. Nothing is hidden there either.
    @Test func overscrollingPastTheBottomShowsNoCue() {
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: 420, visibleHeight: 160, scrolledBy: 300) == false)
    }

    // A fraction of a point left over is layout rounding, not content. A cue for it would sit on panels
    // that show everything they have.
    @Test func aSubPixelRemainderIsNotContent() {
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: 160.4, visibleHeight: 160, scrolledBy: 0) == false)
    }

    @Test func oneHiddenLineIsContent() {
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: 175, visibleHeight: 160, scrolledBy: 0))
    }

    // SwiftUI runs a layout pass before it has measured anything, and every geometry value is zero there.
    // Unmeasured must read as "nothing to say" rather than as "everything is hidden": the alternative is
    // a cue that flashes onto every panel in the app for one frame, including the ones that fit.
    @Test func aBoxNobodyHasMeasuredYetSaysNothing() {
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: 0, visibleHeight: 0, scrolledBy: 0) == false)
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: 420, visibleHeight: 0, scrolledBy: 0) == false)
    }

    // L50: a measurement must never feed the comparison directly. A NaN compares false against every
    // threshold, so an unguarded version lands on whichever side the operator happens to give.
    @Test func anUnusableMeasurementSaysNothing() {
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: .nan, visibleHeight: 160, scrolledBy: 0) == false)
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: 420, visibleHeight: .nan, scrolledBy: 0) == false)
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: 420, visibleHeight: 160, scrolledBy: .nan) == false)
        #expect(ScrollOverflow.showsMoreBelow(contentHeight: .infinity, visibleHeight: 160, scrolledBy: 0) == false)
    }
}
