import Testing
import Foundation

// #3406 and #2694: the Days off sheet lists what is still AHEAD of Dan, not every day he has ever blocked
// and every shoot he has ever worked. "I don't need to see past days. they're already gone."
//
// Filter, never delete: every rule here takes rows and returns fewer of them, and none of them touches the
// store. The past rows are still Dan's record of when he was away, and the calendar the scout judges with is
// deliberately left alone (a past night blocks nothing, and narrowing it would move the conflict keys).
//
// Today is the Eastern day the queue uses, pinned here rather than read from the clock (L130).
@Suite("The Days off sheet lists what is still ahead (#3406, #2694)")
struct DaysOffSheetShowsWhatIsAheadTests {
    private let today = "2026-09-18"

    private func booking(_ id: String, _ name: String, _ start: String, _ end: String? = nil) -> OvertureBooking {
        OvertureBooking(id: id, clientId: "c1", clientDisplayName: "A Client", shootName: name,
                        startDate: start, endDate: end ?? start, venueId: nil, venueName: "V")
    }

    // MARK: Dan's own ranges (#3406)

    @Test func aFinishedRangeIsHiddenAndOneEndingTodayStillShows() {
        let finished = DayOff(startDate: "2026-08-04", endDate: "2026-08-05", note: "Away")
        let endsYesterday = DayOff(startDate: "2026-09-17", endDate: "2026-09-17")
        let endsToday = DayOff(startDate: "2026-09-18", endDate: "2026-09-18", note: "Rehearsal")
        // A multi day block stays on the list through its last night, even though it STARTED in the past.
        let spansToday = DayOff(startDate: "2026-09-16", endDate: "2026-09-20", note: "Trip")
        let ahead = DayOff(startDate: "2026-10-09", endDate: "2026-10-12")

        let shown = DayOffEditing.upcoming([finished, endsYesterday, endsToday, spansToday, ahead], today: today)

        #expect(shown.map(\.startDate) == ["2026-09-18", "2026-09-16", "2026-10-09"])
    }

    // The empty state says what is TRUE. With past blocks and nothing ahead, "Nothing blocked" plus the
    // invitation to add a vacation reads as a claim he has never blocked anything.
    @Test func theEmptyListSaysWhetherHeHasEverBlockedAnything() {
        let never = DayOffEditing.emptyListSentence(hasPastRanges: false)
        let onlyPast = DayOffEditing.emptyListSentence(hasPastRanges: true)

        #expect(never == "Nothing blocked. Add a vacation and Overture will stop pitching you for those nights.")
        #expect(onlyPast == "Nothing blocked from today on.")
    }

    // MARK: Downbeat's booked shoots (#2694)

    @Test func aShootAlreadyWorkedIsHiddenAndTonightsStillShows() {
        let cal = BlockedCalendar.build(availability: .measured,
                                        bookings: [booking("b1", "Battery Dance Festival", "2026-08-14"),
                                                   booking("b2", "Tonight's Recital", "2026-09-18"),
                                                   booking("b3", "Winter Gala", "2026-12-05")],
                                        exportedBlockedDates: [], daysOff: [])

        #expect(cal.upcomingBookedShoots(today: today).map(\.name) == ["Tonight's Recital", "Winter Gala"])
        // The calendar itself is untouched: the past shoot still blocks its (past) night.
        #expect(cal.days.contains { $0.name == "Battery Dance Festival" })
    }

    // The list and the "Downbeat has told Overture about no upcoming shoots" sentence are one predicate, so
    // an empty list can never sit under a sheet that says shoots are coming, or the reverse (L16).
    @Test func theListAndTheNoShootsSentenceAgree() {
        let onlyPast = BlockedCalendar.build(availability: .measured,
                                             bookings: [booking("b1", "Battery Dance Festival", "2026-08-14")],
                                             exportedBlockedDates: ["2026-08-20"], daysOff: [])
        #expect(onlyPast.upcomingBookedShoots(today: today).isEmpty)
        #expect(onlyPast.hasUpcomingBookedShoot(today: today) == false)

        let oneAhead = BlockedCalendar.build(availability: .measured, bookings: [],
                                             exportedBlockedDates: ["2026-09-30"], daysOff: [])
        #expect(oneAhead.upcomingBookedShoots(today: today).count == 1)
        #expect(oneAhead.hasUpcomingBookedShoot(today: today))
    }

    // MARK: The waved through shoots, the third list on the sheet

    // A cancellation is about a BOOKING, and a booking can run several nights, so a cancellation is past only
    // once the booking's LAST night is. The row's own date is the night Dan pressed it on, which can be the
    // first of three.
    @Test func aCancelledShootIsHiddenOnceItsLastNightHasPassed() {
        let bookings = [booking("done", "Spring Recital", "2026-08-01"),
                        booking("running", "Festival Week", "2026-09-15", "2026-09-19"),
                        booking("ahead", "Winter Gala", "2026-12-05")]
        let rows = [CancelledShoot(bookingId: "done", shootName: "Spring Recital", startDate: "2026-08-01"),
                    CancelledShoot(bookingId: "running", shootName: "Festival Week", startDate: "2026-09-15"),
                    CancelledShoot(bookingId: "ahead", shootName: "Winter Gala", startDate: "2026-12-05")]

        let shown = CancelledShootEditing.upcoming(rows, bookings: bookings, today: today)

        #expect(shown.map(\.bookingId) == ["running", "ahead"])
    }

    // Downbeat stops exporting a booking only after the reconcile sweep would clear its row, but between the
    // two the row is judged by the one date it carries rather than dropped or kept on a guess.
    @Test func aCancellationWhoseBookingIsGoneIsJudgedByItsOwnDate() {
        let rows = [CancelledShoot(bookingId: "gone-past", shootName: "Old", startDate: "2026-09-01"),
                    CancelledShoot(bookingId: "gone-ahead", shootName: "New", startDate: "2026-10-01")]

        #expect(CancelledShootEditing.upcoming(rows, bookings: [], today: today).map(\.bookingId) == ["gone-ahead"])
    }

    // MARK: The sheet uses them

    // The sheet cannot be rendered in this target, so its wiring is asked of the source: each list is drawn
    // from its filter, and each heading counts what it lists (a count is a promise about the rows beneath
    // it, #863). The screenshots in the PR are what show the composed result.
    @Test func eachListOnTheSheetIsDrawnFromItsFilterAndCountsWhatItDraws() throws {
        let sheet = SourceGuardHelper.source("Overture/UI/DaysOffView.swift")
        #expect(!sheet.isEmpty, "DaysOffView.swift did not resolve; every check below is unmeasured")

        let booked = try #require(SourceGuardHelper.propertyBody("private var bookedShoots: some View {", in: sheet))
        #expect(booked.contains("cal.upcomingBookedShoots(today: today)"))
        #expect(booked.contains("count: live.count"))
        #expect(booked.contains("CancelledShootEditing.upcoming("))
        #expect(booked.contains("count: cancelled.count"))

        let mine = try #require(SourceGuardHelper.propertyBody("private var myDaysOff: some View {", in: sheet))
        #expect(mine.contains("DayOffEditing.upcoming(daysOff, today: today)"))
        #expect(mine.contains("count: shown.count"))
        #expect(mine.contains("ForEach(shown)"))
        #expect(mine.contains("DayOffEditing.emptyListSentence(hasPastRanges:"))
        #expect(!mine.contains("ForEach(daysOff)"), "the sheet lists every range ever blocked again")
    }
}
