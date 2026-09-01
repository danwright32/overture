import Testing
import Foundation

// #1130: the Prep run gets the scout's takeover progress screen instead of only a subtle toolbar label,
// so a detached run that takes minutes shows a visible working / still-alive / stalled state. It reuses
// the shared RunProgressView in a new `.prepping` phase, fed by the run's own progress file.
@Suite("Prep progress takeover (#1130)")
struct PrepProgressTakeoverTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-takeover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func thePreppingPhaseIsTitledPrepping() {
        #expect(RunProgressCopy.title(.prepping) == "Prepping")
    }

    // The prepping phase must judge "looks stuck" against the PREP ceiling, not the scout's. Reusing the
    // scout sweep's shorter window would declare a healthy multi-minute Prep run stalled (the #803 lesson).
    @Test func thePreppingPhaseUsesThePrepTimeout() {
        let view = RunProgressView(phase: .prepping, since: nil)
        #expect(view.timeout == RunTimeouts.prep)
    }

    // A reachability check is NOT a Prep run wearing a different title, and sharing Prep's 3-minute
    // ceiling made the app accuse a healthy one of being stuck. The first real check ever run took 7m51s
    // for three shows and was reported as stalled at 3:38, on screen, while it was working normally.
    // A check reads pages and hunts contacts per show, so it belongs with the other heavy detached runs.
    //
    // This is the WARNING window only. The double-run guard (PrepQueueService.markerStaleAfter) stays at
    // 3 minutes deliberately: the runner touches its marker every 60s while alive, so a long batch never
    // goes stale and the guard already holds. Lengthening it would only make a genuinely DEAD check look
    // alive for 10 minutes.
    @Test func theProbingPhaseGetsItsOwnLongerTimeoutNotPreps() {
        let probing = RunProgressView(phase: .probing, since: nil)
        #expect(probing.timeout == RunTimeouts.reachabilityProbe)
        #expect(probing.timeout > RunTimeouts.prep)
        // And prepping is untouched, so a normal Prep still surfaces a stall at the old window.
        #expect(RunProgressView(phase: .prepping, since: nil).timeout == RunTimeouts.prep)
    }

    // The failure this exists to prevent, stated as behaviour rather than as a constant: the exact run
    // Dan watched (7m51s) must not read as stalled at any point while it was alive.
    @Test func aHealthyEightMinuteCheckIsNeverCalledStuck() {
        let started = Date(timeIntervalSince1970: 0)
        let view = RunProgressView(phase: .probing, since: started)
        func stalledAt(_ seconds: TimeInterval) -> Bool {
            if case .stalled = RunProgress.liveness(since: started,
                                                    now: started.addingTimeInterval(seconds),
                                                    timeout: view.timeout) { return true }
            return false
        }
        #expect(!stalledAt(218))        // 3:38, the moment the real run was accused
        #expect(!stalledAt(471))        // 7:51, when it actually finished
        #expect(stalledAt(11 * 60))     // past the window it DOES stall: a longer leash, not a removed one
    }

    @Test func livePreppingReadsTheRunsProgressCount() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prep-progress.json")
        try JSONEncoder().encode(PrepProgress(version: 1, total: 6, completed: 2)).write(to: url)

        let snap = RunProgressView.Snapshot.livePrepping(progressURL: url)
        #expect(snap.total == 6)
        #expect(snap.completed == 2)
        // The Prep run publishes no per-prospect name, so there is no current-source line, only the count.
        #expect(snap.sourceName == nil)
        #expect(RunProgressCopy.currentSourceLine(name: snap.sourceName) == nil)
        #expect(RunProgressCopy.overallProgressLine(completed: snap.completed, total: snap.total) == "2 of 6 done")
    }

    // A missing/mid-write progress file reads as an empty snapshot (no crash, no thrown error), which the
    // shared copy renders as no count line at all rather than a bogus "0 of 0".
    @Test func livePreppingReadsAMissingFileAsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-progress-missing-\(UUID().uuidString).json")
        let snap = RunProgressView.Snapshot.livePrepping(progressURL: missing)
        #expect(snap.total == 0)
        #expect(snap.completed == 0)
        #expect(RunProgressCopy.currentSourceLine(name: snap.sourceName) == nil)
        #expect(RunProgressCopy.overallProgressLine(completed: snap.completed, total: snap.total) == nil)
    }
}

// #1130: the takeover is view-only wiring in RootView (a sheet cannot be exercised headlessly), held in
// place with a source guard in this project's existing convention (see PrepProgressWiringGuardTests), and
// paired with the behavioral snapshot/copy/timeout tests above so it is not a source-grep guard alone.
@Suite("Prep takeover is wired into RootView (#1130)")
struct PrepTakeoverWiringGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    @Test func rootViewPresentsThePrepTakeoverInThePreppingPhase() {
        let rootView = source("Overture/App/RootView.swift")
        #expect(!rootView.isEmpty)
        // #2760: the takeover sheet is bound to the per-slot takeover state and renders the shared
        // progress view in the prepping phase. One `prepSheetShown` flag was what let the first run to
        // finish dismiss the screen out from under the second.
        #expect(rootView.contains(".sheet(isPresented: runTakeoverBinding) { prepProgressModal }"))
        // #1322: the phase is prepping for a Prep, probing for a reachability check. #2760: the slot says
        // which, except in the upgrade window where a legacy check still sits in the prep slot.
        #expect(rootView.contains("slot == .check || PrepQueueService.isProbeRunning(now: Date())"))
        #expect(rootView.contains("Snapshot.livePrepping("))
    }
}
