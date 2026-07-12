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
}
