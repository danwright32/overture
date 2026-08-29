import Testing
import Foundation
import SwiftData

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
                         performanceDate: "2026-09-01", sourceListingURL: nil,
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



    @Test func surfacesUnmatchedKeys() throws {
        let ctx = ModelContext(try container())
        lead(ctx, key: "k3")
        let out = ReplyClassifyImporter.ingest(results([("nope", "interested")]), into: ctx)
        #expect(out.unmatchedKeys == ["nope"])
        #expect(out.suggested == 0)
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
        // #2131: written with nothing to edit records as his own, and is protected just the same.
        #expect(ra?.replyDraftWrittenByDan == true)                  // flag stays set
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
