import Testing
import Foundation
import SwiftData

// #789: the send gate for the draft lint. Every safeguard before this one sits UPSTREAM of the
// words (the ranker, the queue, the salutation strip, the contact guards); this is the first that
// reads the words themselves, which are the part that actually reaches a stranger and are written
// by an AI. A blocking finding drops the recipient out of `isSendablePending`, the single predicate
// every send path funnels through (SendService.nextPendingRecipient), so it stops the queue and the
// manual Send button alike, not just the UI.
@Suite("Draft lint send gate")
struct DraftLintSendGateTests {
    @MainActor
    private func makeProspect(_ ctx: ModelContext, body: String?) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "cold", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.draftSubject = "Photographs of your concert"
        p.draftBody = body
        ctx.insert(p)
        return p
    }

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let clean = "I photograph performing arts in New York. Recent work is at danwrightphotography.com."
    private let foreign = "I photograph performing arts. Recent work is at https://smugmug.com/dan."

    @MainActor
    @Test func aCleanDraftLeavesEveryRecipientSendable() throws {
        let ctx = try context()
        let p = makeProspect(ctx, body: clean)
        let act = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        p.setRecipients([act])
        #expect(act.isSendablePending)
    }

    @MainActor
    @Test func aBlockingFindingBlocksEveryRecipientOnThatPerformance() throws {
        let ctx = try context()
        let p = makeProspect(ctx, body: foreign)
        let act = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        let presenter = Recipient(id: "b@present.example", email: "b@present.example", provenance: .presenter)
        p.setRecipients([act, presenter])
        #expect(!act.isSendablePending)
        #expect(!presenter.isSendablePending)
        #expect(act.draftLintBlockers == [.foreignLink])
    }

    // Dan's #789 call, and a deliberate DEPARTURE from the advisory DraftCheck warnings (which hide
    // once `draftEditedByDan`): a dead link or a leftover placeholder is a fact about the words
    // reaching a stranger no matter who typed them, so his own edit is blocked too.
    @MainActor
    @Test func danOwnEditedDraftIsBlockedToo() throws {
        let ctx = try context()
        let p = makeProspect(ctx, body: foreign)
        p.draftEditedByDan = true
        let act = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        p.setRecipients([act])
        #expect(!act.isSendablePending)
    }

    // Mirrors #718's salutation override: the override stores the EXACT text approved, so a later
    // edit to different text silently invalidates it with no migration bookkeeping.
    @MainActor
    @Test func anOverrideUnblocksOnlyTheExactApprovedText() throws {
        let ctx = try context()
        let p = makeProspect(ctx, body: foreign)
        let act = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        p.setRecipients([act])
        #expect(!act.isSendablePending)

        act.lintOverriddenBody = act.effectiveBody
        #expect(act.isSendablePending)

        p.draftBody = "Now see https://pixieset.com/dan instead."   // edited again after overriding
        #expect(!act.isSendablePending)                             // stale override no longer applies
    }

    // The hole a lint that only read `draftBody` would leave: SendService sends a PERFORMER their own
    // `overrideBody` when one exists, so that text (AI-written too) is what reaches them. The block is
    // per recipient, over the text THAT recipient would actually receive, so a bad override body stops
    // the performer without stopping the presenter who receives the clean shared body.
    @MainActor
    @Test func aPerformerOverrideBodyIsLintedInsteadOfTheSharedBody() throws {
        let ctx = try context()
        let p = makeProspect(ctx, body: clean)
        let performer = Recipient(id: "p@perf.example", email: "p@perf.example", provenance: .performer)
        performer.overrideBody = "Hi [NAME], I photograph performing arts."
        let presenter = Recipient(id: "b@present.example", email: "b@present.example", provenance: .presenter)
        p.setRecipients([performer, presenter])

        #expect(performer.effectiveBody == performer.overrideBody)
        #expect(!performer.isSendablePending)
        #expect(performer.draftLintBlockers == [.placeholder])

        #expect(presenter.effectiveBody == clean)
        #expect(presenter.isSendablePending)
    }

    // An overrideBody only applies to a .performer (#640). A non-performer carrying stale override
    // text must be linted on the SHARED body, exactly as SendService will send it.
    @MainActor
    @Test func aNonPerformerOverrideBodyIsIgnoredByTheLintJustAsItIsBySendService() throws {
        let ctx = try context()
        let p = makeProspect(ctx, body: clean)
        let presenter = Recipient(id: "b@present.example", email: "b@present.example", provenance: .presenter)
        presenter.overrideBody = "Hi [NAME], stale text nobody will ever receive."
        p.setRecipients([presenter])

        #expect(presenter.effectiveBody == clean)
        #expect(presenter.isSendablePending)
    }

    // A bare Recipient with no prospect wired (the pattern most tests in RecipientTests use) has no
    // text to lint and must stay governed by its own state alone, never blocked by a body it can't see.
    @Test func aRecipientWithNoProspectIsUnaffected() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.prospect == nil)
        #expect(r.effectiveBody == nil)
        #expect(r.draftLintBlockers.isEmpty)
        #expect(r.isSendablePending)
    }

    // The gate is the one predicate every send path reads, so a blocked recipient must be invisible
    // to the sender itself, not merely greyed out in the UI.
    @MainActor
    @Test func aBlockedRecipientIsNeverOfferedToTheSender() throws {
        let ctx = try context()
        let p = makeProspect(ctx, body: foreign)
        p.status = .approved
        let act = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        p.setRecipients([act])

        #expect(SendService.nextPendingRecipient(for: p) == nil)

        act.lintOverriddenBody = act.effectiveBody
        #expect(SendService.nextPendingRecipient(for: p) === act)
    }
}
