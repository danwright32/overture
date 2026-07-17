import Testing
@testable import Overture

// #1037: the cancel wiring spans three files whose behavior is unit-tested elsewhere (the native loop in
// ScoutCancelTests, the sentinel API in ScoutExtractCancelServiceTests, the button in
// ScoutProgressViewStateTests, the shell predicate in scout-cancel.test.sh). What no behavioral test can
// see is whether those pieces are actually CONNECTED: that RootView's Cancel both flags the native sweep
// and writes the sentinel, and that the runner reads the sentinel on its heartbeat and clears it. This
// pins that wiring, so a silent disconnect (a Cancel button that does nothing) cannot slip through.
@MainActor
@Suite("The cancel wiring is connected end to end (#1037)")
struct ScoutCancelWiringGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }
    private var runner: String { SourceGuardHelper.source("scripts/scout-extract-run.sh") }

    @Test func rootViewCancelStopsBothHalves() {
        #expect(!rootView.isEmpty)
        // The native sweep reads the flag...
        #expect(rootView.contains("isCancelled: { scoutCancelRequested }"))
        // ...and the detached read is stopped via the sentinel the runner checks.
        #expect(rootView.contains("ScoutExtractService.requestCancel()"))
    }

    @Test func theRunnerHonoursTheCancelSentinelOnItsHeartbeat() {
        #expect(!runner.isEmpty)
        #expect(runner.contains("scout-cancel.sh"))     // it sources the predicate
        #expect(runner.contains("cancel_requested"))    // and checks it (in the heartbeat)
        // And it clears the sentinel so a stopped run cannot kill the next one.
        #expect(runner.contains("clear_cancel"))
    }

    // #1053: the cancel must be read on the SHORT poll, decoupled from the 60s marker work, or a Cancel
    // Dan clicks would again sit unnoticed for up to a minute. The cadence decision (marker_due) is unit-
    // tested in scout-cancel.test.sh; this pins that the runner actually sleeps the short poll and gates
    // the periodic work behind marker_due, so the two cadences can't be silently re-coupled.
    @Test func theRunnerPollsTheCancelSentinelFasterThanTheMarkerWork() {
        #expect(!runner.isEmpty)
        #expect(runner.contains("SCOUT_EXTRACT_CANCEL_POLL_SECONDS"))   // a short, tunable poll
        #expect(runner.contains("sleep \"$CANCEL_POLL\""))              // the loop sleeps that poll, not 60
        #expect(runner.contains("marker_due"))                         // the 60s work is gated behind it
    }
}
