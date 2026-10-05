import Testing
import Foundation
import SwiftData

// #4327 step 0.7 (RC4): the working set's own COUNTERS, so what each source of a landing costs is a count
// rather than a reading of the code. Before this the only counter the working set exposed was
// `foldValidations`. #4333 (A4) replaced the stored shows cache these first counted with the batch tables, so
// they count the tables' one build and the rows each source re-judges instead.
//
// Each counter is pinned here to an exact value on a store small enough to count by hand, so a counter that
// never moves, or moves at the wrong site, fails (L63, L159). The landing attribution probe reports them per
// source on a store clone; these tests are what make its numbers mean what they say.
@MainActor
@Suite("A scout landing counts its table builds, folds, re-judged rows and row visits (#4327)")
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

    // Five rows. The first batch question folds all five for the first time and builds the tables from them;
    // the second re-judges nothing; a row joining is counted as a join and re-judged alone; a title written in
    // place is counted as a changed fold and re-judged, while the joined row, still an unsaved insert, is not
    // marked again: it is watched, and nothing has written it since (#4482).
    // Every count below is exact.
    @Test func eachCounterMovesAtItsOwnSiteByExactlyItsOwnAmount() throws {
        let ctx = try context()
        let rows = (0..<5).map { stored(ctx, "Row \($0)", Self.night(10 + $0), url: "https://r.example/\($0)") }
        try ctx.save()
        let landing = ScoutLandingStore(context: ctx)

        _ = try landing.ambiguousURLs(adding: [])
        var c = landing.counters
        #expect(c.rowsRead == 5 && c.tableBuilds == 1 && c.tableRowsRejudged == 0
                && c.firstFolds == 5 && c.foldsChanged == 0
                && c.rowsJoined == 0, Comment(rawValue: "after the first question: \(c)"))
        // The build walks all five rows once.
        #expect(c.rowsWalked == 5, Comment(rawValue: "the first question walked \(c.rowsWalked) rows, not 5"))

        _ = try landing.ambiguousURLs(adding: [])
        c = landing.counters
        #expect(c.tableBuilds == 1 && c.tableRowsRejudged == 0 && c.rowsWalked == 5, Comment(rawValue:
            "an unchanged store was walked or re-judged again: \(c)"))

        let fresh = stored(ctx, "Row 5", Self.night(20), url: "https://r.example/5")
        landing.inserted(fresh)
        _ = try landing.ambiguousURLs(adding: [])
        c = landing.counters
        #expect(c.rowsJoined == 1 && c.firstFolds == 6 && c.tableBuilds == 1 && c.tableRowsRejudged == 1
                && c.rowsWalked == 5, Comment(rawValue: "a joining row did not count as a join judged alone: \(c)"))

        rows[0].groupName = "Row 0: Encore"
        _ = try landing.ambiguousURLs(adding: [])
        c = landing.counters
        // #4482: the joined row, still an unsaved insert, is watched and was not written since it was marked, so
        // it is not marked again and only the rewritten row is judged again (before #4460 it was rebuilt on every
        // read until its source saved; under #4460 alone it was checked and found unchanged).
        #expect(c.foldsChanged == 1 && c.tableBuilds == 1 && c.tableRowsRejudged == 2 && c.foldValidations >= 1,
                Comment(rawValue: "a title written in place did not count as a changed fold judged again: \(c)"))

        let handed = try landing.rows().count
        #expect(landing.counters.rowsHandedOut == handed, Comment(rawValue:
            "rows handed to a caller were counted as \(landing.counters.rowsHandedOut), not \(handed); the "
            + "working set's own reads must not count as a caller's"))
    }

    // The difference of two snapshots is what one source cost, which is how the probe reports per source.
    @Test func aSnapshotDifferenceIsTheWorkBetweenTheTwo() {
        var a = ScoutLandingStore.Counters()
        a.tableBuilds = 1; a.rowsWalked = 10; a.rowsJoined = 2
        var b = a
        b.tableBuilds = 3; b.tableRowsRejudged = 4; b.rowsWalked = 25; b.rowsJoined = 5
        let d = b - a
        #expect(d.tableBuilds == 2 && d.tableRowsRejudged == 4 && d.rowsWalked == 15
                && d.rowsJoined == 3 && d.rowsRead == 0)
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
                                        onLandingStep: { steps.append(($0, $1.counters)) }, into: ctx)

        #expect(steps.map(\.0) == ["one", "two", "three", ScoutLandingStore.Counters.afterReconcile],
                Comment(rawValue: "the steps reported were \(steps.map(\.0))"))
        guard steps.count == 4 else { return }
        let second = steps[1].1 - steps[0].1
        #expect(second.rowsJoined == 2, Comment(rawValue:
            "the source that brought two new shows reported \(second.rowsJoined) inserts"))
        #expect(steps[0].1.rowsJoined == 0 && (steps[2].1 - steps[1].1).rowsJoined == 0)
        #expect(steps[0].1.tableBuilds == 1 && steps[2].1.tableBuilds == 1, Comment(rawValue:
            "the landing built its batch tables \(steps[2].1.tableBuilds) times, not once on the first source"))
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
        "table builds \(tableBuilds), rows re-judged \(tableRowsRejudged), first folds \(firstFolds), "
            + "folds changed \(foldsChanged), rows joined \(rowsJoined), fold validations \(foldValidations), "
            + "rows read \(rowsRead), rows handed out \(rowsHandedOut), rows walked \(rowsWalked), "
            + "rows looked up \(rowsLookedUp)"
    }
}
