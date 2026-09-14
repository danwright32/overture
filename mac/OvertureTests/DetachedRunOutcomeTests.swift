import Testing
import Foundation

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

    // #3887: whose run is it. Everything above compares the results file against the run MARKER, and
    // says nothing about whether that marker belongs to the caller asking. On 2026-09-13 a scout was
    // answered with "Read none", started no read at all, and the marker plus results file left by the
    // read of 2026-09-07 answered `.producedResults`: six day old events were re-imported and the app
    // froze for 34.2 s.
    @Test func idleWhenTheRunMarkerPredatesTheCallerAskingAboutIt() {
        let freshResults = started.addingTimeInterval(120)
        // The same inputs that read as produced results above, now asked by a caller that began AFTER
        // that run started. Nothing here belongs to it.
        #expect(DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: freshResults,
                                         callerStartedAt: started.addingTimeInterval(600)) == .idle)
    }

    @Test func readsTheRunWhenItStartedAfterTheCaller() {
        let callerBegan = started.addingTimeInterval(-10)
        let freshResults = started.addingTimeInterval(120)
        #expect(DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: freshResults,
                                         callerStartedAt: callerBegan) == .producedResults)
        #expect(DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: nil,
                                         callerStartedAt: callerBegan) == .finishedEmpty)
    }

    // A run that started at the very moment the caller did is the caller's own: the scout reads the
    // marker it just caused to be written, and a strict comparison would throw away every real read.
    @Test func aRunStartedAtTheSameInstantIsTheCallersOwn() {
        #expect(DetachedRunOutcome.phase(runStartedAt: started,
                                         resultsModifiedAt: started.addingTimeInterval(60),
                                         callerStartedAt: started) == .producedResults)
    }

    // A caller that does not say when it began is asking the old question, and gets the old answer.
    // `reattachScoutExtractRun` is that caller by design: at launch the run it means to pick up started
    // in a session that has ended, so a boundary of "now" would refuse every one of them.
    @Test func noCallerStartIsTheUnchangedRule() {
        let freshResults = started.addingTimeInterval(120)
        #expect(DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: freshResults) == .producedResults)
        #expect(DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: freshResults,
                                         callerStartedAt: nil) == .producedResults)
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
