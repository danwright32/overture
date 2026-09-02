import Testing
import Foundation
import SwiftData

// #1523: a run is conflict-checked against every DAY in its span, not the nights it actually plays.
//
// `BlockedCalendar.conflict` walks `EasternDate.days(from:through:)` between the opening and closing
// night. That is right for a run that plays every night and wrong for everything else. `The Lineup with
// Susie Mosher` plays sixteen Tuesdays spread across 106 days; Overture checks all 106, so a shoot on any
// Wednesday in October flags a show that does not play Wednesdays.
//
// LIVE-STORE-CLAIM verified=2026-07-26 measure="runs flagged against one booked shoot, and which night actually clashed"
// Measured on the live store 2026-07-26, all three flagged against the same booked shoot on FRIDAY
// 2026-07-31: `The Lineup with Susie Mosher` (106 day span, opens and closes on a Tuesday, does not play
// that Friday), `Max Davidson: Strangers` (107 days), and `Hungry Women` (39 days). Nine further runs
// span 50 to 127 days and will do the same the moment Dan blocks a day inside their window.
//
// DAN'S CALL, 2026-07-26, and it reverses this issue's original suggested fix: "I think I'd want it to be
// one long run. I'm not going to send them an email every week pitching the show. I'm going to pitch it
// once." So the grouping stays exactly as it is, one production and one card. What changes is that the
// run carries the nights it plays, and the conflict asks about those.
@Suite("A run's conflict is judged on the nights it plays (#1523)")
struct RunConflictUsesRealNightsTests {

    // Dan's real shoot, on the date all three false flags point at. 2026-07-31 is a Friday.
    private func calendarBlocking(_ dates: [String]) -> BlockedCalendar {
        BlockedCalendar.build(availability: .measured, bookings: [], exportedBlockedDates: dates, daysOff: [])
    }

    // Tuesdays. The run opens 2026-07-28 and closes 2026-08-11, so the span contains the blocked Friday
    // but the show is dark that night.
    private let tuesdays = ["2026-07-28", "2026-08-04", "2026-08-11"]

    @Test func aWeeklyRunIsNotFlaggedByADayOffOnANightItDoesNotPlay() {
        let blocked = calendarBlocking(["2026-07-31"])

        let clash = blocked.conflict(performanceDate: tuesdays.first, runEndDate: tuesdays.last,
                                     nights: tuesdays)

        #expect(clash == nil, "a Tuesday-only run must not clash with a Friday shoot inside its span")
    }

    // The other half, and the one that must never regress: when the blocked day IS one of its nights, the
    // clash is real and has to be reported, naming that night.
    @Test func aWeeklyRunIsStillFlaggedWhenTheBlockedDayIsOneOfItsNights() {
        let blocked = calendarBlocking(["2026-08-04"])

        let clash = blocked.conflict(performanceDate: tuesdays.first, runEndDate: tuesdays.last,
                                     nights: tuesdays)

        #expect(clash?.date == "2026-08-04")
    }

    // #901's original trap, unchanged: a nightly run whose MIDDLE night is blocked still flags, because
    // Dan would be pitching a show he could not finish.
    @Test func aNightlyRunStillFlagsAnyNightInsideIt() {
        let nights = ["2026-07-23", "2026-07-24", "2026-07-25", "2026-07-26"]
        let blocked = calendarBlocking(["2026-07-25"])

        let clash = blocked.conflict(performanceDate: nights.first, runEndDate: nights.last, nights: nights)

        #expect(clash?.date == "2026-07-25")
    }

    // The earliest clashing night wins, so the warning names the first one Dan would miss rather than an
    // arbitrary one.
    @Test func theFirstClashingNightIsTheOneReported() {
        let blocked = calendarBlocking(["2026-08-11", "2026-08-04"])

        let clash = blocked.conflict(performanceDate: tuesdays.first, runEndDate: tuesdays.last,
                                     nights: tuesdays)

        #expect(clash?.date == "2026-08-04")
    }

    // Every prospect already in Dan's store predates this and carries no recorded nights. Those must keep
    // the old span behaviour exactly, so shipping this cannot silently clear a conflict that was real. They
    // self-heal on the next scout, which records the nights.
    @Test func aRunWithNoRecordedNightsFallsBackToTheWholeSpan() {
        let blocked = calendarBlocking(["2026-07-31"])

        let clash = blocked.conflict(performanceDate: "2026-07-28", runEndDate: "2026-08-11", nights: [])

        #expect(clash?.date == "2026-07-31", "with no nights recorded, the old span walk is all we have")
    }

    // A single-night show is its own run and is unaffected either way.
    @Test func aSingleNightShowIsUnaffected() {
        let blocked = calendarBlocking(["2026-07-31"])

        #expect(blocked.conflict(performanceDate: "2026-07-31", runEndDate: nil,
                                 nights: ["2026-07-31"])?.date == "2026-07-31")
        #expect(blocked.conflict(performanceDate: "2026-08-01", runEndDate: nil,
                                 nights: ["2026-08-01"]) == nil)
    }

    // A date Overture never learned collides with nothing, unchanged (#901).
    @Test func anUndatedShowCollidesWithNothing() {
        #expect(calendarBlocking(["2026-07-31"]).conflict(performanceDate: nil, runEndDate: nil,
                                                          nights: []) == nil)
    }

    // MARK: - The wiring, which is a second claim (#887)

    // The rule above is only true on Dan's screen if the run's nights actually REACH it. They have to
    // survive grouping, assembly, and the store. Without this, every unit test above passes while the
    // scout still stamps a false conflict, because it hands the check an empty list forever.
    //
    // This is The Lineup in miniature: a Tuesday series ingested against a calendar holding Dan's real
    // 2026-07-31 shoot, which falls inside the span and on none of its nights.
    @MainActor
    @Test func aScoutedWeeklyRunIsNotStampedWithAFalseConflict() throws {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let series = "lineup-tuesdays"
        let events = tuesdays.map {
            ExtractedEvent(title: "The Lineup with Susie Mosher", presenter: nil,
                           venue: "The Green Room 42", performanceDate: $0, sourceUrl: nil,
                           location: "New York, NY", seriesId: series)
        }

        _ = ScoutService.apply(events: events, clients: [], history: [],
                               blocked: calendarBlocking(["2026-07-31"]),
                               today: "2026-07-27", into: context)

        let all = try context.fetch(FetchDescriptor<Prospect>())
        let show = try #require(all.first)
        #expect(all.count == 1)                      // one production, one card: Dan pitches it once
        #expect(show.runNights == tuesdays)           // the nights survived into the store
        #expect(show.conflictKey == nil, "a Tuesday run must not be flagged by a Friday shoot")
    }

    // And the same wiring must still stamp a REAL clash, or this change would have quietly disarmed the
    // whole feature rather than sharpened it.
    @MainActor
    @Test func aScoutedRunIsStillStampedWhenTheShootLandsOnOneOfItsNights() throws {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)
        let events = tuesdays.map {
            ExtractedEvent(title: "The Lineup with Susie Mosher", presenter: nil,
                           venue: "The Green Room 42", performanceDate: $0, sourceUrl: nil,
                           location: "New York, NY", seriesId: "lineup-tuesdays")
        }

        _ = ScoutService.apply(events: events, clients: [], history: [],
                               blocked: calendarBlocking(["2026-08-04"]),
                               today: "2026-07-27", into: context)

        let show = try #require(try context.fetch(FetchDescriptor<Prospect>()).first)
        #expect(show.conflictKey != nil)
        #expect(show.conflictKey?.contains("2026-08-04") == true)
    }
}
