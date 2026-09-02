import Testing
import Foundation

// #901: the days Dan cannot shoot, and WHY. The old model was a bare Set<String> of dates, which could
// only ever answer "yes or no" and so could only ever be used to silently drop a show. Dan's decision is
// that a clash is surfaced and named, so a day now carries its reason.
@Suite("Blocked calendar")
struct BlockedCalendarTests {

    private func booking(_ shoot: String, _ start: String, _ end: String? = nil,
                         id: String? = nil) -> OvertureBooking {
        OvertureBooking(id: id ?? "b-\(shoot)", clientId: "c1", clientDisplayName: "A Client",
                        shootName: shoot, startDate: start, endDate: end ?? start,
                        venueId: nil, venueName: "Somewhere")
    }

    private func dayOff(_ start: String, _ end: String, note: String? = nil) -> DayOffRange {
        DayOffRange(startDate: start, endDate: end, note: note)
    }

    // MARK: - What blocks a day

    @Test func anEmptyCalendarBlocksNothing() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [], exportedBlockedDates: [], daysOff: [])
        #expect(cal.conflict(performanceDate: "2026-11-14", runEndDate: nil) == nil)
    }

    @Test func aBookedShootBlocksItsDayAndNamesTheShoot() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [booking("Smith Recital", "2026-11-14")],
                                        exportedBlockedDates: [], daysOff: [])
        let clash = cal.conflict(performanceDate: "2026-11-14", runEndDate: nil)

        #expect(clash?.kind == .bookedShoot)
        #expect(clash?.name == "Smith Recital")
        #expect(clash?.date == "2026-11-14")
    }

    // A multi-day booking blocks EVERY day it spans, not just the day it starts.
    @Test func aMultiDayBookingBlocksEveryDayItSpans() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [booking("Festival", "2026-11-14", "2026-11-16")],
                                        exportedBlockedDates: [], daysOff: [])

        #expect(cal.conflict(performanceDate: "2026-11-15", runEndDate: nil)?.name == "Festival")
        #expect(cal.conflict(performanceDate: "2026-11-16", runEndDate: nil)?.name == "Festival")
        #expect(cal.conflict(performanceDate: "2026-11-17", runEndDate: nil) == nil)
    }

    @Test func aDayOffBlocksItsRangeAndCarriesDansNote() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [], exportedBlockedDates: [],
                                        daysOff: [dayOff("2026-11-14", "2026-11-22", note: "Vacation")])
        let clash = cal.conflict(performanceDate: "2026-11-20", runEndDate: nil)

        #expect(clash?.kind == .dayOff)
        #expect(clash?.name == "Vacation")
        #expect(cal.conflict(performanceDate: "2026-11-23", runEndDate: nil) == nil)   // the day after he's back
    }

    // Downbeat's export carries a flat blockedDates list alongside its bookings. A day in that list with
    // no booking to name it still blocks: it is a real commitment we simply cannot label.
    @Test func anExportedBlockedDateWithNoBookingStillBlocks() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [], exportedBlockedDates: ["2026-11-14"], daysOff: [])
        let clash = cal.conflict(performanceDate: "2026-11-14", runEndDate: nil)

        #expect(clash?.kind == .bookedShoot)
        #expect(clash?.name == nil)              // nothing to name it with, and it does not pretend otherwise
    }

    // A booked shoot outranks Dan's own day off on the same date: naming the real shoot tells him more
    // than "you're away" does, and he can act on it.
    @Test func aBookedShootOutranksADayOffOnTheSameDate() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [booking("Smith Recital", "2026-11-14")],
                                        exportedBlockedDates: [],
                                        daysOff: [dayOff("2026-11-14", "2026-11-14", note: "Vacation")])

        #expect(cal.conflict(performanceDate: "2026-11-14", runEndDate: nil)?.kind == .bookedShoot)
    }

    // MARK: - The run trap (#901)

    // THE trap this issue names. The old check tested performanceDate alone, so a run whose LATER nights
    // land on a booked day sailed through: Dan would have been pitched a show he cannot finish.
    @Test func aRunThatOnlyCollidesOnALaterNightIsCaught() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [booking("Smith Recital", "2026-11-16")],
                                        exportedBlockedDates: [], daysOff: [])
        let clash = cal.conflict(performanceDate: "2026-11-14", runEndDate: "2026-11-17")

        #expect(clash?.date == "2026-11-16")
        #expect(clash?.name == "Smith Recital")
    }

    @Test func aRunThatClearsEveryBlockedDayDoesNotConflict() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [booking("Smith Recital", "2026-11-20")],
                                        exportedBlockedDates: [], daysOff: [])

        #expect(cal.conflict(performanceDate: "2026-11-14", runEndDate: "2026-11-17") == nil)
    }

    // The EARLIEST clash is the one reported, so the note names the first night he'd miss rather than
    // whichever day happened to hash first.
    @Test func theEarliestClashInARunIsTheOneReported() {
        let cal = BlockedCalendar.build(availability: .measured, 
            bookings: [booking("Later Shoot", "2026-11-17"), booking("Earlier Shoot", "2026-11-15")],
            exportedBlockedDates: [], daysOff: [])

        #expect(cal.conflict(performanceDate: "2026-11-14", runEndDate: "2026-11-18")?.name == "Earlier Shoot")
    }

    // An undated listing ("date to be confirmed") cannot collide with anything, and must not be treated
    // as if it did.
    @Test func anUndatedShowNeverConflicts() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [booking("Smith Recital", "2026-11-14")],
                                        exportedBlockedDates: [], daysOff: [])

        #expect(cal.conflict(performanceDate: nil, runEndDate: nil) == nil)
    }

    // A scraped runEndDate is whatever the org's page said, so it can be nonsense. Expanding it blindly
    // would walk a million days. The scan is capped, and still answers.
    @Test func aNonsensicalRunEndDateDoesNotHangTheScan() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [booking("Smith Recital", "2026-11-16")],
                                        exportedBlockedDates: [], daysOff: [])

        #expect(cal.conflict(performanceDate: "2026-11-14", runEndDate: "2999-01-01")?.date == "2026-11-16")
    }

    // A backwards range (end before start) is bad data, not a block on every day in between.
    @Test func aBackwardsRunIsJudgedOnItsOpeningNightAlone() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [booking("Smith Recital", "2026-11-10")],
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
        let cal = BlockedCalendar.build(availability: .measured, bookings: [], exportedBlockedDates: [],
                                        daysOff: [dayOff("2099-11-14", "2099-11-22")])

        #expect(cal.hasUpcomingBookedShoot(today: ScoutTestClock.farFuture) == false)  // Dan's own days off are not shoots
    }

    @Test func aCalendarWithAnUpcomingBookingHasOne() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [booking("Smith Recital", "2099-11-14")],
                                        exportedBlockedDates: [], daysOff: [])

        #expect(cal.hasUpcomingBookedShoot(today: ScoutTestClock.farFuture) == true)
    }

    // MARK: - Two shoots on one night (#2693)

    // The defect: the store was one entry per DATE, so the second booking on a night overwrote the first
    // and was invisible everywhere. The days off sheet, whose whole job is telling Dan what he already has
    // on, under-reported it with nothing saying anything was missing.
    @Test func bothShootsOnOneNightAreListed() {
        let cal = BlockedCalendar.build(availability: .measured, 
            bookings: [booking("Firebird Pops Orchestra", "2027-02-14"),
                       booking("Feb14 Show - Potentially not happening - confirm", "2027-02-14")],
            exportedBlockedDates: [], daysOff: [])

        #expect(cal.days.filter { $0.kind == .bookedShoot }.map(\.name)
                == ["Feb14 Show - Potentially not happening - confirm", "Firebird Pops Orchestra"])
    }

    // Dan's real export, measured 2026-08-15: fifteen bookings across thirteen dates, two of those dates
    // carrying two shoots, and every future booking date ALSO present in `blockedDates`. That last part is
    // what makes a naive "list them all" wrong: it would double every one of them.
    private static let liveBookings: [(name: String, date: String)] = [
        ("Battery Dance Festival", "2026-08-14"),
        ("Spirit of Freedom", "2026-11-16"),
        ("Total Vocal", "2026-11-24"),
        ("A Gospel of Gratitude", "2026-11-28"),
        ("Sorenson and Rutter", "2026-12-01"),
        ("Barnwell, LaBarr, and Pederson", "2027-01-17"),
        ("The Music of Sir Karl Jenkins", "2027-01-18"),
        ("Feb14 Show - Potentially not happening - confirm", "2027-02-14"),
        ("Firebird Pops Orchestra", "2027-02-14"),
        ("The Music of Jennifer Lucy Cook", "2027-04-03"),
        ("April20 Show - Potentially not happening - confirm", "2027-04-20"),
        ("May1 Show - Potentially not happening - confirm", "2027-05-01"),
        ("Sorenson and DiOrio", "2027-05-30"),
        ("God Lives in Glass", "2027-05-30"),
        ("Requiem for the Living", "2027-06-13"),
    ]

    private static let liveBlockedDates = ["2026-11-16", "2026-11-24", "2026-11-28", "2026-12-01",
                                           "2027-01-17", "2027-01-18", "2027-02-14", "2027-04-03",
                                           "2027-04-20", "2027-05-01", "2027-05-30", "2027-06-13"]

    @Test func theLiveExportsFifteenBookingsAllReachTheSheet() {
        let cal = BlockedCalendar.build(availability: .measured, 
            bookings: Self.liveBookings.map { booking($0.name, $0.date) },
            exportedBlockedDates: Self.liveBlockedDates, daysOff: [])

        let booked = cal.days.filter { $0.kind == .bookedShoot }
        #expect(booked.count == 15)                                   // it showed 13
        #expect(booked.filter { $0.date == "2027-02-14" }.map(\.name)
                == ["Feb14 Show - Potentially not happening - confirm", "Firebird Pops Orchestra"])
        #expect(booked.filter { $0.date == "2027-05-30" }.map(\.name)
                == ["God Lives in Glass", "Sorenson and DiOrio"])
    }

    // The other half of that: an exported date is a booking's date on the live export, so it must not sit
    // beside the booking as a second, unnamed row.
    @Test func anExportedBlockedDateAddsNoRowToANightABookingAlreadyNames() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [booking("Smith Recital", "2026-11-14")],
                                        exportedBlockedDates: ["2026-11-14"], daysOff: [])

        #expect(cal.days.map(\.name) == ["Smith Recital"])
    }

    // Two bookings identical in name and date are ONE fact to everything downstream: the same key, the
    // same sentence, the same row. Keeping both would hand the sheet two rows sharing an id.
    @Test func twoBookingsAlikeInNameAndDateAreOneRow() {
        let cal = BlockedCalendar.build(availability: .measured, 
            bookings: [booking("Total Vocal", "2026-11-24", id: "one"),
                       booking("Total Vocal", "2026-11-24", id: "two")],
            exportedBlockedDates: [], daysOff: [])

        #expect(cal.days.count == 1)
    }

    // WHICH of two shoots the stored key names must not depend on the order Downbeat happened to list
    // them in. The key is Dan's acceptance ("I can shoot this anyway"), so a reordered export that moves
    // it re-blocks a night he has already waved through, for no change in his calendar at all.
    @Test func theConflictKeyDoesNotMoveWhenTheExportListsTheSameTwoBookingsTheOtherWayRound() {
        let one = booking("Sorenson and DiOrio", "2027-05-30")
        let other = booking("God Lives in Glass", "2027-05-30")
        let asExported = BlockedCalendar.build(availability: .measured, bookings: [one, other],
                                               exportedBlockedDates: [], daysOff: [])
        let reordered = BlockedCalendar.build(availability: .measured, bookings: [other, one],
                                              exportedBlockedDates: [], daysOff: [])

        #expect(asExported.conflict(performanceDate: "2027-05-30", runEndDate: nil)?.key
                == reordered.conflict(performanceDate: "2027-05-30", runEndDate: nil)?.key)
    }

    // A night holding two shoots still answers the one question a conflict asks with ONE day, because the
    // prospect stores one key. Which one is settled here (by name) rather than by the export.
    @Test func aNightWithTwoShootsStillReportsASingleNamedConflict() {
        let cal = BlockedCalendar.build(availability: .measured, 
            bookings: [booking("Sorenson and DiOrio", "2027-05-30"),
                       booking("God Lives in Glass", "2027-05-30")],
            exportedBlockedDates: [], daysOff: [])
        let clash = cal.conflict(performanceDate: "2027-05-30", runEndDate: nil)

        #expect(clash?.name == "God Lives in Glass")
        #expect(clash?.reason == "You're already shooting God Lives in Glass on May 30.")
    }

    // The same question asked of Dan's own half, which is where the identical defect could sit: two of
    // his ranges can overlap, one entry per date keeps one of their notes, and the stored key carries that
    // note. Both ranges are listed in full on the sheet from the stored rows, so nothing is hidden the way
    // a lost booking was, but WHICH note the key quotes must still not depend on the order the rows came
    // back in, or the same re-block happens for no change he made.
    @Test func theDayOffKeyDoesNotMoveWhenTwoOverlappingRangesArriveInADifferentOrder() {
        let early = dayOff("2026-11-10", "2026-11-16", note: "Vacation")
        let late = dayOff("2026-11-14", "2026-11-22", note: "Away for a wedding")
        let one = BlockedCalendar.build(availability: .measured, bookings: [], exportedBlockedDates: [], daysOff: [early, late])
        let other = BlockedCalendar.build(availability: .measured, bookings: [], exportedBlockedDates: [], daysOff: [late, early])

        #expect(one.conflict(performanceDate: "2026-11-14", runEndDate: nil)?.key
                == other.conflict(performanceDate: "2026-11-14", runEndDate: nil)?.key)
    }

    // Precedence is unchanged where a booked shoot lands on a day off, and the day off does not turn up in
    // the sheet's booked list beside the shoots that outranked it.
    @Test func aDayOffUnderTwoBookedShootsIsNotListedAtAll() {
        let cal = BlockedCalendar.build(availability: .measured, 
            bookings: [booking("Sorenson and DiOrio", "2027-05-30"),
                       booking("God Lives in Glass", "2027-05-30")],
            exportedBlockedDates: [],
            daysOff: [dayOff("2027-05-30", "2027-05-30", note: "Vacation")])

        #expect(cal.days.allSatisfy { $0.kind == .bookedShoot })
        #expect(cal.days.count == 2)
    }
}
