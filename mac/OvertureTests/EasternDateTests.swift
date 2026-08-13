import Testing
import Foundation

// One shared source of truth for Overture's date math, which is ALWAYS reckoned in New York time
// (#116). Consolidates the Eastern day-string logic that was duplicated in QueueModel and
// BookingMatch, and is the basis for the conversation-reminder event-aware timing (#111). All
// "is it past / how many days until the show" questions go through here so nothing drifts a day
// across UTC or the Mac's local zone near midnight.
@Suite("Eastern date helper")
struct EasternDateTests {
    // A Date at a specific UTC wall-clock instant, for testing the zone conversion.
    private func utcInstant(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    @Test func todayUsesEasternNotUTCInSummer() {
        // 2026-06-15 02:00 UTC is 2026-06-14 22:00 EDT (UTC-4): the Eastern day is the 14th.
        #expect(EasternDate.today(utcInstant(2026, 6, 15, 2, 0)) == "2026-06-14")
    }

    @Test func todayUsesEasternNotUTCInWinter() {
        // 2026-01-15 02:00 UTC is 2026-01-14 21:00 EST (UTC-5): the Eastern day is the 14th.
        #expect(EasternDate.today(utcInstant(2026, 1, 15, 2, 0)) == "2026-01-14")
    }

    @Test func dayStringMatchesTodayForTheSameInstant() {
        let instant = utcInstant(2026, 6, 15, 2, 0)
        #expect(EasternDate.dayString(from: instant) == "2026-06-14")
    }

    @Test func daysUntilCountsWholeEasternDays() {
        #expect(EasternDate.daysUntil(from: "2026-06-14", to: "2026-06-20") == 6)
    }

    @Test func daysUntilIsZeroOnTheSameDay() {
        #expect(EasternDate.daysUntil(from: "2026-06-20", to: "2026-06-20") == 0)
    }

    @Test func daysUntilIsNegativeForAPastTarget() {
        #expect(EasternDate.daysUntil(from: "2026-06-20", to: "2026-06-14") == -6)
    }

    @Test func daysUntilIsNilForAnUnparseableDay() {
        #expect(EasternDate.daysUntil(from: "garbage", to: "2026-06-20") == nil)
    }

    // MARK: the spelled-out day (#2615)
    //
    // Overture's own surfaces read "Aug 11" because they are dense lists. An outbound sentence under
    // Dan's name is prose, so it spells the month out.

    @Test func longDayLabelSpellsTheMonthOut() {
        #expect(EasternDate.longDayLabel("2026-08-11") == "August 11")
        #expect(EasternDate.longDayLabel("2026-09-01") == "September 1")
    }

    @Test func longDayLabelIsNilForAnUnparseableDay() {
        // Nil rather than a plausible-looking wrong date, the same contract as dayLabel: a caller has
        // to say what it shows instead.
        #expect(EasternDate.longDayLabel("garbage") == nil)
        #expect(EasternDate.longDayLabel("") == nil)
    }

    // The two month vocabularies must agree, month for month, or one surface names August while the
    // other names September (L41: a list mirroring another is derived from it, never kept beside it).
    @Test func theShortMonthIsAlwaysThePrefixOfTheLongOne() {
        for month in 1...12 {
            let short = EasternDate.shortMonth(month)
            let long = EasternDate.longMonth(month)
            #expect(short.count == 3)
            #expect(long.hasPrefix(short), "\(long) does not start with \(short)")
        }
    }
}
