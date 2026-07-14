import Testing
import Foundation
import SwiftData
@testable import Overture

// #771: which source surfaced this prospect. A plain [String], never a @Relationship: a cascade delete
// from a source row would take every prospect it ever produced with it, including sent emails and live
// reply threads.
//
// It is a LIST, not a single id, and that is the whole design. The upsert chain deliberately MERGES the
// same show arriving from a venue's calendar and from the presenter's own site into one row. A single
// id could only remember one of them, and Phase 3's per-source reconcile would then see the show as
// absent from the other source's feed and accrue misses toward `disappearedFromFeed` on a live show
// Dan may already have drafted and emailed.
@MainActor
@Suite("Which source surfaced this prospect (#771)")
struct ProspectProvenanceTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func event(_ title: String, url: String, date: String = "2026-09-19",
                       venue: String = "Merkin Hall") -> ExtractedEvent {
        ExtractedEvent(title: title, presenter: title, venue: venue,
                       performanceDate: date, sourceUrl: url)
    }

    private func stored(_ ctx: ModelContext) throws -> [Prospect] {
        try ctx.fetch(FetchDescriptor<Prospect>())
    }

    @Test func aScoutedProspectRecordsTheSourceThatSurfacedIt() throws {
        let ctx = try context()
        ScoutService.apply(events: [event("Brooklyn Youth Chorus", url: "https://a.example/1")],
                           clients: [], history: [], blocked: .empty,
                           today: ScoutTestClock.beforeAllFixtures,
                           sourceIds: ["venue-a"], into: ctx)

        #expect(try stored(ctx).first?.sourceIds == ["venue-a"])
    }

    // THE test this field exists for. The same show, listed by a venue and by the presenter, dedupes to
    // one row. That row must remember BOTH, or the source that is not remembered will later report the
    // show as vanished from its feed.
    @Test func theSameShowFromASecondSourceUnionsRatherThanReplaces() throws {
        let ctx = try context()
        let show = event("Brooklyn Youth Chorus", url: "https://venue.example/1")

        ScoutService.apply(events: [show], clients: [], history: [], blocked: .empty,
                           today: ScoutTestClock.beforeAllFixtures, sourceIds: ["venue-a"], into: ctx)
        // The presenter's own site lists the same night at the same venue: the chain merges it.
        ScoutService.apply(events: [show], clients: [], history: [], blocked: .empty,
                           today: ScoutTestClock.beforeAllFixtures, sourceIds: ["presenter-b"], into: ctx)

        let all = try stored(ctx)
        #expect(all.count == 1)                                     // one show, not two
        #expect(all.first?.sourceIds.sorted() == ["presenter-b", "venue-a"])
    }

    // Re-scouting from the SAME source does not accumulate duplicate ids.
    @Test func rescoutingTheSameSourceDoesNotDuplicateItsId() throws {
        let ctx = try context()
        let show = event("Brooklyn Youth Chorus", url: "https://venue.example/1")
        for _ in 0..<3 {
            ScoutService.apply(events: [show], clients: [], history: [], blocked: .empty,
                               today: ScoutTestClock.beforeAllFixtures, sourceIds: ["venue-a"], into: ctx)
        }
        #expect(try stored(ctx).first?.sourceIds == ["venue-a"])
    }

    // The scout stamps Carnegie's id without needing the row to exist: the id is a constant, and Phase 4
    // is what iterates real rows.
    @Test func theCarnegieScoutStampsCarnegiesId() async throws {
        let ctx = try context()
        let carnegie = event("Vienna Philharmonic",
                             url: "https://www.carnegiehall.org/Calendar/2026/09/19/Vienna-0800PM",
                             venue: "Stern Auditorium / Perelman Stage")
        _ = try await ScoutService.runScout(
            into: ctx,
            extractor: StubSourceExtractor(listing: ExtractedListing(events: [carnegie],
                                                                     verdict: .upcomingListings)),
            defaults: UserDefaults(suiteName: "ProvenanceTests-\(UUID().uuidString)")!)

        #expect(try stored(ctx).first?.sourceIds == [WatchedSource.carnegieId])
    }

    // A hand-added lead is its own pseudo-source. It has no feed, which is why it passes no `feed:`
    // (#801): with no feed check there is no source report, and with no report the reconcile can mark
    // nothing gone. That is what makes #826 structurally impossible rather than merely guarded.
    @Test func aHandAddedLeadIsStampedManual() throws {
        let ctx = try context()
        ScoutService.apply(events: [event("Second Ending Ensemble", url: "https://org.example/1")],
                           clients: [], history: [], blocked: .empty,
                           today: ScoutTestClock.beforeAllFixtures,
                           sourceIds: [WatchedSource.manualId], into: ctx)

        #expect(try stored(ctx).first?.sourceIds == [WatchedSource.manualId])
    }

    // A prospect from before this field existed carries no ids at all, and nothing invents one for it.
    // Phase 3's miss test reads "at least one of its sourceIds checked successfully this run", so an
    // empty list can never accrue a miss, which is exactly today's behavior for a non-Carnegie URL.
    @Test func aProspectWithNoRecordedSourceIsLeftEmptyRatherThanGuessedAt() throws {
        let ctx = try context()
        ScoutService.apply(events: [event("Unknown Provenance", url: "https://x.example/1")],
                           clients: [], history: [], blocked: .empty,
                           today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(try stored(ctx).first?.sourceIds == [])
    }
}
