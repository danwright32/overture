import Testing
import Foundation
import SwiftData
@testable import Overture

// Ingesting the classify workflow's results (#185): match each by naturalKey and SUGGEST the
// conversation state (auto), never overwriting a state Dan set by hand (#60). Mirrors PrepImporter.
@MainActor
@Suite("Reply classify importer")
struct ReplyClassifyImporterTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func lead(_ ctx: ModelContext, key: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = .replied
        ctx.insert(p); try? ctx.save()
        return p
    }

    private func results(_ pairs: [(String, String)]) -> ReplyClassifyResults {
        ReplyClassifyResults(version: 1, generatedAt: "2026-06-26T00:00:00.000Z",
                             results: pairs.map { ReplyClassifyResult(naturalKey: $0.0, intent: $0.1) })
    }

    // #653: the suggestion is per-recipient now, keyed off each reply's own recipientId. A v1/v2
    // result with no recipientId has no per-contact target, so it gets no suggestion at all.
    @Test func suggestsTheStateForAMatchedRecipient() throws {
        let ctx = ModelContext(try container())
        let p = lead(ctx, key: "k1")
        let r = Recipient(id: "a@e.com", email: "a@e.com", provenance: .act)
        r.sendState = .sent; r.replied = true
        p.setRecipients([r]); try ctx.save()

        let res = ReplyClassifyResults(version: 3, generatedAt: "x", results: [
            ReplyClassifyResult(naturalKey: "k1", intent: "wants_to_book", recipientId: "a@e.com"),
        ])
        let out = ReplyClassifyImporter.ingest(res, into: ctx)
        let ra = p.recipients.first { $0.id == "a@e.com" }
        #expect(ra?.conversationState == .wantsToBook)
        #expect(ra?.conversationStateSource == .auto)
        #expect(out.suggested == 1)
        #expect(out.matched == 1)
    }

    @Test func neverOverwritesARecipientsManualState() throws {
        let ctx = ModelContext(try container())
        let p = lead(ctx, key: "k2")
        let r = Recipient(id: "a@e.com", email: "a@e.com", provenance: .act)
        r.sendState = .sent; r.replied = true
        r.conversationState = .interested
        r.conversationStateSource = .manual
        p.setRecipients([r]); try ctx.save()

        let res = ReplyClassifyResults(version: 3, generatedAt: "x", results: [
            ReplyClassifyResult(naturalKey: "k2", intent: "declined", recipientId: "a@e.com"),
        ])
        let out = ReplyClassifyImporter.ingest(res, into: ctx)
        let ra = p.recipients.first { $0.id == "a@e.com" }
        #expect(ra?.conversationState == .interested)   // Dan's hand-set state untouched (#60)
        #expect(out.skippedManual == 1)
    }

    @Test func surfacesUnmatchedKeys() throws {
        let ctx = ModelContext(try container())
        lead(ctx, key: "k3")
        let out = ReplyClassifyImporter.ingest(results([("nope", "interested")]), into: ctx)
        #expect(out.unmatchedKeys == ["nope"])
        #expect(out.suggested == 0)
    }

    // #420 C3/C4, #653: v3, two contacts on one show route their OWN intent hint + AI draft AND their
    // OWN conversation-state suggestion to their own recipient row (the old "prefer active over
    // decline" lead-level compromise is gone entirely: each contact suggests off its own reply). The
    // per-contact hints/suggestions are NON-BINDING (no RecipientResolution is set by the importer).
    @Test func v3RoutesPerContactDraftHintAndConversationStateIndependently() throws {
        let ctx = ModelContext(try container())
        let p = lead(ctx, key: "show")
        let act = Recipient(id: "act@a.example", email: "act@a.example", provenance: .act)
        act.sendState = .sent; act.replied = true
        let pres = Recipient(id: "pres@p.example", email: "pres@p.example", provenance: .presenter)
        pres.sendState = .sent; pres.replied = true
        p.setRecipients([act, pres])
        try ctx.save()

        let res = ReplyClassifyResults(version: 3, generatedAt: "x", results: [
            ReplyClassifyResult(naturalKey: "show", intent: "declined", recipientId: "act@a.example",
                                draftSubject: "Re: A", draftBody: "Thanks for letting me know."),
            ReplyClassifyResult(naturalKey: "show", intent: "wants_to_book", recipientId: "pres@p.example",
                                draftSubject: "Re: P", draftBody: "Wonderful, I'd be glad to."),
        ])
        let out = ReplyClassifyImporter.ingest(res, into: ctx)

        #expect(out.matched == 2)
        #expect(out.suggested == 2)
        let ra = p.recipients.first { $0.id == "act@a.example" }
        let rp = p.recipients.first { $0.id == "pres@p.example" }
        #expect(ra?.intentHint == "declined")
        #expect(ra?.replyDraftBody == "Thanks for letting me know.")
        #expect(rp?.intentHint == "wants_to_book")
        #expect(rp?.replyDraftBody == "Wonderful, I'd be glad to.")
        #expect(ra?.conversationState == .declined)         // its OWN reply, not averaged with pres's
        #expect(rp?.conversationState == .wantsToBook)
        #expect(ra?.resolution == nil && rp?.resolution == nil)   // hints are non-binding (decision f)
    }

    // #462 — a fresh AI draft must NOT clobber a reply Dan hand-edited. His unsent text wins until he
    // sends or dismisses it, mirroring the cold path (PrepImporter draftEditedByDan). The AI's intent
    // read still refreshes (a non-binding hint, separate from his draft text). #459 stopped the warnings
    // nagging his edit; this protects the text itself.
    @Test func aFreshAIDraftDoesNotClobberDansEditedReply() throws {
        let ctx = ModelContext(try container())
        let p = lead(ctx, key: "show")
        let act = Recipient(id: "act@a.example", email: "act@a.example", provenance: .act)
        act.sendState = .sent; act.replied = true
        act.intentHint = "declined"
        act.applyReplyDraftEdit("Dan's hand-edited reply.")   // edited; protected
        p.setRecipients([act])
        try ctx.save()

        let res = ReplyClassifyResults(version: 3, generatedAt: "x", results: [
            ReplyClassifyResult(naturalKey: "show", intent: "interested", recipientId: "act@a.example",
                                draftSubject: "Re: A", draftBody: "A new AI draft."),
        ])
        let out = ReplyClassifyImporter.ingest(res, into: ctx)

        let ra = p.recipients.first { $0.id == "act@a.example" }
        #expect(ra?.replyDraftBody == "Dan's hand-edited reply.")   // his text survives
        #expect(ra?.replyDraftEditedByDan == true)                  // flag stays set
        #expect(ra?.intentHint == "interested")                     // hint still refreshes
        #expect(out.skippedEdited == 1)
    }

    // #462 — the freeze guards on actual edited TEXT, not the marker alone: once Dan has sent his reply
    // in Gmail (draft cleared, marker still set), a genuinely new reply must still get a fresh draft.
    @Test func aClearedEditedDraftStillTakesAFreshDraft() throws {
        let ctx = ModelContext(try container())
        let p = lead(ctx, key: "show")
        let act = Recipient(id: "act@a.example", email: "act@a.example", provenance: .act)
        act.sendState = .sent; act.replied = true
        act.applyReplyDraftEdit("An earlier reply Dan sent.")
        act.replyDraftBody = nil   // he sent it in Gmail; text gone, marker still set
        p.setRecipients([act])
        try ctx.save()

        let res = ReplyClassifyResults(version: 3, generatedAt: "x", results: [
            ReplyClassifyResult(naturalKey: "show", intent: "interested", recipientId: "act@a.example",
                                draftSubject: "Re: A", draftBody: "A fresh draft for the new reply."),
        ])
        let out = ReplyClassifyImporter.ingest(res, into: ctx)

        let ra = p.recipients.first { $0.id == "act@a.example" }
        #expect(ra?.replyDraftBody == "A fresh draft for the new reply.")
        #expect(ra?.replyDraftEditedByDan == false)   // stale marker reset; the fresh draft isn't protected
        #expect(out.skippedEdited == 0)
    }

    // #617: a real save() failure (not just the source-scan guard in ImporterSaveGuardTests), via
    // ImmutableStoreFixture. #653: needs a real recipient to mutate -- with none, ingest touches
    // nothing and a genuinely empty save can trivially succeed even against a read-only store.
    @Test func ingestReportsSaveFailedOnAGenuineSaveFailure() async throws {
        let outcome = try await ImmutableStoreFixture.withFailingSave(
            schema: Schema([Prospect.self, Recipient.self]),
            seed: { ctx in
                let p = self.lead(ctx, key: "k1")
                let r = Recipient(id: "a@e.com", email: "a@e.com", provenance: .act)
                r.sendState = .sent; r.replied = true
                p.setRecipients([r])
            },
            body: { ctx in
                ReplyClassifyImporter.ingest(ReplyClassifyResults(version: 3, generatedAt: "x", results: [
                    ReplyClassifyResult(naturalKey: "k1", intent: "wants_to_book", recipientId: "a@e.com"),
                ]), into: ctx)
            })

        #expect(outcome.matched == 1)
        #expect(outcome.saveFailed)
    }
}
