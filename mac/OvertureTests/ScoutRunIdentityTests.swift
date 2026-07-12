import Testing
import Foundation
import SwiftData
@testable import Overture

// #797: `ScoutService.apply` resolved each grouped run back to its assembled prospect through a
// dictionary keyed on `sourceListingURL`. Two silent data-loss paths came out of that, and both are
// real feed shapes, not hypotheticals:
//
// 1. A listing URL is not unique. An org that lists a whole season on ONE page gives every show the
//    same `sourceUrl`, and the dictionary was last-write-wins, so every show but the last vanished.
//    It was not even counted in `skipped`, so `found` and the store simply disagreed with no signal.
// 2. A run's representative row need not carry a URL. `RunGrouping.representativeRow` picks the
//    SHORTEST title in the run, which can be the one night that has no link, and the old
//    `guard let openingURL = gr.row.sourceListingURL` then dropped the ENTIRE run, including its
//    member nights that did have URLs.
//
// The fix keys the lookup on the run's own identity rather than on a URL that was never unique.
@MainActor
@Suite("Scout run identity (#797)")
struct ScoutRunIdentityTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // The season-on-one-page shape: distinct acts, distinct dates, distinct venues, ONE listing URL.
    // Nothing here is a multi-night run, so all three must survive as three prospects.
    @Test func distinctShowsSharingOneListingURLAreAllKept() throws {
        let ctx = ModelContext(try container())
        let events = [
            ExtractedEvent(title: "Indianapolis Children's Choir", presenter: "Indianapolis Children's Choir",
                           venue: "Merkin Hall", performanceDate: "2026-10-03",
                           sourceUrl: "https://org.example/season"),
            ExtractedEvent(title: "Brooklyn Youth Chorus", presenter: "Brooklyn Youth Chorus",
                           venue: "St. Ann's Church", performanceDate: "2026-11-14",
                           sourceUrl: "https://org.example/season"),
            ExtractedEvent(title: "Manhattan Girls Chorus", presenter: "Manhattan Girls Chorus",
                           venue: "Bargemusic", performanceDate: "2026-12-05",
                           sourceUrl: "https://org.example/season"),
        ]

        let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: [], into: ctx)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(outcome.found == 3)
        #expect(outcome.skipped == 0)
        #expect(outcome.collapsedIntoRun == 0)
        #expect(stored.count == 3)                  // was 1: the last write won and two shows vanished
        #expect(outcome.inserted == 3)

        // The books have to balance: every event is accounted for exactly once, never silently
        // dropped. This is the assertion that would have caught the bug in the first place.
        #expect(outcome.inserted + outcome.updated + outcome.skipped + outcome.collapsedIntoRun
                == outcome.found)
        #expect(outcome.collapsedIntoRun == 0)      // three separate shows, not one run
    }

    // A genuine multi-night run whose SHORTEST-titled night (the representative, per
    // RunGrouping.representativeRow) is the one with no link. The run must still be upserted, on its
    // opening night, with the linked nights recorded as members.
    @Test func aRunWhoseRepresentativeNightHasNoURLIsStillKept() throws {
        let ctx = ModelContext(try container())
        let events = [
            // Shortest title, and deliberately no sourceUrl: this becomes the representative row.
            ExtractedEvent(title: "Winter Gala", presenter: "Aurora Strings", venue: "Merkin Hall",
                           performanceDate: "2026-10-03", sourceUrl: nil),
            ExtractedEvent(title: "Winter Gala: Guest Artist Night", presenter: "Aurora Strings",
                           venue: "Merkin Hall", performanceDate: "2026-10-04",
                           sourceUrl: "https://org.example/gala-guest"),
        ]

        let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: [], into: ctx)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.count == 1)                  // was 0: the whole run was dropped by the guard
        #expect(outcome.inserted == 1)
        #expect(stored.first?.performanceDate == "2026-10-03")   // collapsed onto the opening night
        #expect(stored.first?.runEndDate == "2026-10-04")        // and it still knows the run's shape

        // The second night was folded in, not lost, and the books say so.
        #expect(outcome.collapsedIntoRun == 1)
        #expect(outcome.inserted + outcome.updated + outcome.skipped + outcome.collapsedIntoRun
                == outcome.found)
    }

    // The re-scout guarantee has to survive the fix: the same feed twice must update in place, not
    // duplicate. A URL-keyed lookup is not what identified a stored prospect (the natural key is),
    // so this is really a guard that the new run identity did not leak into the stored key.
    @Test func reScoutingASharedURLSeasonUpdatesRatherThanDuplicating() throws {
        let ctx = ModelContext(try container())
        let events = [
            ExtractedEvent(title: "Indianapolis Children's Choir", presenter: "Indianapolis Children's Choir",
                           venue: "Merkin Hall", performanceDate: "2026-10-03",
                           sourceUrl: "https://org.example/season"),
            ExtractedEvent(title: "Manhattan Girls Chorus", presenter: "Manhattan Girls Chorus",
                           venue: "Bargemusic", performanceDate: "2026-12-05",
                           sourceUrl: "https://org.example/season"),
        ]

        _ = ScoutService.apply(events: events, clients: [], history: [], blocked: [], into: ctx)
        let second = ScoutService.apply(events: events, clients: [], history: [], blocked: [], into: ctx)

        #expect(second.inserted == 0)
        #expect(second.updated == 2)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == 2)
    }

    // Dan's keep/dismiss must survive a re-scout of a shared-URL season. This is the whole reason
    // the upsert exists, and the shared URL is exactly the case where a careless fix (re-keying on
    // the URL) would clobber his decision by pointing two shows at one stored record.
    @Test func keepDismissSurvivesAReScoutOfASharedURLSeason() throws {
        let ctx = ModelContext(try container())
        let events = [
            ExtractedEvent(title: "Indianapolis Children's Choir", presenter: "Indianapolis Children's Choir",
                           venue: "Merkin Hall", performanceDate: "2026-10-03",
                           sourceUrl: "https://org.example/season"),
            ExtractedEvent(title: "Manhattan Girls Chorus", presenter: "Manhattan Girls Chorus",
                           venue: "Bargemusic", performanceDate: "2026-12-05",
                           sourceUrl: "https://org.example/season"),
        ]
        _ = ScoutService.apply(events: events, clients: [], history: [], blocked: [], into: ctx)

        let key = Prospect.makeNaturalKey(groupName: "Indianapolis Children's Choir",
                                          performanceDate: "2026-10-03", venue: "Merkin Hall")
        let kept = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        kept?.status = .queued
        try ctx.save()

        _ = ScoutService.apply(events: events, clients: [], history: [], blocked: [], into: ctx)

        let refreshed = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(refreshed?.status == .queued)
    }
}
