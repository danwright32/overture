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
}
