import Foundation
#if OVERTURE_HOSTED_TESTS
@testable import Overture
#endif

// #4569: compiled into BOTH test targets (mac/project.yml), the way RootHarness.swift is, so the hosted
// suites date their nights through the same function. It names EasternDate, which is why it is not in
// TestSupport: a file there cannot name an app type (see RowsFromStore). The import above is switched on
// only by the hosted target's OVERTURE_HOSTED_TESTS condition.
//
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
    // #771's suite. Its fixtures are dated 2026-09-19, which was the day they were written, and the
    // suite read the REAL clock, so `theCarnegieScoutStampsCarnegiesId` passed every day until
    // 2026-09-20 and then failed for nobody's change: the show it scouts had become a past date and
    // the scout correctly stored nothing. Anchored here so the pair is pinned at both ends (L130).
    static let provenanceAnchor = "2026-09-18"
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
    //
    // #4569: stepped from NOON Eastern rather than midnight. Midnight is safe today only because New York
    // never changes its clocks at midnight; noon is twelve hours from either edge of the day, so no clock
    // change anywhere can carry a step onto a neighbouring day.
    static func day(_ anchor: String, plus offset: Int) -> String {
        guard let start = EasternDate.date(from: anchor),
              let noon = EasternDate.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start) else {
            preconditionFailure("ScoutTestClock was handed '\(anchor)', which is not a day it can read")
        }
        guard let moved = EasternDate.calendar.date(byAdding: .day, value: offset, to: noon) else {
            preconditionFailure("ScoutTestClock could not move '\(anchor)' by \(offset) days")
        }
        return EasternDate.dayString(from: moved)
    }

    // #4569: the Eastern day `offset` days after the Eastern day `instant` falls on, for a fixture dated
    // from a clock (usually the real one, because the code under test reads it) rather than an anchor.
    //
    // WHY THIS EXISTS. Thirty suites built their nights as
    // `EasternDate.dayString(from: <host gregorian calendar>.date(byAdding: .day, value: n, to: Date()))`.
    // That calendar is the HOST's: Eastern on Dan's Mac, UTC on GitHub's runners. Adding whole UTC days
    // keeps the UTC clock time, so once the span crosses a clock change an instant between 04:00 and 05:00
    // UTC lands at 00:xx EDT before it and 23:xx EST after it, and two consecutive nights become ONE Eastern
    // day. Measured 2026-10-07 at 04:2x UTC: `AScoutRunDerivesTheQueueOnceTests` stored 38 shows, not 40,
    // on two unrelated pull requests, because the folded night dropped a show per widget (L504, L130).
    //
    // The instant is a parameter with no default, so the call site says which clock it is dated from. It is
    // reduced to its Eastern day first and stepped from noon there, in the app's own Eastern calendar, so the
    // answer is the same on every host and at every hour. `TestNightsAreEasternDaysTests` proves it inside
    // the window that failed, and refuses the chained host calendar step (a zone-less calendar built and
    // stepped in one expression) anywhere in the test tree. A host calendar held in a variable and stepped
    // later is NOT seen by that scan; every such variable in the tree today sets its zone.
    static func day(_ offset: Int, after instant: Date) -> String {
        day(EasternDate.dayString(from: instant), plus: offset)
    }
}
