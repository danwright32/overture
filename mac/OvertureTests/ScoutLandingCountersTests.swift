import Testing
import Foundation
import SwiftData

// #4327 step 0.7 (RC4): the working set's own COUNTERS, so whether `storedShowsPerURL` serves its cache for
// sources 2 to 39 is a count rather than a reading of the code. Before this the only counter the working set
// exposed was `foldValidations`, and the sampler attributes both the stored shows build and every source's
// `addShows` to one call site, so nothing could tell a cache hit from a rebuild.
//
// Each counter is pinned here to an exact value on a store small enough to count by hand, so a counter that
// never moves, or moves at the wrong site, fails (L63, L159). The landing attribution probe reports them per
// source on a store clone; these tests are what make its numbers mean what they say.
@MainActor
@Suite("A scout landing counts its stored shows builds, cache hits, generation moves and row visits (#4327)")
struct ScoutLandingCountersTests {
    private static let today = "2026-10-01"
    private static let room = "The Green Room 42"

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema, configurations: [
            ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)]))
    }

    // A source the app queued and has read before, so its results LAND rather than resolving to nothing
    // (an id the app never queued lands nothing, by design).
    private func queued(_ ctx: ModelContext, _ ids: [String]) {
        for id in ids {
            let s = WatchedSource(sourceId: id, orgName: "Org \(id)", listingsURL: "https://\(id).example/events",
                                  kind: .html)
            s.pendingContentHash = "new-hash-\(id)"
            s.hasUnreadChanges = true
            s.successfulCheckCount = WatchedSource.warmupRuns
            s.baselineFeedCount = 1
            ctx.insert(s)
        }
    }

    @discardableResult
    private func stored(_ ctx: ModelContext, _ title: String, _ night: String, url: String) -> Prospect {
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: title, performanceDate: night,
                                                             venue: Self.room),
                         groupName: title, discipline: "theatre", venue: Self.room, performanceDate: night,
                         sourceListingURL: url, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private static func night(_ n: Int) -> String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: n,
                                                        to: EasternDate.date(from: today)!)!
        return EasternDate.dayString(from: day)
    }

    // MARK: the working set on its own, counted by hand

    // Five rows. The first stored shows read folds all five for the first time and builds; the second is
    // served from the cache; a row joining moves the generation by insertion and forces a build; a title
    // written in place moves it by a changed fold and forces another. Every count below is exact.
    @Test func eachCounterMovesAtItsOwnSiteByExactlyItsOwnAmount() throws {
        let ctx = try context()
        let rows = (0..<5).map { stored(ctx, "Row \($0)", Self.night(10 + $0), url: "https://r.example/\($0)") }
        try ctx.save()
        let landing = ScoutLandingStore(context: ctx)

        _ = try landing.storedShowsPerURL()
        var c = landing.counters
        #expect(c.rowsRead == 5 && c.storedShowsBuilds == 1 && c.storedShowsCacheHits == 0
                && c.generationMovesFirstFold == 5 && c.generationMovesFoldChanged == 0
                && c.generationMovesInserted == 0, Comment(rawValue: "after the first read: \(c)"))
        // The fold loop walks all five rows and the build walks them again.
        #expect(c.rowsWalked == 10, Comment(rawValue: "the first read walked \(c.rowsWalked) rows, not 10"))

        _ = try landing.storedShowsPerURL()
        c = landing.counters
        #expect(c.storedShowsBuilds == 1 && c.storedShowsCacheHits == 1, Comment(rawValue:
            "an unchanged store was not served from the cache: \(c)"))
        #expect(c.rowsWalked == 15, Comment(rawValue: "a cache hit walked \(c.rowsWalked - 10) rows, not 5"))

        let fresh = stored(ctx, "Row 5", Self.night(20), url: "https://r.example/5")
        landing.inserted(fresh)
        _ = try landing.storedShowsPerURL()
        c = landing.counters
        #expect(c.generationMovesInserted == 1 && c.generationMovesFirstFold == 6
                && c.storedShowsBuilds == 2 && c.storedShowsCacheHits == 1, Comment(rawValue:
            "a joining row did not count as an insert and a rebuild: \(c)"))

        rows[0].groupName = "Row 0: Encore"
        _ = try landing.storedShowsPerURL()
        c = landing.counters
        #expect(c.generationMovesFoldChanged == 1 && c.storedShowsBuilds == 3 && c.foldValidations >= 1,
                Comment(rawValue: "a title written in place did not count as a changed fold and a rebuild: \(c)"))

        let handed = try landing.rows().count
        #expect(landing.counters.rowsHandedOut == handed, Comment(rawValue:
            "rows handed to a caller were counted as \(landing.counters.rowsHandedOut), not \(handed); the "
            + "working set's own reads must not count as a caller's"))
    }

    // The difference of two snapshots is what one source cost, which is how the probe reports per source.
    @Test func aSnapshotDifferenceIsTheWorkBetweenTheTwo() {
        var a = ScoutLandingStore.Counters()
        a.storedShowsBuilds = 1; a.rowsWalked = 10; a.generationMovesInserted = 2
        var b = a
        b.storedShowsBuilds = 3; b.storedShowsCacheHits = 4; b.rowsWalked = 25; b.generationMovesInserted = 5
        let d = b - a
        #expect(d.storedShowsBuilds == 2 && d.storedShowsCacheHits == 4 && d.rowsWalked == 15
                && d.generationMovesInserted == 3 && d.rowsRead == 0)
    }

    // MARK: an ingest reports them per source

    private func event(_ title: String, _ night: Int) -> ScoutExtractEvent {
        ScoutExtractEvent(title: title, presenter: Self.room, venue: Self.room,
                          performanceDate: Self.night(night), sourceUrl: "https://src.example/\(title)")
    }

    // Three sources: the first and third re-list what is stored, the second brings two new shows. The hook
    // is called once per LANDED source, in order, then once after the reconcile's read; every snapshot is
    // cumulative, so the second source's difference carries its two inserts and nothing else does.
    @Test func ingestReportsTheCountersAfterEachLandedSource() async throws {
        let ctx = try context()
        for k in 0..<3 { stored(ctx, "Kept \(k)", Self.night(30 + k), url: "https://src.example/Kept \(k)") }
        queued(ctx, ["one", "two", "three"])
        try ctx.save()
        let results = ScoutExtractResults(version: 1, generatedAt: "2026-09-29T00:00:00Z", results: [
            ScoutExtractResult(sourceId: "one", verdict: .upcomingListings,
                               events: (0..<3).map { event("Kept \($0)", 30 + $0) }, note: nil),
            ScoutExtractResult(sourceId: "two", verdict: .upcomingListings,
                               events: [event("New Alpha", 40), event("New Beta", 41)], note: nil),
            ScoutExtractResult(sourceId: "three", verdict: .upcomingListings,
                               events: (0..<3).map { event("Kept \($0)", 30 + $0) }, note: nil),
        ])
        var steps: [(String, ScoutLandingStore.Counters)] = []
        await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty, today: Self.today,
                                        onLandingStep: { steps.append(($0, $1)) }, into: ctx)

        #expect(steps.map(\.0) == ["one", "two", "three", ScoutLandingStore.Counters.afterReconcile],
                Comment(rawValue: "the steps reported were \(steps.map(\.0))"))
        guard steps.count == 4 else { return }
        let second = steps[1].1 - steps[0].1
        #expect(second.generationMovesInserted == 2, Comment(rawValue:
            "the source that brought two new shows reported \(second.generationMovesInserted) inserts"))
        #expect(steps[0].1.generationMovesInserted == 0 && (steps[2].1 - steps[1].1).generationMovesInserted == 0)
        #expect(steps[0].1.storedShowsBuilds >= 1, Comment(rawValue:
            "the first source built no stored shows, so the counters are not wired to the landing"))
    }

    // A landing that reconciled nothing reports no reconcile step, so a probe never reads a reconcile that did
    // not run as a cheap one. Here the only source is one the app never queued, so nothing lands and no report
    // reaches the reconcile.
    @Test func noReconcileStepIsReportedWhenNoReconcileRan() async throws {
        let ctx = try context()
        for k in 0..<2 { stored(ctx, "Kept \(k)", Self.night(30 + k), url: "https://src.example/Kept \(k)") }
        try ctx.save()
        let results = ScoutExtractResults(version: 1, generatedAt: "2026-09-29T00:00:00Z", results: [
            ScoutExtractResult(sourceId: "never-queued", verdict: .upcomingListings,
                               events: [event("Kept 0", 30)], note: nil),
        ])
        var steps: [String] = []
        await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty, today: Self.today,
                                        onLandingStep: { label, _ in steps.append(label) }, into: ctx)
        #expect(steps.isEmpty, Comment(rawValue: "a landing that reconciled nothing reported \(steps)"))
    }

    // MARK: the counters are pure counting

    // Counting must not change what a landing does. The same landing is run once with the hook and once
    // without, and the stored rows must be identical.
    @Test func reportingTheCountersChangesNothingTheLandingWrites() async throws {
        func run(_ observe: Bool) async throws -> [String] {
            let ctx = try context()
            for k in 0..<3 { stored(ctx, "Kept \(k)", Self.night(30 + k), url: "https://src.example/Kept \(k)") }
            queued(ctx, ["one"])
            try ctx.save()
            let results = ScoutExtractResults(version: 1, generatedAt: "2026-09-29T00:00:00Z", results: [
                ScoutExtractResult(sourceId: "one", verdict: .upcomingListings,
                                   events: (0..<3).map { event("Kept \($0)", 30 + $0) } + [event("New", 44)],
                                   note: nil),
            ])
            await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty, today: Self.today,
                                            onLandingStep: observe ? { _, _ in } : nil, into: ctx)
            return try ctx.fetch(FetchDescriptor<Prospect>()).map { "\($0.naturalKey) \($0.groupName)" }.sorted()
        }
        let observed = try await run(true)
        let plain = try await run(false)
        #expect(observed == plain && observed.count == 4)
    }
}

// How the landing attribution probe prints a snapshot. Here rather than beside the counters, because a
// sentence in the app's source is copy to `docs/copy-inventory.md`, and this one is only ever read in a log.
extension ScoutLandingStore.Counters: CustomStringConvertible {
    var description: String {
        "builds \(storedShowsBuilds), cache hits \(storedShowsCacheHits), generation moves \(generationMoves) "
            + "(first fold \(generationMovesFirstFold), fold changed \(generationMovesFoldChanged), inserted "
            + "\(generationMovesInserted)), fold validations \(foldValidations), rows read \(rowsRead), "
            + "rows handed out \(rowsHandedOut), rows walked \(rowsWalked)"
    }
}
