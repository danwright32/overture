import Testing
import Foundation
@testable import Overture

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

    @Test func theWatcherOnlyEntersOnAGenuinelyLiveRunAndReopensTheTakeover() {
        // Isolate the watcher's own body so these assertions cannot be satisfied by the identical wiring
        // elsewhere in the file (the idle toolbar label, canStartPrep, and so on all read isRunning too).
        guard let body = rootView.components(separatedBy: "private func watchPrepRuns() async").last else {
            Issue.record("watchPrepRuns body not found"); return
        }
        // Only when a run is genuinely live (so an old failed run never re-nags on a normal open, #48),
        #expect(body.contains("if PrepQueueService.isRunning(now: Date())"))
        // it reopens the takeover on its own so a re-prep launched from a row is never invisible,
        #expect(body.contains("prepSheetShown = true"))
        // and hands off to the shared watch that follows the run to completion.
        #expect(body.contains("await watchPrepRun()"))
    }

    @Test func theWatcherFollowsTheRunToCompletion() {
        // It still ingests what the run produced (or reports a run that finished empty) via the same
        // watch + finish path an explicit "Prep kept" run uses, so a re-prepped run is not a dead end.
        #expect(rootView.contains("await watchPrepRun()"))
        #expect(rootView.contains("private func watchPrepRun() async"))
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
