import Foundation

// #798 gave `ScoutService.apply` an upcoming-only guard, which means every test that feeds it events
// now depends on WHEN it runs. A fixture dated 2026-06-22 was simply "an event" before; today it is a
// concert that already happened, and the guard correctly skips it.
//
// So the scout's tests pin the day rather than reading the wall clock. Without that, a suite that
// passes today goes red on its own months from now, for reasons that have nothing to do with the
// behavior under test. One shared constant, deliberately earlier than every fixture in the suite, so
// there is a single place to move it and no test quietly invents its own.
//
// A test that is ABOUT the guard (ScoutUpcomingOnlyTests) passes its own `today` instead: the whole
// point there is to sit on both sides of the line.
enum ScoutTestClock {
    static let beforeAllFixtures = "2026-01-01"

    // #811: each of these anchors a suite whose fixtures are dated relative to it (yesterday, tonight,
    // months before, etc.), so the exact value only has to stay internally consistent with that suite's
    // fixtures, not track any real date. They live here, named, instead of as a `private let today` in
    // each file, so a suite going red on a date nobody chose has one shared place to look and fix.
    static let runWindowAnchor = "2026-07-11"
    static let wentByRetirementAnchor = "2026-07-12"
    static let daysOffSnoozeAnchor = "2026-07-14"
    static let farFuture = "2099-01-01"

    // Shared by StageNavigationTests and StagePillCountMatchesNavigationTests: both exercise
    // StageNavigation.naturalKeys, one directly and one through AgentInputs.from, against the same
    // fixture story.
    static let stageNavigationAnchor = "2026-07-12"
    static let manualProvenanceAnchor = "2026-07-13"
    static let feedReconcileAnchor = "2026-06-25"

    // The day N days after an anchor, so a fixture whose meaning is its DISTANCE from the clock can be
    // derived from the rule it is about rather than written down as a literal (#3423).
    //
    // WHY THIS IS HERE. When the ordinary lead time window went from 90 days to 63, eight suites went
    // red, every one for the same reason: a date chosen to sit at, or just inside, the OLD edge. A
    // fixture meaning "this show is inside the window" has to follow the window, or the next time that
    // number moves it silently stands for a different case, and a test asserting about a show that is no
    // longer in Scout goes on passing while asserting nothing (L130, L98). `TriageWindowTests` was the
    // only suite that already did this, privately, and its own comment says why: "dates are computed
    // from the anchor rather than written down, so this suite follows the constant if Dan ever moves the
    // window instead of pinning a number that silently stops being the edge."
    //
    // It reads the app's own calendar rather than building a second one, because these are FIXTURES
    // rather than an assertion about date arithmetic. Where a suite is about the arithmetic itself
    // (`QueueWindowAndScoutHorizonTests`) it deliberately uses Foundation directly, since a check whose
    // two sides come from one implementation can only prove that implementation self-consistent (L70).
    // `TriageWindowTests` keeps one literal cross-check against this for the same reason.
    static func day(_ anchor: String, plus offset: Int) -> String {
        guard let start = EasternDate.date(from: anchor) else {
            preconditionFailure("ScoutTestClock was handed '\(anchor)', which is not a day it can read")
        }
        guard let moved = EasternDate.calendar.date(byAdding: .day, value: offset, to: start) else {
            preconditionFailure("ScoutTestClock could not move '\(anchor)' by \(offset) days")
        }
        return EasternDate.dayString(from: moved)
    }
}
