import Testing
import Foundation

// #885: every sentence a finished run tells Dan, out of RootView's body and into a type a test can read.
//
// #876 did exactly this for the Prep run (PrepRunSummary) and stopped there. The scout's own summary,
// the extract ingest's summary, the three "the run finished empty" messages, and the OmniFocus receipt
// all stayed in the view, assembled inline, unreachable. Same file, same shape, same risk: these are
// claims about what the app just did and what it will do next.
@Suite("Run summary copy (#885)")
struct RunSummaryCopyTests {

    private func outcome(found: Int = 0, inserted: Int = 0, updated: Int = 0,
                         skipped: Int = 0) -> ScoutService.Outcome {
        ScoutService.Outcome(found: found, inserted: inserted, updated: updated, skipped: skipped)
    }

    // MARK: - The scout's own summary

    @Test func aScoutThatFoundNothingSaysSoRatherThanSayingNothing() {
        #expect(ScoutRunSummary.summary(for: outcome(found: 0)) == "0 found")
    }

    @Test func theScoutNamesWhatItFoundThenWhatIsNew() {
        #expect(ScoutRunSummary.summary(for: outcome(found: 9, inserted: 3)) == "9 found · 3 new")
    }

    // #1533: the line used to carry a third part, "N unsure", counting the classifications the rules
    // called uncertain. That was three quarters of every run, it pointed at a badge that no longer
    // exists, and Dan could do nothing with it.
    @Test func theScoutNeverReportsAnUnsureCount() {
        #expect(!ScoutRunSummary.summary(for: outcome(found: 9, inserted: 3)).contains("unsure"))
    }

    // A zero is left out rather than shown as "0 new". A summary padded with zeroes is one Dan skims.
    @Test func aZeroCountIsLeftOutEntirely() {
        #expect(ScoutRunSummary.summary(for: outcome(found: 4, inserted: 0)) == "4 found")
    }

    // MARK: - The watched-calendar ingest
    //
    // "Added" is inserted PLUS updated: a show already in the queue whose details changed is something
    // the run did, and the rule saying so was a bare bit of arithmetic in the view.

    @Test func addedMeansInsertedPlusUpdated() {
        let line = ScoutRunSummary.watchedCalendarSummary(for: outcome(inserted: 2, updated: 3))

        #expect(line == "5 from watched calendars")
    }

    // The zero case is a DIFFERENT sentence, not "0 from watched calendars", because a quiet calendar is
    // a normal, healthy state and must not read as a failure.
    @Test func nothingNewOnTheWatchedCalendarsIsItsOwnSentence() {
        let line = ScoutRunSummary.watchedCalendarSummary(for: outcome(inserted: 0, updated: 0))

        #expect(line == "Nothing new on the watched calendars")
    }

    // MARK: - A run that finished having produced nothing
    //
    // The one shape of failure that would otherwise be indistinguishable from silence. Each run's
    // sentence says something different and true about ITS work, and the log tail rides along so the
    // reason travels with the failure.

    @Test func eachDetachedRunSaysWhatItsOwnFailureMeans() {
        #expect(DetachedRunOutcome.finishedEmptyMessage(.prep, tail: "")
                    .contains("didn't produce any results"))
        #expect(DetachedRunOutcome.finishedEmptyMessage(.scoutExtract, tail: "")
                    .contains("Those pages have NOT been read"))
        #expect(DetachedRunOutcome.finishedEmptyMessage(.replyClassify, tail: "")
                    .contains("didn't produce a draft"))
    }

    @Test func theLogTailRidesAlongWithTheFailure() {
        let message = DetachedRunOutcome.finishedEmptyMessage(.prep, tail: "boom\nsplat")

        #expect(message.contains("Last lines of the run log:\nboom\nsplat"))
    }

    // An empty tail must not leave a dangling heading with nothing under it.
    @Test func anEmptyLogTailAddsNothing() {
        let message = DetachedRunOutcome.finishedEmptyMessage(.prep, tail: "")

        #expect(!message.contains("Last lines of the run log"))
    }

    // MARK: - OmniFocus

    @Test func aNeverSyncedOmniFocusSaysSoRatherThanShowingAnEmptyTime() {
        #expect(OmniFocusSyncStatus.line(lastSuccessAt: nil, now: Date()) == "Not yet synced")
    }

    @Test func aSyncedOmniFocusReadsAsRelativeTime() {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let line = OmniFocusSyncStatus.line(lastSuccessAt: now.addingTimeInterval(-3_600), now: now)

        #expect(line.hasPrefix("Synced "))
        #expect(line != "Synced ")
    }
}
