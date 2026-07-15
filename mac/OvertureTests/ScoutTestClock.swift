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
}
