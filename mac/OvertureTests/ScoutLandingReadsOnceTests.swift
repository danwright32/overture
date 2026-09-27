import Testing
import Foundation
import SwiftData

// #4275: how many times one scout reads the whole show table, and that it does not grow with the number of
// sources landed.
//
// Before this, `ScoutService.apply` fetched the whole table twice for every source it landed, the sweep's
// reconcile fetched it once more per source, and the run URL arm fetched it again for every event that
// reached it. Measured on a store clone at 1x (1,344 shows, 39 sources, Debug): 17.2 s of main thread time,
// 47% of a landing, and linear in store size times sources. The reads are counted through the injected
// table read both scout entry points take; `everyTableReadGoesThroughTheOneCountedRead` is what makes that
// count exhaustive, by refusing any other spelling of the read in the two files.
private struct ListedFeed: SourceExtractor {
    let events: [ExtractedEvent]
    func extract() async throws -> ExtractedListing {
        ExtractedListing(events: events, verdict: .upcomingListings)
    }
}

@MainActor
@Suite("A scout reads the show table a fixed number of times, however many sources land (#4275)")
struct ScoutLandingReadsOnceTests {
    private static func night(_ n: Int) -> String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: Date())!
        return EasternDate.dayString(from: day)
    }

    private static func events(for id: String) -> [ExtractedEvent] {
        (0..<4).map { k in
            ExtractedEvent(title: "Ensemble \(id) \(k)", presenter: "Ensemble \(id) \(k) Presents",
                           venue: "Venue \(k) Hall", performanceDate: night(k),
                           sourceUrl: "https://\(id).example/e\(k)", location: "New York, NY")
        }
    }

    // A store already holding shows, so each source has stored rows to be judged against.
    private func seededContext() throws -> (ModelContainer, ModelContext) {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = c.mainContext
        for k in 0..<6 {
            ctx.insert(Prospect(naturalKey: "stored-\(k)", groupName: "Stored Show \(k)", discipline: "music",
                                venue: "Venue \(k) Hall", performanceDate: Self.night(k),
                                sourceListingURL: "https://stored.example/\(k)", priorRelationship: "none",
                                production: "self", profile: "strong", coverage: "likely_uncovered",
                                fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                                possibleMatchSource: nil, possibleMatchName: nil))
        }
        try ctx.save()
        return (c, ctx)
    }

    // The sweep: every free source read, then landed together.
    private func sweepReads(sources n: Int) async throws -> (reads: Int, inserted: Int) {
        let (container, ctx) = try seededContext()
        _ = container
        var ids: Set<String> = []
        for i in 0..<n {
            ctx.insert(WatchedSource(sourceId: "feed-\(i)", orgName: "Feed \(i)",
                                     listingsURL: "https://feed-\(i).example/", kind: .algolia))
            ids.insert("feed-\(i)")
        }
        try ctx.save()
        var reads = 0
        let outcome = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, only: ids,
            extractorRegistry: { source in
                guard let id = source?.sourceId, id.hasPrefix("feed-") else { return nil }
                return ListedFeed(events: Self.events(for: id))
            },
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString,
                                             contentHash: "same") },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("ScoutLandingReadsOnceTests"),
            readProspectTable: { ctx in
                reads += 1
                return try ctx.fetch(FetchDescriptor<Prospect>())
            })
        return (reads, outcome.inserted)
    }

    // The extract ingest: one results file carrying several sources.
    private func ingestReads(sources n: Int) async throws -> (reads: Int, inserted: Int) {
        let (container, ctx) = try seededContext()
        _ = container
        for i in 0..<n {
            let s = WatchedSource(sourceId: "page-\(i)", orgName: "Page \(i)",
                                  listingsURL: "https://page-\(i).example/events", kind: .html)
            s.pendingContentHash = "hash-\(i)"
            s.hasUnreadChanges = true
            ctx.insert(s)
        }
        try ctx.save()
        let results = ScoutExtractResults(
            version: 1, generatedAt: "2026-07-13T00:00:00Z",
            results: (0..<n).map { i in
                ScoutExtractResult(sourceId: "page-\(i)", verdict: .upcomingListings,
                                   events: Self.events(for: "page-\(i)").map {
                                       ScoutExtractEvent(title: $0.title, presenter: $0.presenter,
                                                         venue: $0.venue, performanceDate: $0.performanceDate,
                                                         sourceUrl: $0.sourceUrl)
                                   }, note: nil)
            })
        var reads = 0
        let outcome = await ScoutExtractIngest.ingest(
            results, clients: [], history: [], blocked: .empty,
            readProspectTable: { ctx in
                reads += 1
                return try ctx.fetch(FetchDescriptor<Prospect>())
            }, into: ctx)
        return (reads, outcome.inserted)
    }

    @Test func aSweepReadsTheTableAsOftenForSixSourcesAsForOne() async throws {
        let one = try await sweepReads(sources: 1)
        let six = try await sweepReads(sources: 6)
        // The control: every source really landed, or a count that stayed flat would prove nothing (L159).
        #expect(one.inserted == 4 && six.inserted == 24, Comment(rawValue:
            "the sources did not all land (\(one.inserted) and \(six.inserted) shows), so the count below "
            + "measured a smaller run than it claims"))
        #expect(six.reads == one.reads, Comment(rawValue:
            "a sweep of six sources read the whole show table \(six.reads) times against \(one.reads) for one, "
            + "so the cost of a landing grows with the watchlist again"))
        // The history, the brand corpus, and the landing's working set.
        #expect(six.reads <= 3, Comment(rawValue: "a sweep read the whole show table \(six.reads) times"))
    }

    @Test func anIngestReadsTheTableAsOftenForSixSourcesAsForOne() async throws {
        let one = try await ingestReads(sources: 1)
        let six = try await ingestReads(sources: 6)
        #expect(one.inserted == 4 && six.inserted == 24, Comment(rawValue:
            "the sources did not all land (\(one.inserted) and \(six.inserted) shows), so the count below "
            + "measured a smaller run than it claims"))
        #expect(six.reads == one.reads, Comment(rawValue:
            "an ingest of six sources read the whole show table \(six.reads) times against \(one.reads) for "
            + "one, so the cost of a landing grows with the results file again"))
        // The brand corpus and the landing's working set.
        #expect(six.reads <= 2, Comment(rawValue: "an ingest read the whole show table \(six.reads) times"))
    }

    // What makes the two counts above exhaustive: no other spelling of a whole table read survives in the
    // two files a landing runs through, so none can happen outside the injected read. Derived from the
    // files rather than a list of call sites, so a new one added later is caught too (L96).
    @Test func everyTableReadGoesThroughTheOneCountedRead() {
        for path in ["Overture/Integration/ScoutService.swift", "Overture/Integration/ScoutExtractIngest.swift"] {
            let source = SourceGuardHelper.source(path)
            #expect(!source.isEmpty, "\(path) could not be read, so this measured nothing")
            let offenders = source
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .filter { $0.element.contains("FetchDescriptor<Prospect>()")
                    && !$0.element.contains("static let readProspectTable") }
                .map { "line \($0.offset + 1)" }
            #expect(offenders.isEmpty, Comment(rawValue:
                "\(path) reads the whole show table outside the counted read at \(offenders.joined(separator: ", "))"))
        }
    }
}
