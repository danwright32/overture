import Testing
import Foundation
import SwiftData
@testable import Overture

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
}
