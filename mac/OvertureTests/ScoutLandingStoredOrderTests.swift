import Testing
import Foundation
import SwiftData

// #4397: a scout landing must leave the same store whatever order the stored shows come back in.
//
// Measured 2026-09-30 on the frozen 4x inputs of #4327 step 0.0, same app code, hash seed fixed: four landings in
// one process gave two different stores, and the first decision that differed was ONE `matchByAnyRunURL` call in
// source 29 of 36, which re-keyed a different one of two stored rows sharing the incoming run's URL. Every input
// to that call was identical; only the ORDER of `landing.rows()` differed, and `all.first` takes whichever
// candidate comes first. That order is the table fetch's, and a fetch with no sort on a context holding ANY
// unsaved change (the ingest edits every source's notes before it lands one) came back in a different order on
// each of six opens of the same file, while a clean context's order repeated every time.
//
// So the order is fixed where the landing takes it: `ScoutLandingStore` holds the table in one canonical order
// (`Prospect.inKeyOrder`, by natural key), whatever the read handed it. Every first match the landing makes
// (the run URL, production token and stable source arms, the lookalike and already pitched notes, the per source
// venue spellings) reads that one array, so all of them are fixed by the one change. The history the classify
// pass matches against is the sibling: `LocalHistory.records(from:)` feeds `history.first(where:)`, and its
// callers read the table unsorted too.
@MainActor
@Suite("A scout landing does not depend on the order the stored shows are read in (#4397)")
struct ScoutLandingStoredOrderTests {

    static let today = "2026-09-29"
    static let venue = "Larkspur Hall"

    private static func stored(_ key: String) -> Prospect {
        Prospect(naturalKey: key, groupName: "Show \(key)", discipline: "music", venue: venue,
                 performanceDate: "2026-11-01", sourceListingURL: "https://order.example/\(key)",
                 priorRelationship: "none", production: "self", profile: "strong",
                 coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                 possibleMatchSource: nil, possibleMatchName: nil)
    }

    private static func byteOrder(_ keys: [String]) -> [String] {
        keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    // MARK: the landing holds the table in one order

    @Test func aLandingHoldsTheStoredShowsInKeyOrderWhateverOrderTheyWereWrittenAndRead() throws {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = container.mainContext
        // Written OUT of key order, so the table's own order is not the canonical one by accident.
        let written = ["k-07", "k-02", "k-11", "k-05", "K-09", "k-01", "k-10", "k-03", "k-08", "k-04"]
        for key in written { ctx.insert(Self.stored(key)) }
        try ctx.save()
        // An unsaved change of another kind, as the ingest leaves one before its first landing read.
        ctx.insert(WatchedSource(sourceId: "order-feed", orgName: "Order Feed", kind: .html))

        let fetched = try ScoutService.readProspectTable(ctx).map(\.naturalKey)
        #expect(fetched != Self.byteOrder(written), Comment(rawValue:
            "the table read already came back in key order, so this cannot see the landing impose one (L159)"))

        let held = try ScoutLandingStore(context: ctx).rows().map(\.naturalKey)
        #expect(held == Self.byteOrder(written), Comment(rawValue:
            "the landing holds the stored shows in the read's order, not key order: \(held)"))

        // An injected read (the tests' seam, and any future caller's) is ordered the same way: the order is the
        // landing's, not whichever read it was handed.
        let reversed = try ScoutLandingStore(context: ctx, read: { try ScoutService.readProspectTable($0).reversed() })
            .rows().map(\.naturalKey)
        #expect(reversed == Self.byteOrder(written), Comment(rawValue:
            "a landing given a reversed read kept the reversed order: \(reversed)"))

        // And the reference policy the working set is proved equivalent to, which fetches afresh every time.
        let everyRead = try ScoutLandingStore(context: ctx, policy: .everyRead).rows().map(\.naturalKey)
        #expect(everyRead == Self.byteOrder(written), Comment(rawValue:
            "the every read landing holds the read's order, not key order: \(everyRead)"))
    }

    // MARK: two landings of the same shows, stored in different orders, leave the same store

    // `pairs` shows are each stored TWICE at one venue on different nights, both rows carrying the same run URL,
    // and the results file lists each show once more on a third night under that URL. The run URL arm finds both
    // stored rows and re-keys the first it meets, so each pair is one order dependent decision: with the order
    // unfixed, a landing on a store written in the other order re-keys the other row of every pair.
    private static func land(pairs: Int, reversed: Bool) async throws -> (digest: String, rekeyed: Int) {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = container.mainContext
        var rows: [Prospect] = []
        for i in 0..<pairs {
            let title = "Paired Recital \(i)"
            let run = "https://order.example/run-\(i)"
            for (side, night) in [("a", "2026-11-10"), ("b", "2026-11-20")] {
                let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: night,
                                                                     venue: venue),
                                 groupName: title, discipline: "music", venue: venue, performanceDate: night,
                                 sourceListingURL: "https://order.example/run-\(i)/\(side)",
                                 priorRelationship: "none", production: "self", profile: "strong",
                                 coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                                 runSourceURLs: [run])
                p.sourceIds = ["order-feed"]
                rows.append(p)
            }
        }
        for p in (reversed ? rows.reversed() : rows) { ctx.insert(p) }
        let source = WatchedSource(sourceId: "order-feed", orgName: "Order Feed",
                                   listingsURL: "https://order.example/events", kind: .html)
        source.pendingContentHash = "order-hash"
        source.hasUnreadChanges = true
        ctx.insert(source)
        try ctx.save()

        let results = ScoutExtractResults(
            version: 1, generatedAt: "2026-09-29T00:00:00Z",
            results: [ScoutExtractResult(sourceId: "order-feed", verdict: .upcomingListings,
                                         events: (0..<pairs).map { i in
                                             ScoutExtractEvent(title: "Paired Recital \(i)", presenter: nil,
                                                               venue: venue, performanceDate: "2026-11-30",
                                                               sourceUrl: "https://order.example/run-\(i)")
                                         }, note: "read")])
        _ = await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty, today: today,
                                            now: Date(timeIntervalSince1970: 1_790_000_000), into: ctx)
        try ctx.save()

        let after = try ModelContext(container).fetch(FetchDescriptor<Prospect>())
        let lines = after.map { p in
            [p.naturalKey, p.performanceDate ?? "", p.sourceListingURL ?? "", p.runSourceURLs.sorted().joined(separator: ","),
             p.runNights.joined(separator: ","), String(p.missedScoutCount)].joined(separator: "|")
        }
        let digest = Self.byteOrder(lines).joined(separator: "\n")
        return (digest, after.filter { $0.performanceDate == "2026-11-30" }.count)
    }

    @Test(arguments: [6, 24])
    func twoLandingsOfTheSameShowsStoredInOppositeOrdersLeaveTheSameStore(pairs: Int) async throws {
        let forward = try await Self.land(pairs: pairs, reversed: false)
        let backward = try await Self.land(pairs: pairs, reversed: true)
        // The control: every pair really reached the run URL arm and re-keyed one of its rows, or two equal
        // stores could just be two landings that decided nothing (L159).
        #expect(forward.rekeyed == pairs && backward.rekeyed == pairs, Comment(rawValue:
            "the landings re-keyed \(forward.rekeyed) and \(backward.rekeyed) of \(pairs) pairs onto the new night, "
            + "so the order dependent decision was not exercised"))
        #expect(forward.digest == backward.digest, Comment(rawValue:
            "two landings of the same shows left different stores because the shows were stored in a different "
            + "order (\(pairs) pairs)"))
    }

    // MARK: the sibling: the history the classify pass matches against

    @Test func historyRecordsDoNotDependOnTheOrderTheShowsWereRead() throws {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = container.mainContext
        var shows: [Prospect] = []
        for (key, status) in [("h-3", "booked"), ("h-1", "passed"), ("h-2", "booked"), ("h-4", "passed")] {
            let p = Self.stored(key)
            if status == "booked" { p.showOutcomeRaw = ShowOutcome.booked.rawValue }
            ctx.insert(p)
            shows.append(p)
        }
        let forward = LocalHistory.records(from: shows)
        let backward = LocalHistory.records(from: shows.reversed())
        #expect(!forward.isEmpty, Comment(rawValue: "no history records came back, so order was not measured"))
        #expect(forward == backward, Comment(rawValue:
            "the history records follow the order the shows were read in, and `history.first(where:)` picks the "
            + "first of them"))
    }
}
