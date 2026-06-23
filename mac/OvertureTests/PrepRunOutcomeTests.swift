import Testing
import Foundation
@testable import Overture

// #48: a finished Prep run that produced nothing must be distinguishable from one
// still working and from one that delivered results, so the app can say so instead of
// looking identical to "still waiting". The phase is decided from the run-start time,
// the live marker, and whether the results file was refreshed by this run.
@Suite("Prep run outcome")
struct PrepRunOutcomeTests {
    private let started = Date(timeIntervalSince1970: 1_000_000)

    @Test func idleWhenNoRunWasEverStarted() {
        #expect(PrepRunOutcome.phase(runStartedAt: nil, running: true, resultsModifiedAt: nil) == .idle)
        #expect(PrepRunOutcome.phase(runStartedAt: nil, running: false, resultsModifiedAt: Date()) == .idle)
    }

    @Test func runningWhileTheMarkerIsLive() {
        #expect(PrepRunOutcome.phase(runStartedAt: started, running: true, resultsModifiedAt: nil) == .running)
    }

    @Test func producedResultsWhenTheFileWasRefreshedByThisRun() {
        let fresh = started.addingTimeInterval(120)
        #expect(PrepRunOutcome.phase(runStartedAt: started, running: false, resultsModifiedAt: fresh) == .producedResults)
    }

    @Test func finishedEmptyWhenNoFreshResults() {
        // No results file at all.
        #expect(PrepRunOutcome.phase(runStartedAt: started, running: false, resultsModifiedAt: nil) == .finishedEmpty)
        // A results file left over from a PRIOR run (older than this run's start).
        let stale = started.addingTimeInterval(-120)
        #expect(PrepRunOutcome.phase(runStartedAt: started, running: false, resultsModifiedAt: stale) == .finishedEmpty)
    }
}

@Suite("Prep log tail")
struct PrepLogTailTests {
    @Test func returnsTheLastNLines() {
        let text = "a\nb\nc\nd\ne"
        #expect(PrepLog.tail(2, in: text) == "d\ne")
    }

    @Test func returnsEverythingWhenFewerLinesThanAsked() {
        #expect(PrepLog.tail(10, in: "only\ntwo") == "only\ntwo")
    }

    @Test func emptyForNonPositiveCountOrBlankText() {
        #expect(PrepLog.tail(0, in: "a\nb") == "")
        #expect(PrepLog.tail(3, in: "") == "")
    }
}
