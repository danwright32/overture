import Testing
import Foundation
import SwiftData

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
                         sourceListingURL: nil, priorRelationship: "booked",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 27, tier: "high", fitReason: "r", matchedClientName: "Larkin Sable",
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        p.downbeatClientId = "client-larkin"
        p.relationshipCorrectedByPerformerMatch = true
        p.matchedPerformerName = "Larkin Sable"
        p.performerMatchNote = "Matched performer 'Larkin Sable' to Downbeat client Larkin Sable."
        p.performerMatchPreviousRelationship = "none"
        p.performerMatchPreviousFitScore = 7
        p.performerMatchPreviousTier = "high"
        p.performerMatchPreviousMatchedClientName = nil
        p.performerMatchPreviousDownbeatClientId = nil
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // #1648 Phase A3 (Dan's sign-off, 2026-07-28): a dismiss must RECOMPUTE the score, not put back
    // the integer that was snapshotted when the match was applied. The snapshot describes the row as
    // it was then, and anything that legitimately changed the score in between is thrown away by a
    // blind restore. Here Dan corrects the genre from music to dance while the match stands; dismissing
    // the match must keep that correction, not rewind to music's number.
    //
    // Accepted consequence: the score after a dismiss may differ from the number the row held before
    // the match was applied. That is the point.
    @Test func dismissingAMatchRecomputesAndKeepsACorrectionMadeInBetween() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)

        // Dan corrects the genre while the match stands: booked 20 + dance 3 + self 2 + strong 2
        // + uncovered 2 = 29.
        ClassificationOverride.correct(p, discipline: .dance, now: Date(timeIntervalSince1970: 2_000))
        #expect(p.fitScore == 29)

        p.dismissPerformerMatch()

        // The relationship rewinds to what the scout had.
        #expect(p.priorRelationship == "none")
        // The score is re-derived from the row as it now stands: dance 3 + self 2 + strong 2
        // + uncovered 2 = 9. Before Phase A3 this restored 7, the number music earned.
        #expect(p.fitScore == 9)
        #expect(p.tier == "high")
        // Dan's genre correction is untouched by the dismiss.
        #expect(p.discipline == "dance")
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
        #expect(p.matchedPerformerName == "Larkin Sable")
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
                       contacts: [PrepContact(name: "Larkin Sable", role: "Violinist",
                                              email: "larkin@sableviolin.example", method: "named_decision_maker",
                                              confidence: "high", formUrl: nil, provenance: "performer")],
                       draft: nil)
        ])
        let client = DownbeatClient(id: "client-larkin", displayName: "Larkin Sable", shortName: nil,
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
                         performanceDate: "2026-08-02", sourceListingURL: nil,
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
                         sourceListingURL: nil, priorRelationship: "booked",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 27, tier: "high", fitReason: "r", matchedClientName: "Aurora Strings",
                         possibleMatchSource: nil, possibleMatchName: nil, status: .queued)
        ctx.insert(p)
        try ctx.save()

        let queue = PrepQueueService.buildQueue(from: ctx, generatedAt: "now")
        let item = try #require(queue.items.first { $0.naturalKey == key })

        #expect(item.priorRelationship == "booked")
    }

    // MARK: - Saying whether the action actually did anything (#1419)

    // Both methods open with a guard and returned Void, so a caller could not tell a real change from
    // a no-op: ProspectMutations saved and carried on either way.
    //
    // Unreachable from the queue as the app stands, and deliberately still fixed. The flag only renders
    // while the correction is live (ProspectRowView.performerMatchFlag), and the one place that wipes a
    // live correction, ScoutService.apply, is synchronous on the main actor against the context the
    // queue's own @Query reads, so there is no moment at which Dan can click a flag whose match has
    // already gone. What is real today is the write that had nothing to write. What would be real
    // tomorrow is the undo stack (#1413): undoing a no-op here would forge a performer-match correction
    // that never existed, which is why the honest answer belongs on the model now, before anything is
    // built on top of it.

    @Test func dismissingALiveMatchSaysItChangedSomething() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)

        #expect(p.dismissPerformerMatch())
    }

    @Test func confirmingALiveMatchSaysItChangedSomething() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)

        #expect(p.confirmPerformerMatch())
    }

    // The guarded case: a show never corrected by a performer match. Already covered for its EFFECTS by
    // dismissingOrConfirmingAProspectWithNoMatchDoesNothing above; this pins what it REPORTS.
    @Test func aShowWithNoMatchSaysNothingChanged() throws {
        let ctx = ModelContext(try container())
        let key = Prospect.makeNaturalKey(groupName: "G", performanceDate: "2026-08-02", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-08-02", sourceListingURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 17, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)

        #expect(p.dismissPerformerMatch() == false)
        #expect(p.confirmPerformerMatch() == false)
    }

    // A second dismissal has nothing left to revert: the first released the lock, so the guard catches
    // it and the snapshot is not re-applied over values that already came from it.
    @Test func dismissingAnAlreadyDismissedMatchSaysNothingChanged() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)
        #expect(p.dismissPerformerMatch())

        #expect(p.dismissPerformerMatch() == false)
    }

    // And a second confirmation is the case the lock check alone does NOT catch: the correction is
    // still live, so that guard passes, but both fields already hold exactly what confirming sets.
    @Test func confirmingAnAlreadyConfirmedMatchSaysNothingChanged() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)
        #expect(p.confirmPerformerMatch())

        #expect(p.confirmPerformerMatch() == false)
        #expect(p.performerMatchReviewed)          // and it is still confirmed, not toggled back off
    }

    // MARK: - The mutation layer stops writing what it cannot change (#1419)

    @Test func actingOnALiveMatchReportsSuccessAndPersistsIt() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)
        let feedback = ActionFeedback()

        #expect(ProspectMutations.confirmPerformerMatch(QueueItem(p), prospects: [p],
                                                        context: ctx, feedback: feedback))

        #expect(p.performerMatchReviewed)
        #expect(feedback.message == nil)   // it has never claimed anything on success, and still does not
    }

    // The failure path: nothing to do, so nothing is written and the caller is told so. Before this the
    // caller got the same silent Void it got for a real change, and the save ran regardless, which meant
    // a failed save could warn Dan about an action that was never attempted.
    @Test func actingOnAMatchThatIsNoLongerThereReportsNoChange() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)
        p.clearPerformerMatch()            // a confident org match superseded it (ScoutService.apply)
        try ctx.save()
        let feedback = ActionFeedback()

        #expect(ProspectMutations.confirmPerformerMatch(QueueItem(p), prospects: [p],
                                                        context: ctx, feedback: feedback) == false)
        #expect(ProspectMutations.dismissPerformerMatch(QueueItem(p), prospects: [p],
                                                        context: ctx, feedback: feedback) == false)

        #expect(p.performerMatchReviewed == false)
        #expect(p.performerMatchDismissed == false)
        #expect(feedback.message == nil)   // and it does not warn about a save it never attempted
    }

    // A show that is not in the array at all cannot be acted on either, and must say so rather than
    // report the success of a mutation that never found its target.
    @Test func actingOnAShowThatIsNotInTheListReportsNoChange() throws {
        let ctx = ModelContext(try container())
        let p = correctedProspect(ctx)
        let feedback = ActionFeedback()

        #expect(ProspectMutations.confirmPerformerMatch(QueueItem(p), prospects: [],
                                                        context: ctx, feedback: feedback) == false)
        #expect(ProspectMutations.dismissPerformerMatch(QueueItem(p), prospects: [],
                                                        context: ctx, feedback: feedback) == false)
    }
}
