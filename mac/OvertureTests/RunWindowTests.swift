import Testing
@testable import Overture

// One definition of "has this run finished?", shared by the two places that ask it: the #798 import
// guard (should this show enter the queue at all?) and FeedReconcile (did this show vanish from the
// feed because it was cancelled, or because it simply happened?). Both were computing
// `runEndDate ?? performanceDate` and comparing it to today, separately.
//
// The two are NOT the same predicate, and that is the point of writing them down together rather than
// collapsing them into one. They disagree, on purpose, about an UNKNOWN date:
//
//   - On import, an undated listing has NOT passed, so it is kept. "Date to be confirmed" is a normal
//     state on an org's season page, and dropping it would silently lose a real show.
//   - For reconcile, an undated prospect is NOT live either, so it never accrues "disappeared from
//     the feed" misses. There is no date to prove it is still ahead.
//
// So `isLive` is deliberately not `!hasPassed`. Anyone tempted to simplify one into the other should
// read this suite first.
@Suite("Run window (#798)")
struct RunWindowTests {
    private let today = ScoutTestClock.runWindowAnchor

    @Test func theLastNightOfARunIsWhatDecidesIt() {
        // A multi-night run is judged on its closing night, not its opening one.
        #expect(EasternDate.runLastNight(runEndDate: "2026-07-20", performanceDate: "2026-07-09")
                == "2026-07-20")
        // A single-night show has only the one date.
        #expect(EasternDate.runLastNight(runEndDate: nil, performanceDate: "2026-07-09") == "2026-07-09")
        #expect(EasternDate.runLastNight(runEndDate: nil, performanceDate: nil) == nil)
    }

    @Test func aRunHasPassedOnlyOnceItsLastNightIsBehindUs() {
        #expect(EasternDate.runHasPassed(lastNight: "2026-07-10", today: today))     // yesterday
        #expect(!EasternDate.runHasPassed(lastNight: today, today: today))           // tonight, still to come
        #expect(!EasternDate.runHasPassed(lastNight: "2026-07-12", today: today))    // tomorrow
    }

    // The case the placement of this rule exists for: opened before today, still running.
    @Test func aRunUnderwayHasNotPassed() {
        let last = EasternDate.runLastNight(runEndDate: "2026-07-20", performanceDate: "2026-07-09")
        #expect(!EasternDate.runHasPassed(lastNight: last, today: today))
        #expect(EasternDate.runIsLive(lastNight: last, today: today))
    }

    // The deliberate asymmetry. An unknown date is neither passed (so it is imported) nor live (so it
    // never accrues disappearance misses). Collapsing these into one predicate breaks one of them.
    @Test func anUnknownDateIsNeitherPassedNorLive() {
        #expect(!EasternDate.runHasPassed(lastNight: nil, today: today))   // so #798 keeps it
        #expect(!EasternDate.runIsLive(lastNight: nil, today: today))      // so reconcile spares it
    }
}
