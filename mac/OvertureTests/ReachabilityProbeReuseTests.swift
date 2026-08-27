import Testing
import Foundation
import SwiftData

// #1308 Layer 2 Phase 4: the cost-saver. The contact hunt is Prep's expensive half, so a show whose
// contact a probe already found should not be researched again. When such a KEPT show is prepped, the run
// skips the hunt (draft_only) and only drafts to the stored contact, so the research is paid once (at the
// probe). An explicit Dan re-prep still wins; a probe that found NO contact still needs the full hunt.
@MainActor
@Suite("Reachability probe Prep-reuse (#1308)")
struct ReachabilityProbeReuseTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @Test func probedWithContactSkipsTheHuntOnAFirstPrep() {
        // no reprep flags, no draft yet, probed and has a contact -> draft_only
        #expect(PrepQueueBuilder.prepMode(hasDraft: false, reprepDraftRequested: false,
                                          reprepContactsRequested: false, probedWithContact: true) == "draft_only")
    }

    @Test func aNeverProbedShowStillDoesTheFullPrep() {
        #expect(PrepQueueBuilder.prepMode(hasDraft: false, reprepDraftRequested: false,
                                          reprepContactsRequested: false, probedWithContact: false) == nil)
    }

    @Test func aProbeThatFoundNoContactStillNeedsTheHunt() {
        // probed but the probe found nothing to store, so there is still a contact to research
        #expect(PrepQueueBuilder.prepMode(hasDraft: false, reprepDraftRequested: false,
                                          reprepContactsRequested: false, probedWithContact: false) == nil)
    }

    @Test func anExplicitReprepStillWins() {
        #expect(PrepQueueBuilder.prepMode(hasDraft: true, reprepDraftRequested: false,
                                          reprepContactsRequested: true, probedWithContact: true) == "contacts_only")
        #expect(PrepQueueBuilder.prepMode(hasDraft: true, reprepDraftRequested: true,
                                          reprepContactsRequested: false, probedWithContact: true) == "draft_only")
    }

    // End to end through buildQueue: a kept, probed-with-contact show is queued draft_only.
    @Test func buildQueueMarksAProbedKeptShowDraftOnly() throws {
        let ctx = ModelContext(try container())
        let key = Prospect.makeNaturalKey(groupName: "Aurora Strings", performanceDate: "2026-09-12", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: "2026-09-12", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        p.reachabilityProbedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let r = Recipient(id: "jane@aurora.org", email: "jane@aurora.org", provenance: .act)
        p.recipients = [r]
        ctx.insert(p)
        try ctx.save()

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        let item = queue.items.first { $0.naturalKey == key }
        #expect(item?.reprepMode == "draft_only")
    }
}
