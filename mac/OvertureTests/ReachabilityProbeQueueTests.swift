import Testing
import Foundation
import SwiftData

// #1308 Layer 2 Phase 1: the probe work-list is built from Dan's hand-picked keys DIRECTLY, bypassing the
// normal "must be kept" prep gate (a Review-stage .new show can never enter the prep queue via
// needsPrepEligible). Every probe item is contacts-only, and the queue is marked a probe so the runner
// researches without drafting and the results are stamped as a probe run.
@MainActor
@Suite("Reachability probe queue (#1308)")
struct ReachabilityProbeQueueTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func insert(_ ctx: ModelContext, group: String, date: String, status: ReviewStatus) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 6, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: status)
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    @Test func buildsContactsOnlyProbeItemsForHandPickedNewShows() throws {
        let ctx = ModelContext(try container())
        let a = insert(ctx, group: "Aurora Strings", date: "2026-09-12", status: .new)   // Review-stage, not kept
        let b = insert(ctx, group: "Boreal Brass", date: "2026-09-12", status: .new)
        _ = insert(ctx, group: "Not Chosen", date: "2026-09-12", status: .new)

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [a, b])

        #expect(Set(queue.items.map(\.naturalKey)) == [a, b])   // only the hand-picked keys, though .new
        // Contacts-only is what tells the runner not to draft; no queue-level probe flag on the wire.
        #expect(queue.items.allSatisfy { $0.reprepMode == "contacts_only" })
    }

    // #1597 Phase 4.3: ProbeBatch decides the grouping, but the QUEUE has to actually carry it. These are
    // two separate claims and the pure planner passing says nothing about the wiring.
    private func insert(_ ctx: ModelContext, group: String, date: String,
                        presenter: String?, venue: String) -> String {
        let key = Prospect.makeNaturalKey(groupName: group, performanceDate: date, venue: venue)
        let p = Prospect(naturalKey: key, groupName: group, discipline: "theater", venue: venue,
                         performanceDate: date, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 6, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        p.presenter = presenter
        ctx.insert(p)
        try? ctx.save()
        return key
    }

    @Test func oneProducersShowsBecomeASingleItemThatAnswersForTheRest() throws {
        let ctx = ModelContext(try container())
        let a = insert(ctx, group: "Show A", date: "2026-09-12", presenter: "FRIGID New York", venue: "Under St Marks")
        let b = insert(ctx, group: "Show B", date: "2026-09-13", presenter: "FRIGID New York", venue: "The Kraine Theater")
        let c = insert(ctx, group: "Show C", date: "2026-09-14", presenter: "FRIGID New York", venue: "Under St Marks")

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [a, b, c])

        #expect(queue.items.count == 1)
        let item = try #require(queue.items.first)
        // Whichever show is the representative, the other two ride along and every show is accounted for.
        let covered = try #require(item.alsoAnswersFor)
        #expect(Set([item.naturalKey] + covered) == Set([a, b, c]))
        #expect(covered.count == 2)
        #expect(covered == covered.sorted())   // stable output for an identical selection
    }

    // The expensive-but-correct case. A room that rents itself out is three unrelated productions that
    // share an address, so one contact must never be stamped across them: three items, three researches.
    @Test func aRoomThatRentsItselfOutStillCostsOneResearchPerShow() throws {
        let ctx = ModelContext(try container())
        let a = insert(ctx, group: "Show A", date: "2026-09-12", presenter: "Green Room 42", venue: "Green Room 42")
        let b = insert(ctx, group: "Show B", date: "2026-09-13", presenter: "Green Room 42", venue: "Green Room 42")
        let c = insert(ctx, group: "Show C", date: "2026-09-14", presenter: "Green Room 42", venue: "Green Room 42")

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [a, b, c])

        #expect(queue.items.count == 3)
        #expect(queue.items.allSatisfy { $0.alsoAnswersFor == nil })
    }

    // The grouping must be judged against the whole store. Dan ticks ONE night, on which this producer
    // has a single show at a single venue; the store knows it also plays elsewhere, so it still groups.
    @Test func theGroupingSeesTheWholeStoreNotJustTheSelectedNight() throws {
        let ctx = ModelContext(try container())
        let a = insert(ctx, group: "Show A", date: "2026-09-12", presenter: "FRIGID New York", venue: "Under St Marks")
        let b = insert(ctx, group: "Show B", date: "2026-09-12", presenter: "FRIGID New York", venue: "Under St Marks")
        _ = insert(ctx, group: "Elsewhere", date: "2027-01-04", presenter: "FRIGID New York", venue: "The Kraine Theater")

        let queue = PrepQueueService.buildProbeQueue(from: ctx, generatedAt: "now", keys: [a, b])

        #expect(queue.items.count == 1)
        #expect(queue.items[0].alsoAnswersFor?.count == 1)
    }
}
