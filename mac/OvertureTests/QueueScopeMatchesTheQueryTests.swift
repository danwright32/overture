import Testing
import Foundation
import SwiftData

// #3507: the queue derives its own scope from the corpus instead of fetching the table a second time,
// and this is what holds that derivation to what the query it replaced actually returned.
//
// `QueueView` held TWO `@Query` properties over `Prospect`. One dropped dismissed shows and sorted by
// date then fit; the other was the whole-store corpus. SwiftData satisfies each independently, and
// measured against the live store on 2026-09-05 a repeat of the identical descriptor cost 96% of the
// cold one, so the second read was paid in full (`QueueRenderPassLiveStoreCostTests`).
//
// WHY THIS SUITE ASKS SWIFTDATA RATHER THAN ASSERTING AN EXPECTED ORDER. The replacement has to produce
// the same rows in the same order as a store the app no longer asks, and the risky half is the ORDER,
// not the filter: `performanceDate` is an optional `String`, so where a nil sorts is decided by
// SQLite in one reading and by Foundation in the other, and neither is obvious from reading either.
// A test written against my belief about that would pin the belief. So every case below fetches with
// the descriptors the removed `@Query` used and compares the derivation against THAT answer (L52, L58).
//
// WHAT IT MAY NOT ASSERT, and finding this out is why the suite is shaped the way it is. Comparing the
// two lists element for element went red on the first corpus big enough to hold a FULL TIE, two dateless
// shows on the same fit score, and it stayed red after the derivation was made stable, with a different
// pair flipping. SQLite defines no order for rows whose sort keys are equal, and the unsorted fetch and
// the sorted one do not agree about them either, so an element-wise comparison is asserting about
// something the removed query never promised. Pinning it would have made this suite fail on a corpus
// nobody changed.
//
// So the comparison is made in the terms the descriptors actually decide: the same rows, and the same
// sequence of sort-key GROUPS, with each group holding the same members. Every ordering the query really
// determined is held; the one it left open is not. The tie order the derivation does produce is asserted
// separately and on its own terms, because there it is STABLE and the query was not, which is the one
// place this change is deliberately better than what it replaced rather than identical to it.
@MainActor
@Suite("The derived queue scope matches the query it replaced (#3507)")
struct QueueScopeMatchesTheQueryTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(
            for: Schema([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self,
                         WatchedSource.self]),
            configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // The descriptor `QueueView.prospects` carried before #3507, spelled here once so both halves of
    // every comparison below come from it.
    private var theQueryThatWasRemoved: FetchDescriptor<Prospect> {
        FetchDescriptor<Prospect>(
            predicate: #Predicate<Prospect> { $0.statusRaw != "dismissed" },
            sortBy: [SortDescriptor(\Prospect.performanceDate, order: .forward),
                     SortDescriptor(\Prospect.fitScore, order: .reverse)])
    }

    private func insert(_ ctx: ModelContext, key: String, date: String?, fit: Int,
                        status: ReviewStatus) {
        let p = Prospect(naturalKey: key, groupName: "Ensemble \(key)", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: date, sourceListingURL: nil,
                         priorRelationship: "none", production: "presenter", profile: "strong",
                         coverage: "likely_uncovered", fitScore: fit, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        ctx.insert(p)
    }

    // A row's position as the descriptors see it: everything they discriminate on, and nothing else.
    // Two rows with the same value here are a full tie the query left unordered.
    private func sortKey(_ p: Prospect) -> String { "\(p.performanceDate ?? "~nil")|\(p.fitScore)" }

    // The list reduced to what the ordering actually determined: the sequence of distinct sort keys, and
    // the SET of rows under each. Two answers that agree here differ only where the query itself was
    // silent.
    private func groups(_ rows: [Prospect]) -> [(key: String, members: Set<String>)] {
        var out: [(key: String, members: Set<String>)] = []
        for row in rows {
            let key = sortKey(row)
            if out.last?.key == key { out[out.count - 1].members.insert(row.naturalKey) }
            else { out.append((key, [row.naturalKey])) }
        }
        return out
    }

    private struct Comparison {
        var queryKeys: [String]
        var derivedKeys: [String]
        var agrees: Bool
        var rowCount: Int
        var largestTie: Int
    }

    private func compare(_ ctx: ModelContext) throws -> Comparison {
        let queried = try ctx.fetch(theQueryThatWasRemoved)
        let everything = try ctx.fetch(FetchDescriptor<Prospect>())
        let derived = QueueModel.queueScope(everything)

        let q = groups(queried), d = groups(derived)
        let agrees = q.count == d.count && zip(q, d).allSatisfy { $0.key == $1.key && $0.members == $1.members }
        return Comparison(queryKeys: queried.map(\.naturalKey),
                          derivedKeys: derived.map(\.naturalKey),
                          agrees: agrees,
                          rowCount: queried.count,
                          largestTie: q.map(\.members.count).max() ?? 0)
    }

    @Test("the same rows, in the same order, on an ordinary spread")
    func matchesOnAnOrdinarySpread() throws {
        let ctx = ModelContext(try container())
        // Dates deliberately out of insertion order, and two rows sharing a date so the fit tiebreak
        // is exercised rather than left to insertion order.
        insert(ctx, key: "c", date: "2026-09-11", fit: 5, status: .new)
        insert(ctx, key: "a", date: "2026-08-02", fit: 3, status: .drafted)
        insert(ctx, key: "d", date: "2026-09-11", fit: 9, status: .contacted)
        insert(ctx, key: "b", date: "2026-08-30", fit: 7, status: .new)
        let c = try compare(ctx)

        #expect(c.rowCount == 4, "the query returned the wrong set, so this compared the wrong thing")
        #expect(c.largestTie == 1, "this corpus was meant to have no full tie in it")
        // With no tie anywhere, the two answers must agree element for element, which is the strongest
        // form this comparison can take and is why the fixture is built without one.
        #expect(c.derivedKeys == c.queryKeys)
        #expect(c.queryKeys == ["a", "b", "d", "c"],
                "neither descriptor did what it was asked, so agreement means nothing")
    }

    @Test("a dismissed show is dropped by both")
    func dropsDismissedByBoth() throws {
        let ctx = ModelContext(try container())
        insert(ctx, key: "kept", date: "2026-09-01", fit: 5, status: .new)
        insert(ctx, key: "gone", date: "2026-09-02", fit: 5, status: .dismissed)
        let c = try compare(ctx)

        #expect(c.derivedKeys == c.queryKeys)
        #expect(c.queryKeys == ["kept"], "the predicate did not drop the dismissed row, so nothing was tested")
    }

    // The case the comment at the top of this suite is about, and the one nobody can answer by reading
    // either implementation: a show with no date at all.
    @Test("a show with no performance date sorts where the query put it")
    func matchesWhereANilDateSorts() throws {
        let ctx = ModelContext(try container())
        insert(ctx, key: "dated-early", date: "2026-08-01", fit: 5, status: .new)
        insert(ctx, key: "no-date", date: nil, fit: 6, status: .new)
        insert(ctx, key: "dated-late", date: "2026-12-31", fit: 7, status: .new)
        let c = try compare(ctx)

        #expect(c.rowCount == 3, "a row went missing, so the orderings were compared over the wrong set")
        #expect(c.largestTie == 1)
        #expect(c.derivedKeys == c.queryKeys)
        #expect(c.queryKeys.first == "no-date",
                "the dateless show did not sort first, so this pins the wrong answer")
    }

    @Test("an empty date string is not a missing one")
    func matchesOnAnEmptyDateString() throws {
        let ctx = ModelContext(try container())
        insert(ctx, key: "empty", date: "", fit: 5, status: .new)
        insert(ctx, key: "nil", date: nil, fit: 6, status: .new)
        insert(ctx, key: "dated", date: "2026-08-01", fit: 7, status: .new)
        let c = try compare(ctx)

        #expect(c.rowCount == 3)
        #expect(c.largestTie == 1)
        #expect(c.derivedKeys == c.queryKeys)
    }

    // A corpus large enough that any ordering difference has somewhere to hide, on the same shape the
    // cost fixture uses: most rows untriaged, dates spread over four months, ties everywhere.
    @Test("the same ordering over a corpus full of ties")
    func matchesOverACorpusWithTies() throws {
        let ctx = ModelContext(try container())
        for n in 0..<400 {
            let day = 1 + (n % 27)
            let month = 8 + (n % 4)
            insert(ctx, key: String(format: "row-%03d", n),
                   date: n % 37 == 0 ? nil : String(format: "2026-%02d-%02d", month, day),
                   fit: 4 + (n % 5),
                   status: n % 11 == 0 ? .dismissed : .new)
        }
        let c = try compare(ctx)

        #expect(c.rowCount > 300, "too few rows survived the predicate to compare orderings over")
        #expect(c.largestTie > 1, "this corpus held no full tie, so it did not exercise the hard case")
        #expect(c.agrees, "the two answers disagree about an ordering the descriptors DO determine")
    }

    // #3507: the half where the derivation is deliberately NOT the same as the query it replaced.
    //
    // A full tie has no defined order in SQLite, so the removed query could return two tied cards either
    // way round on two reads of an unchanged store. `sorted(using:)` alone is no better: Swift's sort is
    // not stable, so it too can answer differently for reasons nothing in the data explains. Neither is
    // acceptable on a list Dan reads, because two cards swapping places is indistinguishable from
    // something having changed.
    //
    // Asserted over the DERIVATION alone rather than against a fetch, because it is a property of this
    // code and must hold whatever SQLite decides to do later.
    @Test("tied rows keep the order they arrived in, every time")
    func breaksTiesStablyAndRepeatably() throws {
        let ctx = ModelContext(try container())
        for n in 0..<60 {
            // Every row a full tie with every other: no date, one fit score.
            insert(ctx, key: String(format: "tied-%02d", n), date: nil, fit: 5, status: .new)
        }
        let everything = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(everything.count == 60)

        let arrivalOrder = everything.map(\.naturalKey)
        let once = QueueModel.queueScope(everything).map(\.naturalKey)
        let twice = QueueModel.queueScope(everything).map(\.naturalKey)

        #expect(once == arrivalOrder, "a tie was reordered, so the answer depends on the sort's internals")
        #expect(once == twice, "two derivations over one unchanged list disagreed")

        // And the reverse input, so the assertion above cannot be satisfied by an implementation that
        // happens to leave any list alone.
        let reversed = Array(everything.reversed())
        #expect(QueueModel.queueScope(reversed).map(\.naturalKey) == arrivalOrder.reversed())
    }
}
