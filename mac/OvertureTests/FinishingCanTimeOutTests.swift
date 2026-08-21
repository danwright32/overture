import Testing
import Foundation

// #2872: a run stuck on "Finishing up" could never become actionable.
//
// `liveness` answered `.finishing` the instant the heartbeat marker read `.absent`, and that branch sat
// ABOVE the timeout check, so the state was absolute. The reasoning was right for the ordinary case (a
// runner deletes its marker in its exit trap, so absence is the last thing a healthy run does) and it
// made a run that tidied up and then died before delivering leave that sentence on screen for ever, with
// the counter beside it still ticking, which reads as alive. Dan watched it for over a minute on
// 2026-08-17 with nothing to press. A wait with no deadline cannot fail, it can only hang (L110).
//
// The window is measured from when absence was first OBSERVED, not from the run's start, because a
// deleted marker carries no timestamp: the instant has to be watched for. `FinishingWatch` is that
// observation, kept out of the view so it can be driven directly here.
@Suite("Finishing up is bounded (#2872)")
struct FinishingCanTimeOutTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var timeout: TimeInterval { RunTimeouts.replyDraft }

    // The ordinary case, unchanged and the reason the branch exists: the exit trap has just removed the
    // marker and the result is on its way in.
    @Test func amarkerThatJustWentAbsentStillReadsAsFinishing() {
        let now = start.addingTimeInterval(30)
        let state = RunProgress.liveness(since: start, now: now, timeout: timeout,
                                         heartbeat: .absent, markerAbsentSince: now)
        #expect(state.isFinishing)
    }

    // Still finishing right up to the bound, so the boundary is asserted rather than assumed.
    @Test func itholdsUpToTheBound() {
        let absentSince = start.addingTimeInterval(10)
        let now = absentSince.addingTimeInterval(RunTimeouts.finishingGrace - 1)
        #expect(RunProgress.liveness(since: start, now: now, timeout: timeout,
                                     heartbeat: .absent, markerAbsentSince: absentSince).isFinishing)
    }

    // THE gap: past the bound it becomes actionable.
    @Test func pastTheBoundItIsStalled() {
        let absentSince = start.addingTimeInterval(10)
        let now = absentSince.addingTimeInterval(RunTimeouts.finishingGrace)
        let state = RunProgress.liveness(since: start, now: now, timeout: timeout,
                                         heartbeat: .absent, markerAbsentSince: absentSince)
        #expect(state.isFinishing == false, "a run that tidied up and died sat here for ever")
        if case .stalled = state {} else { Issue.record("expected .stalled, got \(state)") }
    }

    // Measured from the ABSENCE, not from the run. A run that legitimately overran its timeout and then
    // finished cleanly must not be accused the moment its marker goes: that is the false alarm a bound
    // measured from `start` would produce, on the commonest slow case.
    @Test func alongRunThatJustFinishedIsNotAccused() {
        let absentSince = start.addingTimeInterval(timeout * 3)
        let state = RunProgress.liveness(since: start, now: absentSince.addingTimeInterval(1),
                                         timeout: timeout, heartbeat: .absent,
                                         markerAbsentSince: absentSince)
        #expect(state.isFinishing)
    }

    // A run Dan STOPPED keeps today's behaviour. `.stalled` carries a Retry and accuses the run of being
    // stuck; nothing went wrong there, he ended it, and `stoppedRunIsOver` is the mechanism that closes
    // those out. Scoped out deliberately rather than by omission (L11).
    @Test func arunDanStoppedIsNotAccusedOfStalling() {
        let absentSince = start.addingTimeInterval(10)
        let now = absentSince.addingTimeInterval(RunTimeouts.finishingGrace * 10)
        let state = RunProgress.liveness(since: start, now: now, timeout: timeout,
                                         heartbeat: .absent, cancelRequested: true,
                                         markerAbsentSince: absentSince)
        #expect(state.isFinishing)
    }

    // No observation at all keeps the old behaviour exactly, so a caller that has not been wired cannot
    // be silently given a bound it never asked for.
    @Test func withNoObservationItIsUnbounded() {
        let now = start.addingTimeInterval(timeout * 100)
        #expect(RunProgress.liveness(since: start, now: now, timeout: timeout,
                                     heartbeat: .absent, markerAbsentSince: nil).isFinishing)
    }

    // The observation itself.
    @Test @MainActor func thewatchRemembersWhenAbsenceBegan() {
        let watch = FinishingWatch()
        let t0 = start
        #expect(watch.observe(.beating, now: t0) == nil)
        #expect(watch.observe(.absent, now: t0.addingTimeInterval(5)) == t0.addingTimeInterval(5))
        // Every later tick answers the FIRST instant, which is the whole job: answering `now` each time
        // would restart the window on every tick and the bound could never be reached.
        #expect(watch.observe(.absent, now: t0.addingTimeInterval(90)) == t0.addingTimeInterval(5))
    }

    // A marker that comes back is a live run again, so the window resets. It cannot come back in the
    // ordinary flow, and a rule that only ever runs one way is a rule nobody has exercised.
    @Test @MainActor func aheartbeatReturningClearsIt() {
        let watch = FinishingWatch()
        _ = watch.observe(.absent, now: start)
        #expect(watch.observe(.beating, now: start.addingTimeInterval(5)) == nil)
        #expect(watch.observe(.absent, now: start.addingTimeInterval(9)) == start.addingTimeInterval(9))
    }

    // A caller with no marker at all (nil, not `.absent`) is not in this state and never was.
    @Test @MainActor func noMarkerAtAllIsNotAbsence() {
        let watch = FinishingWatch()
        #expect(watch.observe(nil, now: start) == nil)
    }

    // Both surfaces that render the verdict must observe, or the rule is right and nothing feeds it.
    //
    // The ARGUMENT is read, not merely the parameter name. A first version asked only whether the file
    // mentioned `markerAbsentSince:`, and a mutation passing `nil` there survived it: the word was still
    // present and the guard reported the wiring as intact while nothing fed it (L178, L103).
    @Test func bothSurfacesFeedTheObservation() {
        for file in ["Overture/UI/LiveRunLabel.swift", "Overture/UI/RunProgressView.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(source.contains("FinishingWatch"), "\(file) must hold the observation")
            let calls = source.components(separatedBy: "markerAbsentSince:").dropFirst()
            #expect(calls.isEmpty == false, "\(file) renders liveness and must bound it")
            for call in calls {
                let argument = call.prefix(while: { $0 != "\n" })
                #expect(argument.contains("absentSince") || argument.contains("observe("),
                        "\(file) passes something other than the watch's answer: \(argument)")
            }
        }
    }

    // The bound is a named, documented window beside the others, not a number typed into a branch.
    @Test func theboundIsAStatedWindow() {
        #expect(RunTimeouts.finishingGrace > 0)
        #expect(RunTimeouts.finishingGrace < RunTimeouts.stoppedRunGrace,
                "finishing is a handover, not a run: it must be the shortest window here")
    }
}

private extension RunLiveness {
    var isFinishing: Bool { if case .finishing = self { return true }; return false }
}
