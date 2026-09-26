import Testing
import Foundation
import SwiftData
@testable import Overture

// #4102: a scout now READS every free source first and APPLIES them all in one block at the end of the
// sweep, so the queue sees one change per run rather than one per source (`AScoutRunDerivesTheQueueOnceTests`
// measures that half). These pin what moving the writes must not cost: a source that fails part way leaves
// nothing of itself behind and nothing of the others missing, the report still lists sources in the order
// they were checked, and two runs at once still leave one row per show.

private struct ListedFeed: SourceExtractor {
    let events: [ExtractedEvent]
    func extract() async throws -> ExtractedListing {
        ExtractedListing(events: events, verdict: .upcomingListings)
    }
}

private struct BrokenFeed: SourceExtractor {
    struct Down: Error {}
    func extract() async throws -> ExtractedListing { throw Down() }
}

@MainActor
@Suite("A scout's free reads land together (#4102)")
struct ScoutReadsLandTogetherTests {
    private static let showsPerSource = 10

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory(AppSchema.models)
    }

    private static func night(_ n: Int) -> String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: Date())!
        return EasternDate.dayString(from: day)
    }

    private static func events(for id: String) -> [ExtractedEvent] {
        (0..<showsPerSource).map { k in
            ExtractedEvent(title: "Quartet \(id) \(k)", presenter: "Quartet \(id) \(k) Presents",
                           venue: "Venue \(k) Hall", performanceDate: night(k),
                           sourceUrl: "https://\(id).example/e\(k)", location: "New York, NY")
        }
    }

    private static func widget(for id: String) -> String {
        let dates = (0..<showsPerSource).map { k in
            #""\#(night(k))":{"available":true,"formatted_date":"x","event_series":[{"series_id":\#(k + 1),"name":"Quartet \#(id) \#(k)","venue":"Venue \#(k) Hall","event_page_url":"/events/\#(id)/\#(k)"}]}"#
        }
        return "<script>var selectableDates = {\(dates.joined(separator: ","))};</script>"
    }

    private func feeds(_ n: Int, in ctx: ModelContext) -> Set<String> {
        var ids: Set<String> = []
        for i in 0..<n {
            ctx.insert(WatchedSource(sourceId: "feed-\(i)", orgName: "Feed \(i)",
                                     listingsURL: "https://feed-\(i).example/", kind: .algolia))
            ids.insert("feed-\(i)")
        }
        return ids
    }

    private func run(_ ctx: ModelContext, only: Set<String>, broken: Set<String> = [],
                     depth: ScoutDepth = .watchOnly,
                     fetch: @escaping (URL, String?, String?) async throws -> FetchedPage = { url, _, _ in
                         FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "same")
                     },
                     onProgress: @escaping (String, Int, Int) -> Void = { _, _, _ in })
        async throws -> ScoutService.Outcome {
        try await ScoutService.runScout(
            into: ctx, depth: depth, only: only,
            extractorRegistry: { source in
                guard let id = source?.sourceId, id.hasPrefix("feed-") else { return nil }
                return broken.contains(id) ? BrokenFeed() : ListedFeed(events: Self.events(for: id))
            },
            fetch: fetch,
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("ScoutReadsLandTogetherTests"),
            onNativeProgress: onProgress)
    }

    private func storedTitles(_ ctx: ModelContext) throws -> [String] {
        try ctx.fetch(FetchDescriptor<Prospect>()).map(\.groupName)
    }

    // THE FAILURE PATH. The middle feed of three throws while the run is reading. Its shows must not
    // appear at all, the other two must land WHOLE, and the failure must be on the report and on the row:
    // a run that silently dropped a source, or landed half of one, would look exactly like a quiet night.
    @Test func aFeedThatFailsMidRunLandsNothingAndTheOthersLandWhole() async throws {
        let c = try container()
        let ctx = c.mainContext
        let ids = feeds(3, in: ctx)
        try ctx.save()

        let outcome = try await run(ctx, only: ids, broken: ["feed-1"])

        let titles = try storedTitles(ctx)
        #expect(titles.filter { $0.contains("feed-0") }.count == Self.showsPerSource)
        #expect(titles.filter { $0.contains("feed-2") }.count == Self.showsPerSource)
        #expect(!titles.contains { $0.contains("feed-1") }, Comment(rawValue:
            "the feed that failed landed \(titles.filter { $0.contains("feed-1") }.count) shows"))
        #expect(!outcome.saveFailed, "the healthy feeds' writes did not land")

        let failed = try #require(outcome.sources.first { $0.sourceId == "feed-1" })
        #expect({ if case .failed = failed.state { return true } else { return false } }(), Comment(rawValue:
            "the failed feed is reported as \(failed.state), so the report reads as a quiet source"))
        let row = try #require(try ctx.fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == "feed-1" })
        #expect(row.failedReadStreak == 1, "the failure was not recorded on the source's own row")
        for id in ["feed-0", "feed-2"] {
            let result = try #require(outcome.sources.first { $0.sourceId == id })
            #expect({ if case .ingested(let n) = result.state { return n == Self.showsPerSource } else { return false } }(),
                    Comment(rawValue: "\(id) is reported as \(result.state)"))
        }
    }

    // The report keeps the order the sources were CHECKED in, with a widget read in the html loop sitting
    // where it was fetched rather than moved to the end because its write now lands later. A run Dan
    // started, because only that one reads a changed page at all (`SourceCheck.decide`).
    @Test func theReportKeepsTheOrderTheSourcesWereChecked() async throws {
        let c = try container()
        let ctx = c.mainContext
        var ids: Set<String> = []
        for (i, id) in ["plain-a", "tt-b", "plain-c", "tt-d"].enumerated() {
            let s = WatchedSource(sourceId: id, orgName: "Org \(i) \(id)",
                                  listingsURL: "https://\(id).example/events", kind: .html)
            s.venueLocation = "New York, NY"
            s.lastContentHash = "same"
            ctx.insert(s)
            ids.insert(id)
        }
        try ctx.save()
        var checked: [String] = []

        let outcome = try await run(ctx, only: ids, depth: .readChanged, fetch: { url, _, _ in
            let id = url.host?.replacingOccurrences(of: ".example", with: "") ?? ""
            return FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString,
                               contentHash: id.hasPrefix("tt-") ? "hash-\(id)" : "same",
                               ticketTailorWidgetHTML: id.hasPrefix("tt-") ? Self.widget(for: id) : nil)
        }, onProgress: { name, _, _ in checked.append(name) })

        let byName = try ctx.fetch(FetchDescriptor<WatchedSource>())
        let checkedIds = checked.compactMap { name in byName.first { $0.orgName == name }?.sourceId }
        #expect(checkedIds.count == 4, "the run did not check all four sources: \(checked)")
        #expect(outcome.sources.map(\.sourceId) == checkedIds, Comment(rawValue:
            "the report lists \(outcome.sources.map(\.sourceId)) but the sources were checked as \(checkedIds)"))
        // And the widgets' pages are marked read only now that their shows have landed.
        for row in byName where row.sourceId.hasPrefix("tt-") {
            #expect(row.lastContentHash == "hash-\(row.sourceId)", Comment(rawValue:
                "\(row.sourceId)'s page was not marked read after its shows landed"))
        }
    }

    // ASSUME IT RUNS TWICE. Two runs over the same feeds at once (the app refuses a second start, but a
    // scheduled run and a press can still race, and the reads are awaited). Each show must end up stored
    // exactly once.
    @Test func twoRunsAtOnceLeaveOneRowPerShow() async throws {
        let c = try container()
        let ctx = c.mainContext
        let ids = feeds(2, in: ctx)
        try ctx.save()

        // Two main actor tasks rather than `async let`, which would hand the context to another isolation
        // domain. Both runs interleave at every await exactly as two runs in the app would.
        let first = Task { @MainActor in try await run(ctx, only: ids) }
        let second = Task { @MainActor in try await run(ctx, only: ids) }
        _ = try await first.value
        _ = try await second.value

        let titles = try storedTitles(ctx)
        #expect(titles.count == 2 * Self.showsPerSource, Comment(rawValue:
            "two runs at once stored \(titles.count) rows for \(2 * Self.showsPerSource) shows"))
        #expect(Set(titles).count == titles.count, "a show was stored twice")
    }

    // THE OTHER DOOR. A detached read's results file lands through `ScoutExtractIngest`, which reads every
    // source first and lands them together for the same reason (#4102). The file's order must survive
    // that, with a source that failed and an id nobody queued settled where they were read, and every
    // healthy source must land whole.
    @Test func anIngestLandsEveryReadSourceAndReportsThemInTheFilesOrder() async throws {
        let c = try container()
        let ctx = c.mainContext
        for id in ["a", "b", "c"] {
            let s = WatchedSource(sourceId: id, orgName: "Org \(id)",
                                  listingsURL: "https://\(id).example/events", kind: .html)
            s.venueLocation = "New York, NY"
            ctx.insert(s)
        }
        try ctx.save()
        func shows(_ id: String) -> [ScoutExtractEvent] {
            Self.events(for: id).map {
                ScoutExtractEvent(title: $0.title, presenter: $0.presenter, venue: $0.venue,
                                  performanceDate: $0.performanceDate, sourceUrl: $0.sourceUrl,
                                  location: $0.location)
            }
        }
        let file = ScoutExtractResults(version: 1, generatedAt: "2026-09-25T00:00:00Z", results: [
            ScoutExtractResult(sourceId: "a", verdict: .upcomingListings, events: shows("a"), note: nil),
            ScoutExtractResult(sourceId: "b", verdict: .notRead, events: [], note: nil),
            ScoutExtractResult(sourceId: "nobody-queued-this", verdict: .upcomingListings, events: [], note: nil),
            ScoutExtractResult(sourceId: "c", verdict: .upcomingListings, events: shows("c"), note: nil),
        ])

        let outcome = await ScoutExtractIngest.ingest(file, clients: [], history: [], blocked: .empty,
                                                      into: ctx)

        #expect(outcome.sources.map(\.sourceId) == ["a", "b", "c"], Comment(rawValue:
            "the ingest reported \(outcome.sources.map(\.sourceId)), not the file's order a, b, c"))
        #expect(outcome.unqueuedResultIds == ["nobody-queued-this"])
        let titles = try storedTitles(ctx)
        #expect(titles.filter { $0.contains("Quartet a ") }.count == Self.showsPerSource)
        #expect(titles.filter { $0.contains("Quartet c ") }.count == Self.showsPerSource)
        #expect(titles.count == 2 * Self.showsPerSource, "the ingest stored \(titles.count) rows")
        #expect(!outcome.saveFailed)
    }

    // #4147 carried each apply's title renames on its Outcome, and `Outcome.merge` dropped them, so a
    // whole run's report (built by merging one Outcome per source, on both doors above) never carried a
    // single rename however many the run made. The ledger file was still written, so nothing was lost on
    // disk; what was lost is the one in-memory record a caller could assert on (L90).
    @Test func mergingOutcomesKeepsEveryTitleRename() {
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        var first = ScoutService.Outcome(found: 1, inserted: 0, updated: 1, skipped: 0)
        first.titleRenames = [TitleRenameLedger.Entry(key: "k1", from: "Old One", to: "New One",
                                                      arm: "byConcert", at: at)]
        var second = ScoutService.Outcome(found: 1, inserted: 0, updated: 1, skipped: 0)
        second.titleRenames = [TitleRenameLedger.Entry(key: "k2", from: "Old Two", to: "New Two",
                                                       arm: "byAnyRunURL", at: at)]

        var run = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
        run.merge(first)
        run.merge(second)

        #expect(run.titleRenames.map(\.key) == ["k1", "k2"], Comment(rawValue:
            "a merged run carries renames \(run.titleRenames.map(\.key)), not both sources' k1 and k2"))
    }
}
