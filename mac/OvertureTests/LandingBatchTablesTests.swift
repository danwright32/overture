import Testing
import Foundation
import SwiftData

// #4333 (step A4 of #4275's plan): a landing's per source store wide passes, made proportional to the batch.
// A step toward #4275; the 100 ms bar is not met until Phase E (#4343) says so.
@MainActor
@Suite("A landing judges each source's batch without walking the whole store again (#4333)")
struct LandingBatchTablesTests {
    private static let today = "2026-10-01"
    private static let room = "The Green Room 42"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema, configurations: [
            ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)]))
    }

    private static func night(_ n: Int) -> String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: n,
                                                        to: EasternDate.date(from: today)!)!
        return EasternDate.dayString(from: day)
    }

    private func stored(_ ctx: ModelContext, _ title: String, _ night: String, url: String,
                        venue: String = room, sourceIds: [String] = []) {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: night,
                                                             venue: venue),
                         groupName: title, discipline: "theatre", venue: venue, performanceDate: night,
                         sourceListingURL: url, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        p.sourceIds = sourceIds
        ctx.insert(p)
    }

    private func queued(_ ctx: ModelContext, _ ids: [String]) {
        for id in ids {
            let s = WatchedSource(sourceId: id, orgName: "Org \(id)", listingsURL: "https://\(id).example/events",
                                  kind: .html)
            s.pendingContentHash = "new-hash-\(id)"
            s.hasUnreadChanges = true
            s.successfulCheckCount = WatchedSource.warmupRuns
            s.baselineFeedCount = 3
            ctx.insert(s)
        }
    }

    private func event(_ title: String, _ night: Int) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: Self.room, venue: Self.room,
                          performanceDate: Self.night(night), sourceUrl: "https://src.example/\(title)")
    }

    // MARK: the visit counter, at two store sizes

    // Store rows a landing VISITS for one source: every row handed to a caller, every row the working set
    // walked itself, and every row whose contribution to the batch tables was judged again.
    private static func visits(_ c: ScoutLandingStore.Counters) -> Int {
        c.rowsHandedOut + c.rowsWalked + c.tableRowsRejudged
    }

    // A pure re-land of three sources, each re-listing its own three stored shows, over a store padded with
    // `padding` rows no source owns. Returns the visits each source after the first cost (the first builds the
    // working set, which is linear in the store by design and is A4's starting point, not its subject).
    private func perSourceVisits(padding: Int) async throws -> [Int] {
        let ctx = try context()
        let ids = ["one", "two", "three"]
        for (s, id) in ids.enumerated() {
            for k in 0..<3 {
                stored(ctx, "Kept \(s) \(k)", Self.night(30 + s * 3 + k), url: "https://src.example/Kept \(s) \(k)",
                       sourceIds: [id])
            }
        }
        for k in 0..<padding {
            stored(ctx, "Padding \(k)", Self.night(60 + k % 200), url: "https://padding.example/\(k)",
                   venue: "Padding Hall \(k % 7)")
        }
        queued(ctx, ids)
        try ctx.save()
        let results = ScoutExtractResults(version: 1, generatedAt: "2026-09-29T00:00:00Z", results: ids.enumerated().map { s, id in
            ScoutExtractResult(sourceId: id, verdict: .upcomingListings,
                               events: (0..<3).map { event("Kept \(s) \($0)", 30 + s * 3 + $0) }, note: nil)
        })
        var steps: [(String, ScoutLandingStore.Counters)] = []
        await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty, today: Self.today,
                                        onLandingStep: { steps.append(($0, $1.counters)) }, into: ctx)
        let landed = steps.filter { $0.0 != ScoutLandingStore.Counters.afterReconcile }
        guard landed.map(\.0) == ids else {
            Issue.record(Comment(rawValue: "the landing reported \(steps.map(\.0)), not every source"))
            return []
        }
        return (1..<landed.count).map { Self.visits(landed[$0].1 - landed[$0 - 1].1) }
    }

    // THE GUARD. Sources two and three must visit exactly as many store rows on a store of 40 as on a store of
    // 400: what each costs is set by its own batch and by what the source before it wrote, never by the rows
    // nobody touched. Seen on the code before #4333: `[200, 200] on a store of 40, [2000, 2000] on a store of
    // 400`, five visits of every row per source (the poison walk, the spelling walk, the deletion filter, and
    // the stored shows fold pass and build).
    @Test func aSourcesVisitsDoNotGrowWithTheStore() async throws {
        let small = try await perSourceVisits(padding: 31)
        let large = try await perSourceVisits(padding: 391)
        #expect(!small.isEmpty && small == large, Comment(rawValue:
            "per source visits after the first: \(small) on a store of 40, \(large) on a store of 400"))
    }

    // MARK: the tables equal a rebuild, and every batch's answers equal the walks, after every source

    // A batch as `apply` hands it to the three passes: the fields they read, from the event as published.
    private static func batch(_ events: [ScoutExtractEvent]) -> [AssembledProspect] {
        events.map {
            AssembledProspect(groupName: $0.title, presenter: $0.presenter, location: nil, discipline: "music",
                              venue: $0.venue, performanceDate: $0.performanceDate, sourceListingURL: $0.sourceUrl,
                              reachable: true, priorRelationship: "none", production: "self", profile: "strong",
                              coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                              matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        }
    }

    // What one landing step must satisfy: the tables as kept equal the tables rebuilt from every row with a
    // fresh fold, and for every probe batch the three answers equal the from-scratch walks over every stored
    // row (`ScoutService.poisonedTokensForBatch`, `ambiguousURLsForBatch`, and #1848's spelling walk), which
    // are the code that answered before #4333. Returns a description of each disagreement, empty when none.
    private static func disagreements(_ landing: ScoutLandingStore, at step: String,
                                      batches: [[AssembledProspect]], sourceIds: [String]) -> [String] {
        var found: [String] = []
        do {
            let kept = try landing.batchTablesSnapshot()
            let rebuilt = try landing.rebuiltBatchTablesSnapshot()
            if kept != rebuilt { found.append("\(step): the tables are \(kept), a rebuild is \(rebuilt)") }
            let rows = try landing.rows()
            for (i, b) in batches.enumerated() {
                let poison = try landing.poisonedTokens(adding: b)
                let walkedPoison = try ScoutService.poisonedTokensForBatch(b, storedRows: { rows })
                if poison != walkedPoison {
                    found.append("\(step) batch \(i): poisoned \(poison.sorted()), the walk says \(walkedPoison.sorted())")
                }
                let ambiguous = try landing.ambiguousURLs(adding: b)
                let walkedAmbiguous = try ScoutService.ambiguousURLsForBatch(b, storedRows: { rows })
                if ambiguous != walkedAmbiguous {
                    found.append("\(step) batch \(i): ambiguous \(ambiguous), the walk says \(walkedAmbiguous)")
                }
            }
            let spellings = try landing.venueSpellings()
            for id in sourceIds {
                let walked = rows.filter { $0.sourceIds.contains(id) && !($0.venue ?? "").isEmpty }
                    .flatMap { row in row.sourceIds.filter { $0 == id }.map { _ in row.venue ?? "" } }
                if spellings.used(by: [id]).sorted() != walked.sorted() {
                    found.append("\(step) \(id): spellings \(spellings.used(by: [id]).sorted()), the walk says \(walked.sorted())")
                }
            }
        } catch {
            found.append("\(step): the store could not answer: \(error)")
        }
        return found
    }

    // A1's synthetic corpus (`LandingOracleCorpus`), landed through the extract ingest in both Fenwick orders
    // (the order dependent fold, RC2), with the tables and every source's batch checked after EVERY source.
    // The end state against 6d3453d8's recording is `LandingOracleTests`'; this is the step by step half.
    @Test(arguments: [false, true])
    func theOracleCorpusTablesEqualARebuildAfterEverySource(fenwickSwapped: Bool) async throws {
        let order = fenwickSwapped ? LandingOracleTests.fenwickSwapped : LandingOracleCorpus.sources.map(\.id)
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let context = container.mainContext
        try LandingOracleCorpus.seed(into: context)
        let batches = LandingOracleCorpus.sources.map { Self.batch($0.events) }
        let ids = Array(Set(LandingOracleCorpus.sources.map(\.id) + LandingOracleCorpus.stored.flatMap(\.sourceIds)))
            .sorted()
        var steps: [String] = []
        var found: [String] = []
        await ScoutExtractIngest.ingest(LandingOracleCorpus.results(order: order), clients: [], history: [],
                                        blocked: .empty, today: LandingOracleCorpus.today,
                                        now: LandingOracleCorpus.now,
                                        onLandingStep: { step, landing in
                                            steps.append(step)
                                            found += Self.disagreements(landing, at: step, batches: batches,
                                                                        sourceIds: ids)
                                        }, into: context)
        #expect(steps == order + [ScoutLandingStore.Counters.afterReconcile], Comment(rawValue:
            "the landing reported \(steps), so not every source was checked"))
        #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))
    }

    // THE ISSUE'S FIXTURE. Three sources, and each one rewrites a folded field of a stored row in place (a title
    // whose key fold is unchanged, so the row is updated rather than re-keyed); the second also RE-KEYS a row
    // (the same show at the same room on the same page, its night moved); the third also INSERTS the middle
    // title of a non-transitive triple onto a page whose two stored ends are two shows. After each source the
    // tables must equal a rebuild, and every batch's answers the walks.
    @Test func everySourceRewritingReKeyingAndCompletingTheTripleLeavesTablesEqualToARebuild() async throws {
        let chapel = "Fenwick Chapel"
        let page = "https://fenwick.example/winter-light"
        let ctx = try context()
        stored(ctx, "Winter Light Vespers", Self.night(20), url: page, venue: chapel, sourceIds: ["one"])
        stored(ctx, "Winter Light Carols", Self.night(21), url: page, venue: chapel, sourceIds: ["two"])
        stored(ctx, "Ember Psalms", Self.night(22), url: "https://fenwick.example/ember", venue: chapel,
               sourceIds: ["two"])
        stored(ctx, "Harbor Lights", Self.night(23), url: "https://harbor.example/lights", sourceIds: ["three"])
        queued(ctx, ["one", "two", "three"])
        try ctx.save()
        func on(_ title: String, _ n: Int, _ url: String, _ venue: String) -> ScoutExtractEvent {
            ScoutExtractEvent(title: title, presenter: venue, venue: venue, performanceDate: Self.night(n),
                              sourceUrl: url)
        }
        let sources: [(String, [ScoutExtractEvent])] = [
            ("one", [on("Winter Light Vespers!", 20, page, chapel)]),
            ("two", [on("Winter Light Carols!", 21, page, chapel),
                     on("Ember Psalms", 25, "https://fenwick.example/ember", chapel)]),
            ("three", [on("Harbor Lights!", 23, "https://harbor.example/lights", Self.room),
                       on("Winter Light", 27, page, chapel)]),
        ]
        let results = ScoutExtractResults(version: 1, generatedAt: "2026-09-29T00:00:00Z", results: sources.map {
            ScoutExtractResult(sourceId: $0.0, verdict: .upcomingListings, events: $0.1, note: nil)
        })
        let batches = sources.map { Self.batch($0.1) }
        var found: [String] = []
        var steps: [(String, ScoutLandingStore.Counters)] = []
        await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty, today: Self.today,
                                        onLandingStep: { step, landing in
                                            // After the check, which is what brings the tables current, so
                                            // each source's own writes are counted in its own interval.
                                            found += Self.disagreements(landing, at: step, batches: batches,
                                                                        sourceIds: ["one", "two", "three"])
                                            steps.append((step, landing.counters))
                                        }, into: ctx)
        #expect(found.isEmpty, Comment(rawValue: found.joined(separator: "\n")))

        // The fixture did what it claims, or the equality above proves less than it says (L159).
        let landed = try ctx.fetch(FetchDescriptor<Prospect>())
        let titles = Set(landed.map(\.groupName))
        #expect(titles.isSuperset(of: ["Winter Light Vespers!", "Winter Light Carols!", "Harbor Lights!",
                                       "Winter Light"]), Comment(rawValue: "the titles landed were \(titles.sorted())"))
        let psalms = landed.filter { $0.groupName == "Ember Psalms" }
        #expect(psalms.count == 1 && psalms.first?.performanceDate == Self.night(25), Comment(rawValue:
            "the moved night was not a re-key of the one stored row: \(psalms.map { $0.performanceDate ?? "-" })"))
        #expect(landed.count == 5, Comment(rawValue: "the landing left \(landed.count) rows, not the four plus one"))
        let perSource = steps.filter { $0.0 != ScoutLandingStore.Counters.afterReconcile }
        #expect(perSource.count == 3 && perSource.indices.allSatisfy { i in
            (perSource[i].1 - (i == 0 ? ScoutLandingStore.Counters() : perSource[i - 1].1)).foldsChanged > 0
        }, Comment(rawValue: "not every source rewrote a folded field: \(perSource.map { $0.1.description })"))
    }

    // MARK: an answer already handed out is the store as that source began

    // `apply` takes the spellings ONCE per source and reads them for every row of the batch, so they must stay
    // the stored rows as they stood when the source began, even while the tables are changed in place under
    // them by a later question. A row written after the answer was taken changes the NEXT answer only.
    @Test func aSpellingAnswerStaysAsTheStoreWasWhenItWasTaken() throws {
        let ctx = try context()
        stored(ctx, "Tin Orchard", Self.night(20), url: "https://marlow.example/tin", venue: "Marlow Theatre",
               sourceIds: ["marlow"])
        try ctx.save()
        let landing = ScoutLandingStore(context: ctx)
        let before = try landing.venueSpellings()

        let row = try #require(try landing.rows().first)
        row.venue = "Marlow Theater"
        row.sourceIds = ["marlow", "marlow-archive"]
        try ctx.save()
        let after = try landing.venueSpellings()

        #expect(before.used(by: ["marlow"]) == ["Marlow Theatre"] && before.used(by: ["marlow-archive"]).isEmpty,
                Comment(rawValue: "the answer taken first now reads \(before.used(by: ["marlow", "marlow-archive"]))"))
        #expect(after.used(by: ["marlow"]) == ["Marlow Theater"] && after.used(by: ["marlow-archive"]) == ["Marlow Theater"],
                Comment(rawValue: "the answer taken after the write reads \(after.used(by: ["marlow", "marlow-archive"]))"))
        #expect(landing.counters.tableBuilds == 1 && landing.counters.tableRowsRejudged == 1, Comment(rawValue:
            "the write was not judged as one row on the tables built once: \(landing.counters)"))
    }

    // MARK: the pure tables, against a rebuild, over a seeded random history

    // Rows on one page and one token at one room, with the triple's three titles among them, set, rewritten
    // and removed in a seeded random order (L339: the seed is fixed, so a failure replays). After every change
    // the kept tables equal a rebuild of the rows then present, in their order.
    @Test func randomChangesKeepTheTablesEqualToARebuild() {
        final class Key {}
        let keys = (0..<8).map { _ in Key() }
        let titles = ["Winter Light Vespers", "Winter Light Carols", "Winter Light", "Ember Psalms"]
        func contribution(_ title: String, _ venue: String, _ source: String) -> LandingBatchTables.Contribution {
            var c = LandingBatchTables.Contribution()
            c.tokens = [.init(token: "vtx1", title: ShowLink.foldedTitle(title), venue: venue)]
            c.urls = [.init(url: "https://page.example/season", title: title, venue: venue)]
            c.spellings = [.init(sourceId: source, venue: venue)]
            return c
        }
        var rng = SeededGenerator(seed: 4333)
        var kept = LandingBatchTables()
        var present: [Int: (order: Int, value: LandingBatchTables.Contribution)] = [:]
        var nextOrder = 0
        var mismatches: [String] = []
        for step in 0..<400 {
            let k = Int.random(in: 0..<keys.count, using: &rng)
            let row = ObjectIdentifier(keys[k])
            if present[k] != nil, Int.random(in: 0..<4, using: &rng) == 0 {
                kept.remove(row)
                present[k] = nil
            } else {
                let value = contribution(titles[Int.random(in: 0..<titles.count, using: &rng)],
                                         ["chapel", "loft"][Int.random(in: 0..<2, using: &rng)],
                                         ["a", "b"][Int.random(in: 0..<2, using: &rng)])
                let order: Int
                if let held = present[k]?.order {
                    order = held
                } else {
                    order = nextOrder
                    nextOrder += 1
                }
                kept.set(row, order: order, to: value)
                present[k] = (order, value)
            }
            let rows = present.sorted { $0.value.order < $1.value.order }
                .map { (row: ObjectIdentifier(keys[$0.key]), contribution: $0.value.value) }
            let name: (ObjectIdentifier) -> String = { id in String(keys.firstIndex { ObjectIdentifier($0) == id } ?? -1) }
            if kept.snapshot(naming: name) != LandingBatchTables.rebuilt(rows).snapshot(naming: name) {
                mismatches.append("step \(step)")
            }
        }
        #expect(mismatches.isEmpty, Comment(rawValue: "the kept tables left a rebuild at \(mismatches.prefix(5))"))
    }
}
