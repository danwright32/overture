import Testing
import Foundation
import SwiftData

// #1699 / #1984, the WIRING, which is a second claim (the #887 lesson, and the shape
// RunConflictUsesRealNightsTests uses for the same reason).
//
// `RunStartTimes.across` and `ClockTime.listLabel` are both unit tested, and both can be perfectly
// correct while Dan's card still shows nothing, because the times have to survive assembly, run grouping
// and the store to reach him. A rule nothing reaches is a rule that does not exist.
@Suite("A published start time reaches the store (#1699)")
struct StartTimeReachesTheStoreTests {
    // Nothing in Dan's calendar: these tests are about the start time, not about conflicts.
    private let clearCalendar = BlockedCalendar.build(bookings: [], exportedBlockedDates: [], daysOff: [])

    private func context() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    private func event(_ date: String, startTimes: [String], series: String? = nil,
                       title: String = "Hungry Women") -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: nil, venue: "SoHo Playhouse",
                       performanceDate: date, sourceUrl: nil, location: "New York, NY",
                       seriesId: series, startTimes: startTimes)
    }

    @MainActor
    @Test func aSingleNightShowKeepsItsPublishedTime() throws {
        let ctx = try context()
        _ = ScoutService.apply(events: [event("2026-08-06", startTimes: ["19:00"])],
                               clients: [], history: [], blocked: clearCalendar,
                               today: "2026-08-02", into: ctx)

        let show = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)
        #expect(show.performanceStartTimes == ["19:00"])
        #expect(show.startTimesVary == false)
    }

    // #1984's double bill, all the way through. Both performances survive to the store, so the card can
    // name both instead of claiming the day starts at the first.
    @MainActor
    @Test func aDoubleBillKeepsBothOfItsTimes() throws {
        let ctx = try context()
        _ = ScoutService.apply(events: [event("2026-08-08", startTimes: ["17:00", "21:15"])],
                               clients: [], history: [], blocked: clearCalendar,
                               today: "2026-08-02", into: ctx)

        let show = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)
        #expect(show.performanceStartTimes == ["17:00", "21:15"])
        #expect(show.startTimesVary == false)
    }

    // A run collapses to ONE card, so its stored time is a claim about every night. All three nights here
    // are 7:00 PM, so the claim is true and the card may state it.
    @MainActor
    @Test func aRunWhoseNightsAgreeStoresTheSharedTime() throws {
        let ctx = try context()
        let nights = ["2026-07-23", "2026-07-24", "2026-07-25"]
        _ = ScoutService.apply(events: nights.map { event($0, startTimes: ["19:00"], series: "p1") },
                               clients: [], history: [], blocked: clearCalendar,
                               today: "2026-07-20", into: ctx)

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.count == 1)                       // one production, one card
        let show = try #require(all.first)
        #expect(show.performanceStartTimes == ["19:00"])
        #expect(show.startTimesVary == false)
    }

    // The Players Theatre's real shape: weeknights at 7:00 PM, a Sunday matinee at 2:00 PM. The card must
    // NOT pick one, so the store records that they vary and the card says so (Dan's call, 2026-08-02).
    @MainActor
    @Test func aRunWhoseNightsDifferIsRecordedAsVarying() throws {
        let ctx = try context()
        let events = [event("2026-09-26", startTimes: ["19:00"], series: "p2"),
                      event("2026-09-27", startTimes: ["14:00"], series: "p2"),
                      event("2026-09-28", startTimes: ["19:00"], series: "p2")]
        _ = ScoutService.apply(events: events, clients: [], history: [], blocked: clearCalendar,
                               today: "2026-09-20", into: ctx)

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.count == 1)
        let show = try #require(all.first)
        #expect(show.startTimesVary == true)
        // And it must not ALSO be carrying one night's time, or the card could state it and contradict
        // the flag beside it.
        #expect(show.performanceStartTimes.isEmpty)
    }

    // #1699, Dan's call (2026-08-02) after the real measurement: a run whose nights differ keeps EVERY
    // night's times, so the card can say "Times vary" and the hover can show the actual schedule. This is
    // the reversal of the earlier decision to discard them, which was made on the assumption that varying
    // runs were rare; measured against his two live venues they are the MAJORITY (16 of 30 timed cards).
    @MainActor
    @Test func aVaryingRunKeepsEveryNightsTimesForTheHover() throws {
        let ctx = try context()
        let events = [event("2026-09-26", startTimes: ["15:00"], series: "p3"),
                      event("2026-09-27", startTimes: ["11:00", "14:00"], series: "p3")]
        _ = ScoutService.apply(events: events, clients: [], history: [], blocked: clearCalendar,
                               today: "2026-09-20", into: ctx)

        let show = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)
        #expect(show.startTimesVary == true)
        #expect(show.nightStartTimes.sorted()
                == ["2026-09-26 15:00", "2026-09-27 11:00", "2026-09-27 14:00"])
    }

    // The majority of sources publish no time at all. Those rows must be indistinguishable from today's,
    // and must NOT borrow the "times vary" sentence, which is a different fact about a different thing.
    @MainActor
    @Test func aShowWhoseSourcePublishedNoTimeStoresNothingAndDoesNotVary() throws {
        let ctx = try context()
        _ = ScoutService.apply(events: [event("2026-08-06", startTimes: [])],
                               clients: [], history: [], blocked: clearCalendar,
                               today: "2026-08-02", into: ctx)

        let show = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first)
        #expect(show.performanceStartTimes.isEmpty)
        #expect(show.startTimesVary == false)
    }

    // Dan's call (2026-08-02): the NEWEST read wins, including when it is empty. A show that gets
    // rescheduled must never keep advertising yesterday's curtain time, which is the failure that could
    // actually cost him a shoot; losing a time on a feed that went quiet is the cheaper error.
    @MainActor
    @Test func aLaterScoutThatPublishesNoTimeClearsTheOldOne() throws {
        let ctx = try context()
        _ = ScoutService.apply(events: [event("2026-08-06", startTimes: ["19:00"])],
                               clients: [], history: [], blocked: clearCalendar,
                               today: "2026-08-02", into: ctx)
        _ = ScoutService.apply(events: [event("2026-08-06", startTimes: [])],
                               clients: [], history: [], blocked: clearCalendar,
                               today: "2026-08-02", into: ctx)

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.count == 1, "the same show must refresh in place, not duplicate")
        #expect(try #require(all.first).performanceStartTimes.isEmpty)
    }

    // And a CHANGED time reaches the store on the refresh, which is the same rule's useful half: a show
    // moved from 7:00 PM to 8:00 PM says 8:00 PM.
    @MainActor
    @Test func aLaterScoutWithANewTimeReplacesTheOldOne() throws {
        let ctx = try context()
        _ = ScoutService.apply(events: [event("2026-08-06", startTimes: ["19:00"])],
                               clients: [], history: [], blocked: clearCalendar,
                               today: "2026-08-02", into: ctx)
        _ = ScoutService.apply(events: [event("2026-08-06", startTimes: ["20:00"])],
                               clients: [], history: [], blocked: clearCalendar,
                               today: "2026-08-02", into: ctx)

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.count == 1)
        #expect(try #require(all.first).performanceStartTimes == ["20:00"])
    }

    // The identity guard. The start time is deliberately NOT part of how Overture recognises a show
    // across scouts: if it were, every show already in the store would look brand new the first time a
    // time was read for it, and the queue would fill with duplicates of shows Dan has already triaged.
    @MainActor
    @Test func learningATimeDoesNotMakeAnExistingShowLookNew() throws {
        let ctx = try context()
        _ = ScoutService.apply(events: [event("2026-08-06", startTimes: [])],
                               clients: [], history: [], blocked: clearCalendar,
                               today: "2026-08-02", into: ctx)
        let firstKey = try #require(try ctx.fetch(FetchDescriptor<Prospect>()).first).naturalKey

        _ = ScoutService.apply(events: [event("2026-08-06", startTimes: ["19:00"])],
                               clients: [], history: [], blocked: clearCalendar,
                               today: "2026-08-02", into: ctx)

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.count == 1, "learning a start time must refresh the show, never mint a second one")
        #expect(try #require(all.first).naturalKey == firstKey)
        #expect(try #require(all.first).performanceStartTimes == ["19:00"])
    }
}
