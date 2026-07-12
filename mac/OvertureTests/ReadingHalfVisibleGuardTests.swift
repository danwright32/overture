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
// It is worth its own guard because the regression is silent: remove the label and everything still
// compiles, every other test still passes, and the only symptom is that Dan's scout looks finished
// while it is still working.
@Suite("The scout's reading half is visible while it works (#803)")
struct ReadingHalfVisibleGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func theReadingHalfHasItsOwnLiveLabel() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("LiveRunLabel(base: \"Reading calendars\""))
        #expect(rootView.contains("readingStartedAt = ScoutExtractService.lastRunStartedAt"))
    }

    // Judged against the DETACHED run's timeout, not the in-process scout's. RunTimeouts.scout is three
    // minutes, which is right for a native run and wrong for a batch that follows every event's detail
    // page: a perfectly healthy read would be declared stuck at three minutes, and Dan would learn that
    // "looks stuck" means nothing.
    @Test func itIsJudgedAgainstTheDetachedRunsOwnTimeout() {
        #expect(rootView.contains("timeout: RunTimeouts.scoutExtract"))
        #expect(RunTimeouts.scoutExtract > RunTimeouts.scout)
    }

    // And against the run's real heartbeat, so a slow-but-living run never flips to "looks stuck" while
    // a genuinely dead one does. That distinction is the whole difference between still-alive and failed.
    @Test func aSlowButLivingRunIsNotCalledStuck() {
        #expect(rootView.contains("runAlive: { ScoutExtractService.isRunning(now: Date()) }"))
    }

    // Real "3 of 9", not a bare spinner, from the run's own progress file.
    @Test func itCountsRatherThanSpins() {
        #expect(rootView.contains("progressDetail: ScoutExtractProgressDecoder.label("))
    }
}
