import Testing
import Foundation
import SwiftData
@testable import Overture

// Dismiss/revert and the drafting-tone reviewed-gate (#752, plan #748, issue #585).
//
// The correction is STICKY by design (Phase 2), which is what makes this phase necessary: it
// survives into a later Prep cycle's redraft, so without a gate a match Dan never agreed with could
// put a warm, familiar tone into an email that actually gets sent. And because it is sticky, a wrong
// one has to be genuinely revertible, not just visually dismissed.
@MainActor
@Suite("Performer match: dismiss, confirm, and the drafting-tone gate")
struct PerformerMatchDismissTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A prospect the scout scored cold (none, 7), that Prep then corrected to booked (27) off a
    // performer match, snapshotting the cold values on the way.
    private func correctedProspect(_ ctx: ModelContext) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "Emerging Artists Series",
                                          performanceDate: "2026-08-02", venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: "Emerging Artists Series", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-08-02",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "booked",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 27, tier: "high", fitReason: "r", matchedClientName: "Marisol Vega",
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        p.downbeatClientId = "client-marisol"
        p.relationshipCorrectedByPerformerMatch = true
        p.matchedPerformerName = "Marisol Vega"
        p.performerMatchNote = "Matched performer 'Marisol Vega' to Downbeat client Marisol Vega."
        p.performerMatchPreviousRelationship = "none"
        p.performerMatchPreviousFitScore = 7
        p.performerMatchPreviousTier = "high"
        p.performerMatchPreviousMatchedClientName = nil
        p.performerMatchPreviousDownbeatClientId = nil
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    @Test func dismissingAWrongMatchRestoresExactlyWhatTheScoutHad() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)

        p.dismissPerformerMatch()

        #expect(p.priorRelationship == "none")
        #expect(p.fitScore == 7)
        #expect(p.matchedClientName == nil)
        #expect(p.downbeatClientId == nil)
        #expect(p.performerMatchDismissed)
        // Phase 2's guard must stop protecting a correction Dan has rejected, so ordinary org-name
        // matching resumes on the next scout run.
        #expect(!p.relationshipCorrectedByPerformerMatch)
        #expect(!p.hasActivePerformerMatch)
        // The FINDING itself survives the dismissal on purpose: it is the record that stops the same
        // rejected match being re-applied on the next ingest of the same evidence (see below).
        #expect(p.matchedPerformerName == "Marisol Vega")
    }

    // The bug this catches is subtle and would have been live: PrepImporter's "don't run twice" check
    // originally keyed off relationshipCorrectedByPerformerMatch, and dismissing CLEARS that flag. So
    // re-ingesting the very same prep-results file would have resurrected a match Dan had just
    // rejected, with the score jumping back to warm. Keyed off the recorded performer name instead
    // (the alreadyCoveredNote pattern, #611), the dismissal sticks.
    @Test func aDismissedMatchIsNotResurrectedByReIngestingTheSameEvidence() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)
        p.dismissPerformerMatch()
        try ctx.save()

        let results = PrepResults(version: 3, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey,
                       contacts: [PrepContact(name: "Marisol Vega", role: "Violinist",
                                              email: "marisol@vegaviolin.com", method: "named_decision_maker",
                                              confidence: "high", formUrl: nil, provenance: "performer")],
                       draft: nil)
        ])
        let client = DownbeatClient(id: "client-marisol", displayName: "Marisol Vega", shortName: nil,
                                    email: "", contractEmail: "", phoneNumber: nil, isTaxExempt: nil,
                                    hasLeftReview: false, specialBehaviors: [], notes: nil, hostingSite: "")

        _ = PrepImporter.ingest(results, into: ctx, clients: [client], history: [])

        #expect(p.priorRelationship == "none")
        #expect(p.fitScore == 7)
        #expect(p.performerMatchDismissed)
        #expect(!p.relationshipCorrectedByPerformerMatch)
    }

    @Test func confirmingAMatchMarksItReviewed() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)
        #expect(!p.performerMatchReviewed)

        p.confirmPerformerMatch()

        #expect(p.performerMatchReviewed)
        #expect(!p.performerMatchDismissed)
        #expect(p.relationshipCorrectedByPerformerMatch)   // still corrected, now agreed with
        #expect(p.fitScore == 27)                          // confirming changes nothing about the score
    }

    @Test func dismissingOrConfirmingAProspectWithNoMatchDoesNothing() throws {
        let ctx = ModelContext(try container())
        let key = Prospect.makeNaturalKey(groupName: "G", performanceDate: "2026-08-02", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-08-02", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 17, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)

        p.dismissPerformerMatch()
        p.confirmPerformerMatch()

        #expect(p.priorRelationship == "warm")   // NOT reverted to a snapshot that was never taken
        #expect(p.fitScore == 17)
        #expect(!p.performerMatchDismissed)
        #expect(!p.performerMatchReviewed)
    }

    // MARK: - The drafting-tone gate

    // The leak this closes: the correction survives to a LATER Prep cycle (a redraft, #367), and that
    // run reads priorRelationship to pick its tone. An unconfirmed guess must never make an email
    // SOUND like it is going to a returning client. It may still change how the lead is RANKED, which
    // is what makes the feature useful while Dan has not looked yet.
    @Test func anUnreviewedCorrectionIsHiddenFromTheDrafter() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)
        try ctx.save()

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        let item = try #require(queue.items.first { $0.naturalKey == p.naturalKey })

        // The drafter sees the COLD value the scout originally had, not the unconfirmed correction.
        #expect(item.priorRelationship == "none")
        // While the app itself still holds the corrected value, so the lead is ranked warm.
        #expect(p.priorRelationship == "booked")
    }

    @Test func aConfirmedCorrectionReachesTheDrafter() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)
        p.confirmPerformerMatch()
        try ctx.save()

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        let item = try #require(queue.items.first { $0.naturalKey == p.naturalKey })

        #expect(item.priorRelationship == "booked")
    }

    @Test func aDismissedCorrectionLeavesTheDrafterWithTheColdValue() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)
        p.dismissPerformerMatch()
        try ctx.save()

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        let item = try #require(queue.items.first { $0.naturalKey == p.naturalKey })

        #expect(item.priorRelationship == "none")
    }

    // A prospect with no performer match at all must reach the drafter completely unchanged: the gate
    // may not quietly cool the tone of an ordinary warm lead the scout matched on the org name.
    @Test func anOrdinaryWarmLeadIsUnaffectedByTheGate() throws {
        let ctx = ModelContext(try container())
        let key = Prospect.makeNaturalKey(groupName: "Aurora Strings", performanceDate: "2026-08-05",
                                          venue: "Weill Recital Hall")
        let p = Prospect(naturalKey: key, groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-08-05",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "booked",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 27, tier: "high", fitReason: "r", matchedClientName: "Aurora Strings",
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try ctx.save()

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        let item = try #require(queue.items.first { $0.naturalKey == key })

        #expect(item.priorRelationship == "booked")
    }
}
