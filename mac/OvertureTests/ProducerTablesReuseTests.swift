import Testing
import Foundation
import SwiftData

// #3742: the presenter-against-venue table, built once and reused until one of its inputs moves.
//
// WHAT IT COSTS TODAY. `ProducerGate.VenueBrands` is 40.6 ms a pass on the live store (5 runs, 40.1 to
// 42.5), the largest single piece inside `QueueModel.scope`, and the `ProducerGate.Corpus` it is built
// from is 27.2 ms beside it. Neither is an un-optimised loop: #1963 indexed the walk and #3743 stopped
// it being built twice. They cost that because there are roughly 400 distinct presenters.
//
// THE HARD PART IS INVALIDATION AND IT IS THE WHOLE ISSUE. A wrong `VenueBrands` silently changes which
// presenters the producer gate admits, which changes which shows Dan is offered. That is a product
// regression no cost test would see. So this suite is mostly about the key, and the three directions it
// has to be right in are each produced here rather than reasoned about: a presenter, a venue, and an
// override. A key that misses one is silently wrong only for that one (L40).
@Suite("The producer tables are reused only while their inputs hold (#3742)")
struct ProducerTablesReuseTests {

    private func shows(_ pairs: [(String?, String?)]) -> [ProducerGate.Show] {
        pairs.map { ProducerGate.Show(presenter: $0.0, venue: $0.1) }
    }

    private var base: [ProducerGate.Show] {
        shows([("Carnegie Hall", "Weill Recital Hall"),
               ("The Knights", "Weill Recital Hall"),
               ("Carnegie Hall", "Zankel Hall"),
               ("Ensemble Éclat", "Merkin Hall")])
    }

    @Test func theSameInputsKeyTheSame() {
        let first = QueueModel.ProducerTables.key(shows: base, overrides: .none)
        let second = QueueModel.ProducerTables.key(shows: base, overrides: .none)
        #expect(first == second, """
            two keys over identical inputs differ, so the memo could never hit and the reuse this exists \
            for would silently never happen (L289)
            """)
    }

    @Test func aChangedPresenterChangesTheKey() {
        var changed = base
        changed[1] = ProducerGate.Show(presenter: "The Knights Ensemble", venue: "Weill Recital Hall")
        #expect(QueueModel.ProducerTables.key(shows: base, overrides: .none)
                != QueueModel.ProducerTables.key(shows: changed, overrides: .none),
                "a presenter changed and the key did not, so a stale table would decide which shows Dan sees")
    }

    @Test func aChangedVenueChangesTheKey() {
        var changed = base
        changed[1] = ProducerGate.Show(presenter: "The Knights", venue: "Zankel Hall")
        #expect(QueueModel.ProducerTables.key(shows: base, overrides: .none)
                != QueueModel.ProducerTables.key(shows: changed, overrides: .none),
                "a venue changed and the key did not, which is the second of the three directions")
    }

    @Test func aChangedOverrideChangesTheKey() {
        let promoted = ProducerOverrides(promoted: ["carnegie hall"], demoted: [])
        #expect(QueueModel.ProducerTables.key(shows: base, overrides: .none)
                != QueueModel.ProducerTables.key(shows: base, overrides: promoted),
                "an override changed and the key did not, which is the third direction")
        let demoted = ProducerOverrides(promoted: [], demoted: ["carnegie hall"])
        #expect(QueueModel.ProducerTables.key(shows: base, overrides: promoted)
                != QueueModel.ProducerTables.key(shows: base, overrides: demoted),
                "promoting and demoting the same name key the same, so one would serve the other's table")
    }

    @Test func aRowSwappedForAnotherChangesTheKeyEvenThoughTheCountIsTheSame() {
        var changed = base
        changed[3] = ProducerGate.Show(presenter: "Orchestra of St Luke's", venue: "Merkin Hall")
        #expect(QueueModel.ProducerTables.key(shows: base, overrides: .none)
                != QueueModel.ProducerTables.key(shows: changed, overrides: .none),
                "a count is blind to a row swapped for another, which is why the key is not a count")
    }

    @Test func theOverrideSetsKeyTheSameWhateverOrderTheyWereBuiltIn() {
        // A Set's iteration order is not stable between instances, so hashing one unsorted would make
        // two EQUAL overrides key differently and the memo would never hit: the failure that reads as
        // the optimisation simply not working, with nothing saying so (L289).
        let one = ProducerOverrides(promoted: ["a", "b", "c"], demoted: ["x", "y"])
        let other = ProducerOverrides(promoted: ["c", "a", "b"], demoted: ["y", "x"])
        #expect(QueueModel.ProducerTables.key(shows: base, overrides: one)
                == QueueModel.ProducerTables.key(shows: base, overrides: other))
    }

    @Test func handingTheTablesInGivesTheSameScopeAsBuildingThem() throws {
        let container = try TestModelContainer.inMemory([Prospect.self, Recipient.self])
        let ctx = ModelContext(container)
        for n in 0..<40 {
            ctx.insert(Prospect(naturalKey: "row-\(n)",
                                groupName: ["Carnegie Hall", "The Knights", "Ensemble Éclat"][n % 3],
                                discipline: "music",
                                venue: ["Weill Recital Hall", "Zankel Hall", "Merkin Hall"][n % 3],
                                performanceDate: "2027-05-0\(1 + (n % 9))",
                                sourceListingURL: nil, priorRelationship: "none", production: "self",
                                profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                                fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                                possibleMatchName: nil, status: .new))
        }
        try ctx.save()
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())

        let built = QueueModel.scope(from: rows, corpus: rows, cardKeys: [])
        let tables = QueueModel.ProducerTables(
            shows: rows.map { ProducerGate.Show(presenter: $0.presenter, venue: $0.venue) },
            overrides: .none)
        let handed = QueueModel.scope(from: rows, corpus: rows, cardKeys: [], producerTables: tables)

        // FIELD FOR FIELD over the rows, not a count: two scopes with the same number of rows and
        // different producer verdicts is exactly the regression this issue warns about, and a count
        // cannot see it.
        #expect(!built.rows.isEmpty, "the fixture produced no rows, so nothing below was compared")
        #expect(built.rows.count == handed.rows.count)
        #expect(built.rows.map(\.id) == handed.rows.map(\.id))
        #expect(built.rows.map(\.presenter) == handed.rows.map(\.presenter))
        #expect(built.rows.map(\.groupName) == handed.rows.map(\.groupName))
    }
}
