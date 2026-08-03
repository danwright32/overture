import Testing
import Foundation

// Dan's call (2026-07-14), correcting what #901 shipped.
//
// Two things were wrong with the "no booked shoots" mark. It asked "has Downbeat EVER told me about a
// shoot", so one booking made in March turned it off forever, including in September when that shoot was
// long past and he was again protected by nothing. And it could not be dismissed, so the one honest answer
// to it ("yes, I know, I have nothing booked right now") was to ignore it, which is how a warning dies.
//
// So: it asks about UPCOMING shoots only, and he can put it away for a week at a time.
@Suite("The no-booked-shoots warning, and putting it away (#925)")
struct DaysOffSnoozeTests {
    private let today = ScoutTestClock.daysOffSnoozeAnchor
    private let now = Date(timeIntervalSince1970: 1_784_000_000)

    private func booking(_ start: String, _ end: String? = nil) -> OvertureBooking {
        OvertureBooking(id: "b-\(start)", clientId: "c1", clientDisplayName: "A Client",
                        shootName: "Nguyen Recital", startDate: start, endDate: end ?? start,
                        venueId: nil, venueName: "V")
    }

    private func calendar(_ bookings: [OvertureBooking]) -> BlockedCalendar {
        BlockedCalendar.build(bookings: bookings, exportedBlockedDates: [], daysOff: [])
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "daysoff-\(UUID().uuidString)")!
    }

    // MARK: - A past shoot proves nothing about now

    // THE correction. Downbeat exports every committed booking it has ever held, with no date filter
    // (OvertureExportService.swift:45), so "we have seen a booking" stays true forever after the first
    // one. It says the pipe once worked. It says nothing about whether Overture can keep clear of Dan's
    // schedule TODAY, which is the only thing the mark is for.
    @Test func aBookingThatHasAlreadyHappenedDoesNotCount() {
        let cal = calendar([booking("2026-03-01")])          // months before `today`

        #expect(cal.hasUpcomingBookedShoot(today: today) == false)
    }

    @Test func aShootFromTodayOnwardCounts() {
        #expect(calendar([booking("2026-07-14")]).hasUpcomingBookedShoot(today: today))   // today itself
        #expect(calendar([booking("2026-09-01")]).hasUpcomingBookedShoot(today: today))
    }

    // A multi-day shoot that started yesterday and runs through tomorrow is still work he is doing.
    @Test func aShootAlreadyUnderwayCounts() {
        #expect(calendar([booking("2026-07-13", "2026-07-16")]).hasUpcomingBookedShoot(today: today))
    }

    // Dan's own days off are not shoots, and never silence this: a vacation says nothing about the work
    // he has taken on.
    @Test func hisOwnDaysOffAreNotBookedShoots() {
        let cal = BlockedCalendar.build(bookings: [], exportedBlockedDates: [],
                                        daysOff: [DayOffRange(startDate: "2026-08-01", endDate: "2026-08-09", note: nil)])

        #expect(cal.hasUpcomingBookedShoot(today: today) == false)
    }

    // MARK: - Putting it away for a week

    @Test func itWarnsWhenThereIsNoUpcomingShootAndNothingIsSnoozed() {
        let d = defaults()
        #expect(DaysOffAttention.needsALook(calendar([]), today: today, now: now, defaults: d))
    }

    @Test func dismissingItSilencesItForAWeek() {
        let d = defaults()
        DaysOffAttention.snooze(now: now, into: d)

        #expect(DaysOffAttention.needsALook(calendar([]), today: today, now: now, defaults: d) == false)
        // Six days later: still away.
        let sixDays = now.addingTimeInterval(6 * 86_400)
        #expect(DaysOffAttention.needsALook(calendar([]), today: today, now: sixDays, defaults: d) == false)
    }

    @Test func afterTheWeekItComesBackIfHeStillHasNothingBooked() {
        let d = defaults()
        DaysOffAttention.snooze(now: now, into: d)
        let eightDays = now.addingTimeInterval(8 * 86_400)

        #expect(DaysOffAttention.needsALook(calendar([]), today: today, now: eightDays, defaults: d))
    }

    // The snooze hides a warning; it does not hide a FACT. Once a real upcoming shoot exists, the mark is
    // off on its own merits, and a stale snooze underneath it changes nothing.
    @Test func aRealBookingSilencesItWhetherOrNotHeDismissedIt() {
        let d = defaults()
        let cal = calendar([booking("2026-09-01")])

        #expect(DaysOffAttention.needsALook(cal, today: today, now: now, defaults: d) == false)
        DaysOffAttention.snooze(now: now, into: d)
        #expect(DaysOffAttention.needsALook(cal, today: today, now: now, defaults: d) == false)
    }

    // Dismissing it AGAIN after it returns gives another full week, rather than counting from the first
    // time he ever dismissed it (which would make the button do nothing on the second press).
    @Test func dismissingItAgainBuysAnotherWeek() {
        let d = defaults()
        DaysOffAttention.snooze(now: now, into: d)
        let eightDays = now.addingTimeInterval(8 * 86_400)
        #expect(DaysOffAttention.needsALook(calendar([]), today: today, now: eightDays, defaults: d))

        DaysOffAttention.snooze(now: eightDays, into: d)

        #expect(DaysOffAttention.needsALook(calendar([]), today: today, now: eightDays, defaults: d) == false)
        let twelveDays = now.addingTimeInterval(12 * 86_400)
        #expect(DaysOffAttention.needsALook(calendar([]), today: today, now: twelveDays, defaults: d) == false)
    }

    // MARK: - What Dan reads

    @Test func theDismissSaysExactlyWhatItDoes() {
        #expect(DaysOffAttention.snoozeButtonTitle == "Hide this for a week")
    }

    // It never claims the problem is solved. It says the warning is away, and when it is coming back.
    @Test func theBannerDoesNotPretendTheGapIsClosed() {
        #expect(ActionAck.daysOffSnoozed() == "Hidden for a week. Overture still can't keep clear of shoots it doesn't know about.")
    }
}
