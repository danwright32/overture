import Testing
import Foundation
@testable import Overture

// #435: a detached AI run (reply drafter, Prep, scout) must show a positive, moving sign of life
// so Dan can tell "still working" from "already hung". The elapsed label is the shared, runner-free
// signal next to the spinner. Pure so the formatting is unit-tested independent of any timer.
@Suite("Run progress elapsed label")
struct RunProgressTests {
    private let started = Date(timeIntervalSince1970: 1_000_000)

    @Test func nilWhenNoStart() {
        #expect(RunProgress.elapsedLabel(since: nil, now: started) == nil)
    }

    @Test func zeroAtTheStartInstant() {
        #expect(RunProgress.elapsedLabel(since: started, now: started) == "0:00")
    }

    @Test func subMinuteShowsSeconds() {
        #expect(RunProgress.elapsedLabel(since: started, now: started.addingTimeInterval(45)) == "0:45")
        #expect(RunProgress.elapsedLabel(since: started, now: started.addingTimeInterval(9)) == "0:09")
    }

    @Test func minutesAndSecondsZeroPadded() {
        #expect(RunProgress.elapsedLabel(since: started, now: started.addingTimeInterval(65)) == "1:05")
        #expect(RunProgress.elapsedLabel(since: started, now: started.addingTimeInterval(725)) == "12:05")
    }

    @Test func rollsToHoursPastSixtyMinutes() {
        // A stuck run can pass an hour; show H:MM:SS rather than an ever-growing minute count.
        #expect(RunProgress.elapsedLabel(since: started, now: started.addingTimeInterval(3725)) == "1:02:05")
    }

    @Test func clockSkewClampsToZero() {
        // `now` earlier than the start (clock change) must never render a negative label.
        #expect(RunProgress.elapsedLabel(since: started, now: started.addingTimeInterval(-30)) == "0:00")
    }
}

@Suite("Run progress spinner label")
struct RunProgressSpinnerLabelTests {
    private let started = Date(timeIntervalSince1970: 1_000_000)

    @Test func appendsTheElapsedCounterToTheBase() {
        #expect(RunProgress.spinnerLabel("Drafting a reply", since: started,
                                         now: started.addingTimeInterval(45)) == "Drafting a reply… 0:45")
    }

    @Test func fallsBackToTheBareLabelWithoutAStart() {
        // No start time (e.g. the counter source isn't known): the plain "working" label, no counter.
        #expect(RunProgress.spinnerLabel("Prepping", since: nil, now: started) == "Prepping…")
    }

    // #354: real "N of M" progress, e.g. from the Prep run's progress file, inserted before the
    // ellipsis so the label reads "Prepping 3 of 9… 0:45" instead of a bare elapsed counter.
    @Test func insertsProgressDetailBeforeTheEllipsis() {
        #expect(RunProgress.spinnerLabel("Prepping", since: started, now: started.addingTimeInterval(45),
                                         detail: "3 of 9") == "Prepping 3 of 9… 0:45")
    }

    @Test func detailShowsEvenWithoutAStart() {
        #expect(RunProgress.spinnerLabel("Prepping", since: nil, now: started, detail: "3 of 9")
                == "Prepping 3 of 9…")
    }

    @Test func noDetailIsUnaffected() {
        #expect(RunProgress.spinnerLabel("Prepping", since: started, now: started.addingTimeInterval(45),
                                         detail: nil) == "Prepping… 0:45")
    }
}

// #436: the one shared decision every long action routes through — given a start time, the current
// instant, and the run's expected window, is the run idle, still working/alive, or past its timeout
// (stalled → show an actionable failed state instead of an indefinite spinner). Pure so each surface
// can render the same three-state story from a TimelineView tick.
@Suite("Run progress liveness")
struct RunProgressLivenessTests {
    private let started = Date(timeIntervalSince1970: 1_000_000)
    private let timeout: TimeInterval = 5 * 60

    @Test func idleWithoutAStart() {
        #expect(RunProgress.liveness(since: nil, now: started, timeout: timeout) == .idle)
    }

    @Test func runningBeforeTheTimeoutCarriesTheElapsedLabel() {
        #expect(RunProgress.liveness(since: started, now: started.addingTimeInterval(45),
                                     timeout: timeout) == .running(elapsed: "0:45"))
    }

    @Test func stalledAtTheTimeoutBoundary() {
        // At exactly the timeout the run is treated as stalled (>=), matching isReplyDraftStalled.
        #expect(RunProgress.liveness(since: started, now: started.addingTimeInterval(300),
                                     timeout: timeout) == .stalled(elapsed: "5:00"))
    }

    @Test func stalledPastTheTimeoutStillReportsHowLong() {
        // The stalled state keeps the elapsed counter so Dan sees how long it has been stuck.
        #expect(RunProgress.liveness(since: started, now: started.addingTimeInterval(425),
                                     timeout: timeout) == .stalled(elapsed: "7:05"))
    }

    @Test func clockSkewIsRunningNotStalled() {
        // `now` before the start (clock change) clamps to 0:00 and must read as working, never stalled.
        #expect(RunProgress.liveness(since: started, now: started.addingTimeInterval(-30),
                                     timeout: timeout) == .running(elapsed: "0:00"))
    }

    // #471: a fixed wall-clock timeout alone can't tell a genuinely dead run from a slow-but-alive one.
    // `runAlive` is the real heartbeat (e.g. a marker-freshness check); when it says the run is still
    // going, past-timeout must never read as stalled.
    @Test func pastTimeoutWithRunAliveTrueStillReportsRunning() {
        #expect(RunProgress.liveness(since: started, now: started.addingTimeInterval(425),
                                     timeout: timeout, runAlive: true) == .running(elapsed: "7:05"))
    }

    @Test func pastTimeoutWithRunAliveFalseReportsStalled() {
        #expect(RunProgress.liveness(since: started, now: started.addingTimeInterval(425),
                                     timeout: timeout, runAlive: false) == .stalled(elapsed: "7:05"))
    }

    @Test func withinTimeoutIsRunningRegardlessOfRunAlive() {
        #expect(RunProgress.liveness(since: started, now: started.addingTimeInterval(45),
                                     timeout: timeout, runAlive: false) == .running(elapsed: "0:45"))
    }
}
