import Testing
@testable import Overture

// #803: the scout's READING half is detached and can run for minutes, and it had no visible state at
// all.
//
// The bug this guards against is one I shipped: `runScout` turned the spinner off as soon as the native
// half finished, and only then began waiting for the pages to be read. So Overture reported the scout
// as done and then sat there reading calendars with nothing on screen, and nothing to say if that run
// hung or died. CLAUDE.md's rule is binding and explicit about exactly this: started, still-alive and
// failed must be visibly distinct, and a bare indefinite spinner (or here, no spinner at all) is a
// defect.
//
// #1034: that visible state moved out of a compact toolbar label and into the takeover ScoutProgressView
// (a scout Dan started owns the screen while it runs). The regression this guards against is unchanged
// (the reading half losing its own timeout, heartbeat and count), only its home did, so the guard now
// checks both the RootView wiring and the modal that renders it.
//
// It is worth its own guard because the regression is silent: remove the surface and everything still
// compiles, every other test still passes, and the only symptom is that Dan's scout looks finished while
// it is still working.
@Suite("The scout's reading half is visible while it works (#803)")
struct ReadingHalfVisibleGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }
    private var progressView: String { SourceGuardHelper.source("Overture/UI/ScoutProgressView.swift") }

    @Test func theReadingHalfHasItsOwnLiveSurface() {
        #expect(!rootView.isEmpty)
        #expect(!progressView.isEmpty)
        // The detached read is entered with its own start time...
        #expect(rootView.contains("readingStartedAt = ScoutExtractService.lastRunStartedAt"))
        // ...and shown through the modal's reading phase, not a silent wait.
        #expect(rootView.contains("readingStartedAt != nil ? .reading : .scouting"))
    }

    // Judged against the DETACHED run's timeout, not the in-process scout's. RunTimeouts.scout is three
    // minutes, which is right for a native run and wrong for a batch that follows every event's detail
    // page: a perfectly healthy read would be declared stuck at three minutes, and Dan would learn that
    // "looks stuck" means nothing. The modal picks the window from the phase.
    @Test func itIsJudgedAgainstTheDetachedRunsOwnTimeout() {
        #expect(progressView.contains("RunTimeouts.scoutExtract"))
        #expect(progressView.contains("RunTimeouts.scout"))
        #expect(RunTimeouts.scoutExtract > RunTimeouts.scout)
    }

    // And against the run's real heartbeat, so a slow-but-living run never flips to "looks stuck" while a
    // genuinely dead one does. That distinction is the whole difference between still-alive and failed:
    // RootView supplies the heartbeat, the modal routes it through the shared liveness decision.
    @Test func aSlowButLivingRunIsNotCalledStuck() {
        #expect(rootView.contains("ScoutExtractService.isRunning(now: Date())"))
        #expect(progressView.contains("RunProgress.liveness"))
    }

    // Real "3 of 9" from the run's own progress file, and the source being read RIGHT NOW, not a bare
    // spinner. Both come from files the app already owns (#1034), read live each tick. The snapshot that
    // reads them is shared with AddLeadSheet (#1036), so the loaders live in ScoutProgressView; RootView
    // wires that shared snapshot into the reading phase.
    @Test func itCountsAndNamesTheSourceRatherThanSpinning() {
        #expect(progressView.contains("ScoutExtractProgressDecoder.loadCurrent("))
        #expect(progressView.contains("ScoutExtractCurrentSource.loadCurrentName("))
        #expect(rootView.contains("ScoutProgressView.Snapshot.liveReading()"))
    }
}
