import Testing
import Foundation

// #2761, the last phase of #2620. Dan's call, 2026-08-15: one line per live run, each named, each with
// its own Cancel.
//
// Until #3015 the two runs excluded each other, so "the run on screen" was the only run and one block was
// the whole truth. Now both can be going, and macOS will not present a second sheet over the first, so a
// single block meant the other run worked entirely unseen: no name, no elapsed time, no way to stop it.
@Suite("Both live runs are on screen (#2761)")
struct BothRunsAreVisibleTests {

    @Test func nothingRunningShowsNothing() {
        #expect(RunTakeover().shown.isEmpty)
    }

    @Test func oneRunIsOneLine() {
        var t = RunTakeover()
        t.show(.prep)
        #expect(t.shown == [.prep])
    }

    // THE test. Before #2761 this could only ever answer with one.
    @Test func twoLiveRunsAreBothOnScreen() {
        var t = RunTakeover()
        t.show(.prep)
        t.show(.check)
        #expect(t.shown.count == 2, "only one run is visible, so the other works unseen")
        #expect(Set(t.shown) == [.prep, .check])
    }

    // The order is the order they went up, which is what stops a second run appearing ABOVE what Dan is
    // already reading and shifting it under him.
    @Test func theOrderIsTheOrderTheyStarted() {
        var t = RunTakeover()
        t.show(.check)
        t.show(.prep)
        #expect(t.shown == [.check, .prep])
    }

    // One run ending leaves the other's line alone, which is the property #2760 added and #2761 now has
    // to preserve across two visible blocks rather than one hidden one.
    @Test func oneRunEndingLeavesTheOthersLineUp() {
        var t = RunTakeover()
        t.show(.prep)
        t.show(.check)
        t.hide(.prep)
        #expect(t.shown == [.check])
    }

    // Announcing twice is one line, not two: the launch announces, then the watcher notices the same run.
    @Test func aRunThatAnnouncesTwiceIsOneLine() {
        var t = RunTakeover()
        t.show(.prep)
        t.show(.prep)
        #expect(t.shown == [.prep])
    }

    // The sheet's own dismissal closes the FIRST line only, leaving the other run visible. Dismissing the
    // sheet must never silently take a live run off screen with it.
    @Test func dismissingTheSheetClosesOneLineNotBoth() {
        var t = RunTakeover()
        t.show(.prep)
        t.show(.check)
        t.hidePresented()
        #expect(t.shown == [.check])
    }
}
