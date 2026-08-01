import Testing
import Foundation
@testable import Overture

// #1774: searching the same show twice in a row must jump twice.
//
// Found by Dan walking the Debug build, 2026-08-01: "It jumped to the show, I scrolled back up and then
// tried to search it again and then it's not working."
//
// The queue's scroll position lives on QueueScrollHolder and the deliberate jumps reach it through a
// channel the holder watches with .onChange. .onChange fires on a CHANGE, so a channel carrying the
// DESTINATION silently drops the second jump to the same place: the first search sets it to that show's
// date group, scrolling away moves the scroll position but leaves the channel still holding that group,
// and setting it to the identical value again is not a change. Nothing fires, and the click reads as dead.
//
// That is the #1573 dead click arriving by a new route, so the fix is to stop sending a destination. A
// jump is an EVENT, and two searches for one show are two events even though they name one group.
@Suite("Asking for the same jump twice is two jumps (#1774)")
struct QueueJumpRequestTests {
    // The regression test for exactly what Dan hit. Two requests naming the same group must not compare
    // equal, or .onChange cannot tell the second one happened.
    @Test func twoRequestsForTheSameGroupAreDifferentEvents() {
        let first = QueueJumpRequest(group: "2026-10-03")
        let second = QueueJumpRequest(group: "2026-10-03")

        #expect(first.group == second.group)
        #expect(first != second)
    }

    // And a request still says where to go, or the holder would have nothing to act on.
    @Test func aRequestCarriesTheGroupItWants() {
        #expect(QueueJumpRequest(group: "2026-10-03").group == "2026-10-03")
    }

    // A request equals itself, so handing the same one down twice (a parent re-render that changes
    // nothing) does not re-fire the jump and yank Dan off a row he has since scrolled to.
    @Test func oneRequestHandedDownTwiceIsStillOneJump() {
        let request = QueueJumpRequest(group: "2026-10-03")
        #expect(request == request)

        let copy = request
        #expect(copy == request)
    }
}
