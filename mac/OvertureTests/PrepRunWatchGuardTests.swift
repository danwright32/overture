import Testing
import Foundation

// #1143: a per-row Re-prep click launches a Prep run straight from ProspectMutations, with no RootView
// startPrep call to open the takeover or ingest its results. A single continuous watcher (watchPrepRuns)
// therefore has to follow EVERY live Prep run to completion (launch-time, explicit "Prep kept", or a
// re-prep from a row), the same way watchReplyClassifyRuns already does for reply-classify runs.
//
// The failure this guards is invisible and total, exactly the #435/#802 shape: remove the watcher and
// everything still compiles and every other test still passes, the only symptom being a re-prepped show
// whose drafts never surface until the next launch and whose progress shows nothing mid-session. So it is
// guarded by source (the watcher lives in a `.task` and drives @State), mirroring ScoutExtractWatchGuardTests
// and ScoutReattachGuardTests rather than inventing a second pattern, and paired with a data-path test that
// the live/dead gate it relies on is real.
@MainActor
@Suite("Every Prep run is followed to completion by one continuous watcher (#1143)")
struct PrepRunWatchGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func aContinuousTaskWatchesEveryPrepRun() {
        #expect(!rootView.isEmpty)
        // The `.task` hands off to the continuous watcher, and the watcher exists.
        #expect(rootView.contains("await watchPrepRuns()"))
        #expect(rootView.contains("private func watchPrepRuns() async"))
    }

    // #1938: the same rule, now that the watcher is TOLD a run has started rather than asking every three
    // seconds. Everything this guard exists to protect is unchanged: it enters only on a genuinely live
    // run, it reopens the takeover, and it follows the run to its end.
    @Test func theWatcherOnlyEntersOnAGenuinelyLiveRunAndReopensTheTakeover() {
        // Isolate the watcher's own body so these assertions cannot be satisfied by the identical wiring
        // elsewhere in the file (the idle toolbar label, canStartPrep, and so on all read isRunning too).
        guard let body = SourceGuardHelper.propertyBody("private func watchPrepRuns() async {",
                                                        in: rootView) else {
            Issue.record("watchPrepRuns body not found"); return
        }
        // Only when a run genuinely starts, which includes one a previous launch left in flight (that is
        // the one stat the activity makes when it is built), so an old failed run never re-nags (#48),
        #expect(body.contains("DetachedRunActivity.prep"))
        #expect(body.contains("runStarts()"))
        // it reopens the takeover on its own so a re-prep launched from a row is never invisible,
        #expect(body.contains("prepSheetShown = true"))
        // and follows the run to completion.
        #expect(body.contains("followUntilFinished()"))
        // #1938's defect itself: a sleep here is one an idle window pays for the life of the session.
        #expect(!body.contains("Task.sleep"))
        #expect(!body.contains("PrepQueueService.isRunning"))
    }

    @Test func theWatcherFollowsTheRunToCompletion() {
        // It still ingests what the run produced (or reports a run that finished empty) via the same
        // settle path an explicit "Prep kept" run uses, so a re-prepped run is not a dead end.
        #expect(rootView.contains("await settleFinishedPrepRun()"))
        #expect(rootView.contains("private func settleFinishedPrepRun() async"))
    }

    // The data path the watcher gates on, exercised directly: isRunning must tell a genuinely-live run
    // (a fresh marker) apart from a dead one (a stale marker), or the watcher would either never enter or
    // never leave. Without a real gate the whole "follow to completion" story is hollow.
    @Test func theLiveRunGateDistinguishesAFreshMarkerFromAStaleOne() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-running-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        #expect(PrepQueueService.isRunning(markerURL: marker, now: Date()) == false)   // absent: not running

        let written = Date(timeIntervalSince1970: 1_000_000)
        try Data().write(to: marker)
        try FileManager.default.setAttributes([.modificationDate: written], ofItemAtPath: marker.path)
        let window = PrepQueueService.markerStaleAfter
        #expect(PrepQueueService.isRunning(markerURL: marker, now: written.addingTimeInterval(window - 1)) == true)   // fresh: live
        #expect(PrepQueueService.isRunning(markerURL: marker, now: written.addingTimeInterval(window + 1)) == false)  // stale: dead
    }
}
