import Testing
import Foundation

// #1684. Observed live on the #1601 Phase 8 walk, 2026-07-28. Dan, mid-run: "I'm trying to click cancel
// and it's doing nothing."
//
// It was not doing nothing. The click was honoured at once and the run died at 66 seconds. But the panel
// kept showing a spinner, "Checking reachability", "1 of 5 done", a climbing timer and a Cancel button,
// pixel for pixel identical to a run working normally, for the three minutes it took the marker to go
// stale. So he clicked again, and again, and reported it broken. That is the only reasonable read of what
// the app showed him.
//
// This is the project's own progress rule failing exactly where it matters most: working, still alive and
// failed have to be visibly distinct, and here "stopping" was indistinguishable from "still working".
@Suite("A stop request is its own state (#1684)")
struct StoppingIsItsOwnStateTests {

    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    // The moment the request is made, the panel must stop looking like a run that is working.
    @Test func arequestedStopIsNeitherRunningNorStalled() {
        let state = RunProgress.liveness(since: start, now: start.addingTimeInterval(70),
                                         timeout: RunTimeouts.reachabilityProbe,
                                         heartbeat: .beating, cancelRequested: true)

        #expect(state == .stopping(elapsed: "1:10"))
    }

    // Without a request nothing changes: the same instant, the same heartbeat, still a running run.
    @Test func arunNobodyStoppedIsUnaffected() {
        let state = RunProgress.liveness(since: start, now: start.addingTimeInterval(70),
                                         timeout: RunTimeouts.reachabilityProbe,
                                         heartbeat: .beating)

        #expect(state == .running(elapsed: "1:10"))
    }

    // A stop request must outrank the STALLED verdict too. Past the timeout with a dead heartbeat the
    // panel would otherwise accuse the run of being stuck, when Dan is the one who stopped it: nothing
    // has gone wrong and there is nothing for him to retry.
    @Test func astoppedRunIsNeverAccusedOfBeingStuck() {
        let state = RunProgress.liveness(since: start,
                                         now: start.addingTimeInterval(RunTimeouts.reachabilityProbe + 60),
                                         timeout: RunTimeouts.reachabilityProbe,
                                         heartbeat: .stale, cancelRequested: true)

        if case .stalled = state { Issue.record("a run Dan stopped must never read as stuck: \(state)") }
    }

    // Once the marker is GONE the run is genuinely over, and the screen closes itself the way it does after
    // any run. "Stopping" then would be a screen claiming work is still winding down after it has ended.
    @Test func aStoppedRunWhoseMarkerHasGoneIsFinishing() {
        let state = RunProgress.liveness(since: start, now: start.addingTimeInterval(70),
                                         timeout: RunTimeouts.reachabilityProbe,
                                         heartbeat: .absent, cancelRequested: true)

        #expect(state == .finishing(elapsed: "1:10"))
    }

    // The second half of what he saw. A cancelled run's heartbeat stops immediately, because the runner's
    // heartbeat loop exits the moment it reads the sentinel, so nothing touches the marker again. Waiting
    // the full three-minute window after that is waiting for a clock rather than for evidence: the app can
    // conclude a stopped run is over as soon as the marker misses a beat it would certainly have made.
    @Test func astoppedRunIsDeclaredOverWellBeforeTheFullTimeout() {
        let stoppedAt = start.addingTimeInterval(70)
        let overAt = RunProgress.stoppedRunIsOver(cancelRequestedAt: stoppedAt,
                                                  markerTouchedAt: stoppedAt,
                                                  now: stoppedAt.addingTimeInterval(RunTimeouts.stoppedRunGrace + 1))

        #expect(overAt, "a stopped run whose marker has gone quiet is over")
        #expect(RunTimeouts.stoppedRunGrace < RunTimeouts.prep,
                "the whole point is that it settles sooner than the ordinary stale window")
    }

    // It must not declare a run over while its marker is still being touched, which is what a runner that
    // has not yet noticed the sentinel looks like. Killing the panel there would report a live run dead.
    @Test func arunStillTouchingItsMarkerIsNotDeclaredOver() {
        let stoppedAt = start.addingTimeInterval(70)
        let overAt = RunProgress.stoppedRunIsOver(
            cancelRequestedAt: stoppedAt,
            markerTouchedAt: stoppedAt.addingTimeInterval(RunTimeouts.stoppedRunGrace),
            now: stoppedAt.addingTimeInterval(RunTimeouts.stoppedRunGrace + 1))

        #expect(!overAt)
    }

    // What the panel SAYS while it winds down. It has to be honest about the one thing Dan cannot see:
    // stopping does not call back the lookups that are already running.
    @Test func thestoppingCopySaysTheInflightLookupsStillLand() {
        let label = RunProgress.stoppingLabel(elapsed: "1:10")

        #expect(label.lowercased().contains("stopping"))
        #expect(!ReachabilityProbeCopy.stoppingSpendNote.isEmpty)
        #expect(ReachabilityProbeCopy.stoppingSpendNote.lowercased().contains("under way")
                || ReachabilityProbeCopy.stoppingSpendNote.lowercased().contains("already"),
                "it must name the lookups that are still finishing")
        #expect(!ReachabilityProbeCopy.stoppingSpendNote.contains("$"))
    }
}
