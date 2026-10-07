import Testing
import Foundation
import SwiftData

// #4490: a show table that cannot be read during a landing is a RECORDED outcome at every entry point, never a
// trap. The issue was filed from a trap the #4339 agent saw under the lead paste; measured the same day, that
// trap was the test releasing its ModelContainer (a context whose container is gone traps in SwiftData on its
// first use), not the landing. These hold what each entry point really does with an unreadable table, so the
// question never has to be answered from a crash report again:
//   - the calendar ingest lands nothing and counts each show it could not settle as store unreadable, with the
//     reads named (the lead paste's own case is `LeadPasteLandingTests.aShowTableUnreadableEverywhereIsRecordedNotATrap`);
//   - `runScout` refuses before it spends anything, by name (`StoreReadFailure`, repeat client history), when
//     the table cannot be read at all;
//   - `runScout` whose table reads at the start and fails during the landing counts the shows as store
//     unreadable and lands none of them.
// Every test holds its container for its whole length, the fault the original report was.

private struct Unreadable: Error {}

private struct ListedFeed: SourceExtractor {
    let events: [ExtractedEvent]
    func extract() async throws -> ExtractedListing {
        ExtractedListing(events: events, verdict: .upcomingListings)
    }
}

// A table read that answers the first `succeeding` times and then refuses, counted from any thread.
private final class FailingAfter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let succeeding: Int
    init(succeeding: Int) { self.succeeding = succeeding }
    func read(_ context: ModelContext) throws -> [Prospect] {
        let n = lock.withLock { () -> Int in calls += 1; return calls }
        guard n <= succeeding else { throw Unreadable() }
        return try ScoutService.readProspectTable(context)
    }
    var count: Int { lock.withLock { calls } }
}

@MainActor
@Suite("#4490 a show table unreadable during a landing is recorded, never a trap")
final class AWorkingSetReadFailureIsRecordedTests {
    private static func night(_ n: Int) -> String {
        ScoutTestClock.day(20 + n, after: Date())
    }

    private static func events(_ id: String) -> [ExtractedEvent] {
        (0..<3).map { k in
            ExtractedEvent(title: "Ensemble \(id) \(k)", presenter: "Ensemble \(id) Presents", venue: "Venue \(k) Hall",
                           performanceDate: night(k), sourceUrl: "https://\(id).example/e\(k)", location: "New York, NY")
        }
    }

    private func seeded() throws -> (ModelContainer, ModelContext) {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = c.mainContext
        ctx.insert(Prospect(naturalKey: "stored-0", groupName: "Stored Show", discipline: "music",
                            venue: "Venue 0 Hall", performanceDate: Self.night(0),
                            sourceListingURL: "https://stored.example/0", priorRelationship: "none",
                            production: "self", profile: "strong", coverage: "likely_uncovered",
                            fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                            possibleMatchSource: nil, possibleMatchName: nil))
        try ctx.save()
        return (c, ctx)
    }

    private func count(_ c: ModelContainer) throws -> Int {
        try ModelContext(c).fetchCount(FetchDescriptor<Prospect>())
    }

    @Test func theCalendarIngestCountsEveryShowAsStoreUnreadable() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        let source = WatchedSource(sourceId: "page-a", orgName: "Page A", listingsURL: "https://page-a.example/events",
                                   kind: .html)
        source.pendingContentHash = "hash-a"
        source.hasUnreadChanges = true
        ctx.insert(source)
        try ctx.save()
        let results = ScoutExtractResults(version: 1, generatedAt: "2026-07-13T00:00:00Z", results: [
            ScoutExtractResult(sourceId: "page-a", verdict: .upcomingListings,
                               events: Self.events("page-a").map {
                                   ScoutExtractEvent(title: $0.title, presenter: $0.presenter, venue: $0.venue,
                                                     performanceDate: $0.performanceDate, sourceUrl: $0.sourceUrl)
                               }, note: nil)])
        let outcome = await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty,
                                                      readProspectTable: { _ in throw Unreadable() }, into: ctx)
        #expect(outcome.inserted == 0 && outcome.storeUnreadable == 3,
                "inserted \(outcome.inserted), store unreadable \(outcome.storeUnreadable)")
        #expect(outcome.degradedReads.contains(.venueBrandCorpus), "degraded: \(outcome.degradedReads)")
        #expect(try count(container) == 1, "a show landed from a store that could not be read")
    }

    private func runScout(reading read: @escaping ScoutLandingStore.SendableRead,
                          into ctx: ModelContext) async throws -> ScoutService.Outcome {
        ctx.insert(WatchedSource(sourceId: "feed-a", orgName: "Feed A", listingsURL: "https://feed-a.example/",
                                 kind: .algolia))
        try ctx.save()
        return try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, only: ["feed-a"],
            extractorRegistry: { source in source?.sourceId == "feed-a" ? ListedFeed(events: Self.events("feed-a")) : nil },
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "same") },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("AWorkingSetReadFailureIsRecordedTests"),
            readProspectTable: read)
    }

    @Test func runScoutRefusesByNameWhenTheTableCannotBeReadAtAll() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        do {
            _ = try await runScout(reading: { _ in throw Unreadable() }, into: ctx)
            Issue.record("runScout ran on a store whose show table could not be read")
        } catch let failure as ScoutService.StoreReadFailure {
            #expect(failure.read == .repeatClientHistory, "refused naming \(failure.read)")
        }
        #expect(try count(container) == 1)
    }

    @Test func runScoutWhoseTableFailsDuringTheLandingCountsTheShowsAsStoreUnreadable() async throws {
        let (container, ctx) = try seeded()
        defer { withExtendedLifetime(container) {} }
        // The run's own first read (its history) answers; everything after it, the landing's working set
        // included, refuses.
        let reader = FailingAfter(succeeding: 1)
        let outcome = try await runScout(reading: { try reader.read($0) }, into: ctx)
        #expect(reader.count > 1, "the landing never read the table, so nothing here failed during it")
        #expect(outcome.inserted == 0 && outcome.storeUnreadable == 3,
                "inserted \(outcome.inserted), store unreadable \(outcome.storeUnreadable)")
        #expect(try count(container) == 1, "a show landed from a store that could not be read")
    }
}
