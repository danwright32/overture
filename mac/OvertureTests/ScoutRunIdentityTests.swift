import Testing
import Foundation
import SwiftData

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

        let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(outcome.found == 3)
        #expect(outcome.skipped == 0)
        #expect(outcome.collapsedIntoRun == 0)
        #expect(stored.count == 3)                  // was 1: the last write won and two shows vanished
        #expect(outcome.inserted == 3)

        // The books have to balance: every event is accounted for exactly once, never silently
        // dropped. This is the assertion that would have caught the bug in the first place.
        // #2758: the identity gains a fifth term. A row the store could not be read for is left
        // untouched, and it has to be accounted for here or a refused show reads as one that
        // vanished, which is the exact bug this identity was added to catch.
        #expect(outcome.inserted + outcome.updated + outcome.skipped + outcome.collapsedIntoRun
                + outcome.storeUnreadable
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

        let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.count == 1)                  // was 0: the whole run was dropped by the guard
        #expect(outcome.inserted == 1)
        #expect(stored.first?.performanceDate == "2026-10-03")   // collapsed onto the opening night
        #expect(stored.first?.runEndDate == "2026-10-04")        // and it still knows the run's shape

        // The second night was folded in, not lost, and the books say so.
        #expect(outcome.collapsedIntoRun == 1)
        // #2758: the identity gains a fifth term. A row the store could not be read for is left
        // untouched, and it has to be accounted for here or a refused show reads as one that
        // vanished, which is the exact bug this identity was added to catch.
        #expect(outcome.inserted + outcome.updated + outcome.skipped + outcome.collapsedIntoRun
                + outcome.storeUnreadable
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

        _ = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)
        let second = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(second.inserted == 0)
        #expect(second.updated == 2)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == 2)
    }

    // The DELIBERATE cost of #797's re-key guard, pinned so it is a recorded decision rather than a
    // surprise later. The URL-rescue path (#132) exists to update a stored show in place when its key
    // no longer matches, which is what preserves Dan's keep/dismiss. It now demands that the ACT and
    // the VENUE agree, so a venue that RENAMES itself in the feed no longer rescues: the show is
    // inserted afresh and the old row is left behind.
    //
    // That is the trade Dan chose (2026-07-11), and the reasoning matters more than the assertion: a
    // duplicate he can SEE beats a stored show silently overwritten by a different act, which is
    // exactly what the looser URL-only match did on a season page. If this test ever fails because
    // someone relaxed the guard, re-read #797 before "fixing" it.
    @Test func aRenamedVenueNoLongerRescuesAndInsertsAfresh() throws {
        let ctx = ModelContext(try container())
        let first = [ExtractedEvent(title: "Indianapolis Children's Choir",
                                    presenter: "Indianapolis Children's Choir", venue: "Weill Recital Hall",
                                    performanceDate: "2026-10-03", sourceUrl: "https://org.example/show")]
        _ = ScoutService.apply(events: first, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        // Same show, same listing URL, same date: only the venue's NAME changed in the feed.
        let renamed = [ExtractedEvent(title: "Indianapolis Children's Choir",
                                      presenter: "Indianapolis Children's Choir", venue: "Zankel Hall",
                                      performanceDate: "2026-10-03", sourceUrl: "https://org.example/show")]
        let outcome = ScoutService.apply(events: renamed, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(outcome.inserted == 1)      // NOT rescued in place: a new row, and the old one remains
        #expect(outcome.updated == 0)
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
        _ = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let key = Prospect.makeNaturalKey(groupName: "Indianapolis Children's Choir",
                                          performanceDate: "2026-10-03", venue: "Merkin Hall")
        let kept = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        kept?.status = .queued
        try ctx.save()

        _ = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let refreshed = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(refreshed?.status == .queued)
    }
}
