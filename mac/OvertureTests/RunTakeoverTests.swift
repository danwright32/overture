import Testing
import Foundation

// #2760: `prepSheetShown`, `listingReadProgress` and `listingReadStartedAt` were three single `@State`
// values on RootView, shared by both launches. The first run to finish sets `prepSheetShown = false` and
// dismisses the takeover out from under the second, and the second run's listing-read count overwrites the
// first's while it is still counting.
//
// The state lives here rather than in the view for the reason #863 states: logic in a SwiftUI view body is
// unreachable by any test, which is how a rule like "hide only the run that ended" comes to be written
// once and then quietly broken.
@Suite("A run's takeover belongs to its slot (#2760)")
struct RunTakeoverTests {

    // The named defect. Two takeovers are up (which is what the exclusion still prevents today and what
    // #2765 allows), one run ends, and the other's screen has to survive it.
    @Test func oneRunEndingDoesNotDismissTheOthersTakeover() {
        var takeover = RunTakeover()
        takeover.show(.prep)
        takeover.show(.check)

        takeover.hide(.check)

        #expect(takeover.isShown(.prep))
        #expect(!takeover.isShown(.check))
        #expect(takeover.presented == .prep)
    }

    // Nothing is presented until a run puts something there, and hiding the last one closes the sheet.
    @Test func anIdleAppShowsNoTakeover() {
        var takeover = RunTakeover()
        #expect(takeover.presented == nil)
        takeover.show(.check)
        #expect(takeover.presented == .check)
        takeover.hide(.check)
        #expect(takeover.presented == nil)
    }

    // Which slot the one sheet renders: the one that got there FIRST, and it keeps the screen until it
    // ends. A rule of "whichever started last" would swap the content Dan is reading out from under him,
    // which is the same defect as dismissing it.
    @Test func theFirstTakeoverUpKeepsTheScreen() {
        var takeover = RunTakeover()
        takeover.show(.check)
        takeover.show(.prep)

        #expect(takeover.presented == .check)

        takeover.hide(.check)
        #expect(takeover.presented == .prep, "the run still going takes the screen when the other ends")
    }

    // Showing the same slot twice is one takeover, not two, so a re-announced run cannot leave a screen
    // that one hide cannot close (assume it runs twice).
    @Test func showingTheSameSlotTwiceIsStillOneTakeover() {
        var takeover = RunTakeover()
        takeover.show(.prep)
        takeover.show(.prep)

        takeover.hide(.prep)

        #expect(takeover.presented == nil)
    }

    // The listing read is the launch's own first phase (the app rendering each show's page), which has no
    // marker file, so its count IS its still-alive evidence. Two launches sharing one count means one
    // run's progress reads as the other's.
    @Test func eachSlotCountsItsOwnListingRead() {
        var takeover = RunTakeover()
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        takeover.startListingRead(.prep, at: started)
        takeover.recordListingProgress(.prep, completed: 3, total: 9, at: started.addingTimeInterval(5))
        takeover.startListingRead(.check, at: started.addingTimeInterval(1))
        takeover.recordListingProgress(.check, completed: 1, total: 2, at: started.addingTimeInterval(6))

        #expect(takeover.listingProgress(.prep)?.completed == 3)
        #expect(takeover.listingProgress(.prep)?.total == 9)
        #expect(takeover.listingProgress(.check)?.completed == 1)
        #expect(takeover.listingStartedAt(.prep) == started)
        #expect(takeover.listingStartedAt(.check) == started.addingTimeInterval(1))
    }

    // And finishing one slot's read leaves the other's alone, which is the `defer { listingReadProgress = nil }`
    // that used to run over whichever launch happened to be second.
    @Test func finishingOneListingReadLeavesTheOthersCounting() {
        var takeover = RunTakeover()
        let now = Date()
        takeover.startListingRead(.prep, at: now)
        takeover.recordListingProgress(.prep, completed: 2, total: 9, at: now)
        takeover.startListingRead(.check, at: now)

        takeover.finishListingRead(.check)

        #expect(takeover.listingProgress(.prep)?.completed == 2)
        #expect(takeover.listingProgress(.check) == nil)
        #expect(takeover.listingStartedAt(.check) == nil)
    }

    // Hiding a takeover clears that slot's listing read too: the phase belongs to the screen, and a stamp
    // left behind would make the next run's first tick look as if it had been going for hours.
    @Test func hidingATakeoverClearsItsOwnListingRead() {
        var takeover = RunTakeover()
        takeover.startListingRead(.check, at: Date())
        takeover.startListingRead(.prep, at: Date())

        takeover.hide(.check)

        #expect(takeover.listingStartedAt(.check) == nil)
        #expect(takeover.listingStartedAt(.prep) != nil)
    }
}
