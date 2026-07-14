import Testing
import Foundation
@testable import Overture

// #901: the days Dan cannot shoot, and WHY. The old model was a bare Set<String> of dates, which could
// only ever answer "yes or no" and so could only ever be used to silently drop a show. Dan's decision is
// that a clash is surfaced and named, so a day now carries its reason.
@Suite("Blocked calendar")
struct BlockedCalendarTests {

    private func booking(_ shoot: String, _ start: String, _ end: String? = nil) -> OvertureBooking {
        OvertureBooking(id: "b-\(shoot)", clientId: "c1", clientDisplayName: "A Client",
                        shootName: shoot, startDate: start, endDate: end ?? start,
                        venueId: nil, venueName: "Somewhere")
    }

    private func dayOff(_ start: String, _ end: String, note: String? = nil) -> DayOffRange {
        DayOffRange(startDate: start, endDate: end, note: note)
    }

    // MARK: - What blocks a day

    @Test func anEmptyCalendarBlocksNothing() {
        let cal = BlockedCalendar.build(bookings: [], exportedBlockedDates: [], daysOff: [])
        #expect(cal.conflict(performanceDate: "2026-11-14", runEndDate: nil) == nil)
    }

    @Test func aBookedShootBlocksItsDayAndNamesTheShoot() {
        let cal = BlockedCalendar.build(bookings: [booking("Smith Recital", "2026-11-14")],
                                        exportedBlockedDates: [], daysOff: [])
        let clash = cal.conflict(performanceDate: "2026-11-14", runEndDate: nil)

        #expect(clash?.kind == .bookedShoot)
        #expect(clash?.name == "Smith Recital")
        #expect(clash?.date == "2026-11-14")
    }

    // A multi-day booking blocks EVERY day it spans, not just the day it starts.
    @Test func aMultiDayBookingBlocksEveryDayItSpans() {
        let cal = BlockedCalendar.build(bookings: [booking("Festival", "2026-11-14", "2026-11-16")],
                                        exportedBlockedDates: [], daysOff: [])

        #expect(cal.conflict(performanceDate: "2026-11-15", runEndDate: nil)?.name == "Festival")
        #expect(cal.conflict(performanceDate: "2026-11-16", runEndDate: nil)?.name == "Festival")
        #expect(cal.conflict(performanceDate: "2026-11-17", runEndDate: nil) == nil)
    }

    @Test func aDayOffBlocksItsRangeAndCarriesDansNote() {
        let cal = BlockedCalendar.build(bookings: [], exportedBlockedDates: [],
                                        daysOff: [dayOff("2026-11-14", "2026-11-22", note: "Vacation")])
        let clash = cal.conflict(performanceDate: "2026-11-20", runEndDate: nil)

        #expect(clash?.kind == .dayOff)
        #expect(clash?.name == "Vacation")
        #expect(cal.conflict(performanceDate: "2026-11-23", runEndDate: nil) == nil)   // the day after he's back
    }

    // Downbeat's export carries a flat blockedDates list alongside its bookings. A day in that list with
    // no booking to name it still blocks: it is a real commitment we simply cannot label.
    @Test func anExportedBlockedDateWithNoBookingStillBlocks() {
        let cal = BlockedCalendar.build(bookings: [], exportedBlockedDates: ["2026-11-14"], daysOff: [])
        let clash = cal.conflict(performanceDate: "2026-11-14", runEndDate: nil)

        #expect(clash?.kind == .bookedShoot)
        #expect(clash?.name == nil)              // nothing to name it with, and it does not pretend otherwise
    }

    // A booked shoot outranks Dan's own day off on the same date: naming the real shoot tells him more
    // than "you're away" does, and he can act on it.
    @Test func aBookedShootOutranksADayOffOnTheSameDate() {
        let cal = BlockedCalendar.build(bookings: [booking("Smith Recital", "2026-11-14")],
                                        exportedBlockedDates: [],
                                        daysOff: [dayOff("2026-11-14", "2026-11-14", note: "Vacation")])

        #expect(cal.conflict(performanceDate: "2026-11-14", runEndDate: nil)?.kind == .bookedShoot)
    }

    // MARK: - The run trap (#901)

    // THE trap this issue names. The old check tested performanceDate alone, so a run whose LATER nights
    // land on a booked day sailed through: Dan would have been pitched a show he cannot finish.
    @Test func aRunThatOnlyCollidesOnALaterNightIsCaught() {
        let cal = BlockedCalendar.build(bookings: [booking("Smith Recital", "2026-11-16")],
                                        exportedBlockedDates: [], daysOff: [])
        let clash = cal.conflict(performanceDate: "2026-11-14", runEndDate: "2026-11-17")

        #expect(clash?.date == "2026-11-16")
        #expect(clash?.name == "Smith Recital")
    }

    @Test func aRunThatClearsEveryBlockedDayDoesNotConflict() {
        let cal = BlockedCalendar.build(bookings: [booking("Smith Recital", "2026-11-20")],
                                        exportedBlockedDates: [], daysOff: [])

        #expect(cal.conflict(performanceDate: "2026-11-14", runEndDate: "2026-11-17") == nil)
    }

    // The EARLIEST clash is the one reported, so the note names the first night he'd miss rather than
    // whichever day happened to hash first.
    @Test func theEarliestClashInARunIsTheOneReported() {
        let cal = BlockedCalendar.build(
            bookings: [booking("Later Shoot", "2026-11-17"), booking("Earlier Shoot", "2026-11-15")],
            exportedBlockedDates: [], daysOff: [])

        #expect(cal.conflict(performanceDate: "2026-11-14", runEndDate: "2026-11-18")?.name == "Earlier Shoot")
    }

    // An undated listing ("date to be confirmed") cannot collide with anything, and must not be treated
    // as if it did.
    @Test func anUndatedShowNeverConflicts() {
        let cal = BlockedCalendar.build(bookings: [booking("Smith Recital", "2026-11-14")],
                                        exportedBlockedDates: [], daysOff: [])

        #expect(cal.conflict(performanceDate: nil, runEndDate: nil) == nil)
    }

    // A scraped runEndDate is whatever the org's page said, so it can be nonsense. Expanding it blindly
    // would walk a million days. The scan is capped, and still answers.
    @Test func aNonsensicalRunEndDateDoesNotHangTheScan() {
        let cal = BlockedCalendar.build(bookings: [booking("Smith Recital", "2026-11-16")],
                                        exportedBlockedDates: [], daysOff: [])

        #expect(cal.conflict(performanceDate: "2026-11-14", runEndDate: "2999-01-01")?.date == "2026-11-16")
    }

    // A backwards range (end before start) is bad data, not a block on every day in between.
    @Test func aBackwardsRunIsJudgedOnItsOpeningNightAlone() {
        let cal = BlockedCalendar.build(bookings: [booking("Smith Recital", "2026-11-10")],
                                        exportedBlockedDates: [], daysOff: [])

        #expect(cal.conflict(performanceDate: "2026-11-14", runEndDate: "2026-11-01") == nil)
        #expect(cal.conflict(performanceDate: "2026-11-10", runEndDate: "2026-11-01")?.name == "Smith Recital")
    }

    // MARK: - What Dan reads

    @Test func aBookedShootSaysWhatHeIsShooting() {
        let day = BlockedCalendar.Day(date: "2026-11-14", kind: .bookedShoot, name: "Smith Recital")
        #expect(day.reason == "You're already shooting Smith Recital on Nov 14.")
    }

    @Test func anUnnamedBookedShootStillSaysTheDay() {
        let day = BlockedCalendar.Day(date: "2026-11-14", kind: .bookedShoot, name: nil)
        #expect(day.reason == "You're already shooting on Nov 14.")
    }

    @Test func aDayOffSaysItWasHisOwnDecisionAndWhy() {
        let day = BlockedCalendar.Day(date: "2026-11-14", kind: .dayOff, name: "Vacation")
        #expect(day.reason == "You blocked Nov 14 (Vacation).")
    }

    @Test func aDayOffWithNoNoteStillSaysTheDay() {
        let day = BlockedCalendar.Day(date: "2026-11-14", kind: .dayOff, name: nil)
        #expect(day.reason == "You blocked Nov 14.")
    }

    // MARK: - Identity, so a cleared conflict stays cleared and a CHANGED one does not (#718's pattern)

    @Test func aDaySurvivesARoundTripThroughItsKey() {
        let day = BlockedCalendar.Day(date: "2026-11-14", kind: .bookedShoot, name: "Smith Recital")
        #expect(BlockedCalendar.Day(key: day.key) == day)
    }

    // A shoot name is free text Dan typed in another app, so it can carry the separator itself.
    @Test func aNameCarryingTheSeparatorSurvivesTheRoundTrip() {
        let day = BlockedCalendar.Day(date: "2026-11-14", kind: .dayOff, name: "Away | back Monday")
        #expect(BlockedCalendar.Day(key: day.key)?.name == "Away | back Monday")
    }

    @Test func aGarbageKeyDecodesToNothingRatherThanToAWrongDay() {
        #expect(BlockedCalendar.Day(key: "nonsense") == nil)
        #expect(BlockedCalendar.Day(key: "") == nil)
    }

    // MARK: - Booked-shoot coverage (#901 part 3)

    // The trap that produced this issue: Downbeat exports zero bookings, so the conflict guard has never
    // once fired, and nothing said so. A guard protecting nothing must not look identical to one that
    // works. #925 sharpened the question from "has a booking ever existed" to "is there one from today
    // on", so this asks against a fixed `today`.
    @Test func aCalendarWithNoBookingsHasNoUpcomingShoot() {
        let cal = BlockedCalendar.build(bookings: [], exportedBlockedDates: [],
                                        daysOff: [dayOff("2099-11-14", "2099-11-22")])

        #expect(cal.hasUpcomingBookedShoot(today: "2099-01-01") == false)  // Dan's own days off are not shoots
    }

    @Test func aCalendarWithAnUpcomingBookingHasOne() {
        let cal = BlockedCalendar.build(bookings: [booking("Smith Recital", "2099-11-14")],
                                        exportedBlockedDates: [], daysOff: [])

        #expect(cal.hasUpcomingBookedShoot(today: "2099-01-01") == true)
    }
}
