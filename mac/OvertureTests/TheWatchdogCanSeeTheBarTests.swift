import Testing
import Foundation

// #3752: the watchdog can see the stall the milestone is judged by.
//
// WHAT WENT WRONG. Milestone 80's bar, on #3660, is "a day of Dan's ordinary use produces no
// baseline-load main-thread stall over 100 ms, measured by the in-app watchdog that already writes
// freeze-log.ndjson". The watchdog's floor was 250 ms, one ping interval, so it could not report a 100 ms
// stall at all and an empty log would have read as the bar being met when it meant only that nothing
// crossed 250 ms.
//
// That is the emptiest possible failure reading as the cleanest possible pass (L98), and it sat inside
// the milestone's own success criterion from the day the bar was written. Nothing could have caught it,
// because the bar lived in an issue and the floor lived in code and no check compared them. This is that
// check.
//
// MEASURED on Dan's real log, 2026-09-10, before the change: 504 records, smallest 0.251 s. So 100% of
// recorded stalls exceeded the bar by construction and the whole sub-250ms population was invisible.
@Suite("The watchdog can see a stall the size of the bar (#3752)")
struct TheWatchdogCanSeeTheBarTests {

    // The bar, and where it comes from. A number in a test with no source is one nobody can re-check
    // (L316), so this names the issue it is quoted from rather than standing on its own.
    //
    // Deliberately NOT declared in the app: the bar is a target somebody set, not a property of the log,
    // and its wording is still open on #3660. What the app owes it is the ability to MEASURE it, which is
    // what this asserts.
    private static let barSeconds = 0.100   // #3660, milestone 80

    @Test("a stall the size of the bar is recorded rather than counted away")
    func theFloorIsAtOrBelowTheBar() {
        #expect(StallLog.floorSeconds <= Self.barSeconds,
                Comment(rawValue: "the watchdog records nothing under \(StallLog.floorSeconds)s, and the "
                        + "bar is \(Self.barSeconds)s. It cannot report a stall the size of the bar, so "
                        + "an empty log would read as the bar being met when it means only that nothing "
                        + "crossed the floor (#3660, #3752, L98)."))
    }

    // The mechanism, asserted rather than assumed: a stall exactly at the bar is KEPT as a record, and one
    // safely under it is counted instead. Without this the comparison above could hold while
    // `StallLog.adding` used some other number.
    @Test("a stall at the bar is kept and a much smaller one is counted")
    func theRetentionRuleAgreesWithTheFloor() {
        let atTheBar = record(seconds: Self.barSeconds)
        let wellUnder = record(seconds: Self.barSeconds / 4)

        let afterBar = StallLog.adding(atTheBar, to: empty).kept
        #expect(afterBar.records.count == 1,
                Comment(rawValue: "a \(Self.barSeconds)s stall was not kept as a record, so the bar cannot "
                        + "be read off the file"))
        #expect(afterBar.belowFloor == 0)

        let afterSmall = StallLog.adding(wellUnder, to: empty).kept
        #expect(afterSmall.records.isEmpty, "a stall well under the bar was stored rather than counted")
        #expect(afterSmall.belowFloor == 1,
                Comment(rawValue: "a stall under the floor must still be COUNTED, or a session of "
                        + "constant small delays is invisible rather than being one number"))
    }

    // The floor and the interval being ONE fact is #3752's other half, and it is asserted by
    // `TheAppReportsItsOwnFreezesTests.theFloorIsOnePingInterval`, which already existed. It is NOT
    // repeated here: that assertion passed the whole time the two were separate literals both equal to
    // 0.25, because equality catches drift AFTER it happens and deriving prevents it. The derivation is
    // the fix; the existing test remains the guard, and a second copy of it here would be one more thing
    // saying the same thing (L605).

    private var empty: StallLog.Kept {
        StallLog.Kept(records: [], highWater: nil, evicted: 0, belowFloor: 0)
    }

    private func record(seconds: Double) -> StallRecord {
        StallRecord(session: "s", sequence: 1, at: Date(timeIntervalSince1970: 1_000_000),
                    seconds: seconds, surface: .queue, load: .baseline, loadAverage: 1,
                    passes: nil)
    }
}
