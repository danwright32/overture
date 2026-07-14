import Testing
import Foundation
import SwiftData
@testable import Overture

// #798: the scout had no upcoming-only guard at all. Carnegie's feed only ever returns a forward
// 90-day window, so nothing ever needed one. An arbitrary org's page is the opposite: the #770 spike
// found 5 of 7 real sites displaying LAST season's dates while having zero upcoming shows, and one
// page carrying 11 concert dates under a "Previous Concerts This Season" heading. Without this guard
// the first check of any new source floods Dan's queue with concerts that already happened, and the
// only defence would be trusting the extraction prompt.
//
// The rule is at the RUN, not the event, and that placement is the whole point. Skipping past nights
// inside ProspectAssembler.decide would drop them BEFORE RunGrouping runs, so a run already underway
// would lose its opening night, its natural key would shift to the next remaining night on every
// scout, and each scout would re-key or duplicate the same show. The guard therefore judges the run
// against `runEndDate ?? performanceDate`: a run is past only once its LAST night has passed.
//
// Dan's decision (2026-07-11): a run already underway KEEPS its opening-night date. It is not
// re-keyed forward. The queue already renders it as a run ("Oct 3 to 20", QueueModel.runDateLabel),
// so it reads as still running rather than simply past.
@MainActor
@Suite("Scout upcoming-only guard (#798)")
struct ScoutUpcomingOnlyTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let today = "2026-07-11"

    private func choir(_ title: String, _ date: String?, venue: String = "Merkin Hall",
                       url: String = "https://org.example/season") -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: title, venue: venue,
                       performanceDate: date, sourceUrl: url)
    }

    @Test func aShowThatAlreadyHappenedIsNotImported() throws {
        let ctx = ModelContext(try container())
        let events = [choir("Indianapolis Children's Choir", "2026-06-20")]   // three weeks ago

        let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty,
                                         today: today, into: ctx)

        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).isEmpty)
        #expect(outcome.inserted == 0)
        #expect(outcome.skipped == 1)          // accounted for, not silently vanished
        #expect(outcome.inserted + outcome.updated + outcome.skipped + outcome.collapsedIntoRun
                == outcome.found)
    }

    @Test func aShowStillToComeIsImported() throws {
        let ctx = ModelContext(try container())
        let events = [choir("Indianapolis Children's Choir", "2026-09-19")]

        let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty,
                                         today: today, into: ctx)

        #expect(outcome.inserted == 1)
        #expect(outcome.skipped == 0)
    }

    // Today's show still counts as upcoming: it has not happened yet at the time the scout runs.
    @Test func aShowTodayIsStillUpcoming() throws {
        let ctx = ModelContext(try container())
        let outcome = ScoutService.apply(events: [choir("Indianapolis Children's Choir", today)],
                                         clients: [], history: [], blocked: .empty, today: today, into: ctx)
        #expect(outcome.inserted == 1)
    }

    // The case the placement of this rule exists for. A run that opened BEFORE today but is still
    // running must survive, keeping its OPENING-night date (Dan's call: no re-keying forward), so its
    // identity is stable across scouts instead of shifting to the next remaining night every run.
    @Test func aRunAlreadyUnderwayIsKeptOnItsOpeningNight() throws {
        let ctx = ModelContext(try container())
        let events = [
            choir("Brooklyn Youth Chorus", "2026-07-09", url: "https://org.example/a"),   // opened 2 days ago
            choir("Brooklyn Youth Chorus", "2026-07-10", url: "https://org.example/b"),
            choir("Brooklyn Youth Chorus", "2026-07-12", url: "https://org.example/c"),   // still to come
        ]

        let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty,
                                         today: today, into: ctx)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.count == 1)
        #expect(stored.first?.performanceDate == "2026-07-09")   // the opening night, NOT re-keyed forward
        #expect(stored.first?.runEndDate == "2026-07-12")
        #expect(outcome.inserted == 1)
        #expect(outcome.collapsedIntoRun == 2)
        #expect(outcome.skipped == 0)          // no night of a live run is "skipped"

        // Dan's requirement: it must read as a run still running, not as a show that has passed.
        #expect(QueueModel.runDateLabel(start: "2026-07-09", end: "2026-07-12") == "Jul 9 to 12")
    }

    // Re-scouting the same underway run must not shift its key: the same one row, updated.
    @Test func reScoutingAnUnderwayRunDoesNotShiftItsIdentity() throws {
        let ctx = ModelContext(try container())
        let events = [
            choir("Brooklyn Youth Chorus", "2026-07-09", url: "https://org.example/a"),
            choir("Brooklyn Youth Chorus", "2026-07-12", url: "https://org.example/c"),
        ]
        _ = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty, today: today, into: ctx)
        let second = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty,
                                        today: "2026-07-12", into: ctx)   // a later scout, still running

        #expect(second.inserted == 0)
        #expect(second.updated == 1)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == 1)
    }

    // Once the LAST night has passed, the whole run is past and drops out.
    @Test func aRunWhoseFinalNightHasPassedIsNotImported() throws {
        let ctx = ModelContext(try container())
        let events = [
            choir("Brooklyn Youth Chorus", "2026-06-19", url: "https://org.example/a"),
            choir("Brooklyn Youth Chorus", "2026-06-20", url: "https://org.example/b"),
        ]

        let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty,
                                         today: today, into: ctx)

        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).isEmpty)
        #expect(outcome.skipped == 2)          // both nights accounted for
        #expect(outcome.inserted + outcome.updated + outcome.skipped + outcome.collapsedIntoRun
                == outcome.found)
    }

    // A listing with no date at all cannot be judged past, and a real one exists ("date to be
    // confirmed" is a normal state on an org's season page). Keep it rather than silently dropping it.
    @Test func anUndatedShowIsKeptRatherThanDroppedAsPast() throws {
        let ctx = ModelContext(try container())
        let outcome = ScoutService.apply(events: [choir("Indianapolis Children's Choir", nil)],
                                         clients: [], history: [], blocked: .empty, today: today, into: ctx)
        #expect(outcome.inserted == 1)
        #expect(outcome.skipped == 0)
    }
}
