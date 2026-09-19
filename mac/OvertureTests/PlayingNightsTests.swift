import Testing
import Foundation

// #3286: "which nights does this run play" has ONE answer, and every per-night reader asks it.
//
// Three readers used to answer the empty-list case for themselves (the calendar check walked the span,
// the self-booking check took the opening alone, the night drop refused). Each was right, and each had
// to remember the case existed. These pin the shared answer and each reader's stated use of it.
@Suite("Which nights a run plays (#3286)")
struct PlayingNightsTests {

    @Test func recordedNightsAreDeduplicatedAndInDateOrder() {
        // 19 rows stored duplicates on 2026-09-17, one live row every night of a twenty night run twice.
        let playing = PlayingNights.of(runNights: ["2026-11-20", "2026-11-06", "2026-11-20", "2026-11-13"],
                                       performanceDate: "2026-11-06", runEndDate: "2026-11-20")
        #expect(playing == .recorded(["2026-11-06", "2026-11-13", "2026-11-20"]))
    }

    @Test func aSpanWithNoRecordedNightsSaysSoRatherThanReturningAnEmptyList() {
        let playing = PlayingNights.of(runNights: [], performanceDate: "2026-10-09", runEndDate: "2026-10-12")
        #expect(playing == .spanOnly(opening: "2026-10-09", lastNight: "2026-10-12"))
        #expect(playing.recordedNights == nil)
    }

    @Test func aSingleUndatedEndIsASpanOfOneNight() {
        let playing = PlayingNights.of(runNights: [], performanceDate: "2026-10-09", runEndDate: nil)
        #expect(playing == .spanOnly(opening: "2026-10-09", lastNight: "2026-10-09"))
    }

    @Test func noDateAtAllIsUndated() {
        #expect(PlayingNights.of(runNights: [], performanceDate: nil, runEndDate: nil) == .undated)
        #expect(PlayingNights.of(runNights: [], performanceDate: "", runEndDate: nil) == .undated)
    }

    // MARK: each reader's stated use of the span-only case

    // The calendar check walks the span, so a clash on a night nobody recorded is still found. Clearing a
    // real clash on no evidence is the direction that loses safety.
    @Test func theCalendarCheckWalksASpanOnlyRow() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [],
                                        exportedBlockedDates: [],
                                        daysOff: [DayOffRange(startDate: "2026-10-11", endDate: "2026-10-11",
                                                              note: "away")])
        let playing = PlayingNights.of(runNights: [], performanceDate: "2026-10-09", runEndDate: "2026-10-12")
        #expect(cal.conflict(playing)?.date == "2026-10-11")
    }

    // The self-booking reader's own answer (opening night alone) is pinned in SelfBookingRunNightsTests,
    // aRowWithNoRecordedNightsFallsBackToItsOwnDateOnly, which now reaches it through this type.

    // The per-night set: every blocked night, in order, and the card's one conflict is its first.
    @Test func blockedNightsNamesEveryBlockedNightAndConflictIsTheFirst() {
        let cal = BlockedCalendar.build(availability: .measured, bookings: [],
                                        exportedBlockedDates: [],
                                        daysOff: [DayOffRange(startDate: "2026-11-13", endDate: "2026-11-13",
                                                              note: nil),
                                                  DayOffRange(startDate: "2026-11-27", endDate: "2026-11-27",
                                                              note: nil)])
        let playing = PlayingNights.recorded(["2026-11-06", "2026-11-13", "2026-11-20", "2026-11-27"])
        #expect(cal.blockedNights(playing).map(\.date) == ["2026-11-13", "2026-11-27"])
        #expect(cal.conflict(playing)?.date == "2026-11-13")
        #expect(cal.blockedNights(.undated).isEmpty)
    }
}
