import Testing
import Foundation
@testable import Overture

// #48: a finished Prep run that produced nothing must be distinguishable from one that
// delivered results, so the app can say so instead of looking identical to "still waiting".
// The phase is decided from the run-start time and whether the results file was refreshed by
// this run. #472: no `running` case here (removed as dead code; every real caller only asks
// this after already confirming the run stopped), see RunLiveness for the live-ticking question.
@Suite("Detached run outcome")
struct DetachedRunOutcomeTests {
    private let started = Date(timeIntervalSince1970: 1_000_000)

    @Test func idleWhenNoRunWasEverStarted() {
        #expect(DetachedRunOutcome.phase(runStartedAt: nil, resultsModifiedAt: nil) == .idle)
        #expect(DetachedRunOutcome.phase(runStartedAt: nil, resultsModifiedAt: Date()) == .idle)
    }

    @Test func producedResultsWhenTheFileWasRefreshedByThisRun() {
        let fresh = started.addingTimeInterval(120)
        #expect(DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: fresh) == .producedResults)
    }

    @Test func finishedEmptyWhenNoFreshResults() {
        // No results file at all.
        #expect(DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: nil) == .finishedEmpty)
        // A results file left over from a PRIOR run (older than this run's start).
        let stale = started.addingTimeInterval(-120)
        #expect(DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: stale) == .finishedEmpty)
    }
}

@Suite("Run log tail")
struct RunLogTailTests {
    @Test func returnsTheLastNLines() {
        let text = "a\nb\nc\nd\ne"
        #expect(RunLog.tail(2, in: text) == "d\ne")
    }

    @Test func returnsEverythingWhenFewerLinesThanAsked() {
        #expect(RunLog.tail(10, in: "only\ntwo") == "only\ntwo")
    }

    @Test func emptyForNonPositiveCountOrBlankText() {
        #expect(RunLog.tail(0, in: "a\nb") == "")
        #expect(RunLog.tail(3, in: "") == "")
    }
}
