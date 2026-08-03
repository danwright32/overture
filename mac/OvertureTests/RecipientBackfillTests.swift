import Testing
import Foundation
import SwiftData

// #418 A1 / #416: the one-time, idempotent repair that copies a legacy lead-level send's thread down
// to its act recipient, so per-recipient reply detection has a thread to watch.
@Suite("Recipient backfill")
struct RecipientBackfillTests {
    private func makeInMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    // A contacted-via-the-old-path show: lead carries sentAt/thread, its act recipient row does not.
    private func legacyContacted(_ ctx: ModelContext, key: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: nil,
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.sentAt = Date(timeIntervalSince1970: 1_700_000_000)
        p.gmailThreadId = "lead-thread-" + key
        p.gmailMessageId = "lead-msg-" + key
        ctx.insert(p)
        return p
    }

    private func act(_ id: String) -> Recipient {
        Recipient(id: id, email: id, provenance: .act)   // pending, no thread
    }

    @Test func repairCopiesTheLeadThreadDownToALegacyActRecipientAndMarksItSent() throws {
        let ctx = try makeInMemoryContext()
        let p = legacyContacted(ctx, key: "Old Show")
        p.setRecipients([act("a@act.example")])

        let n = RecipientBackfill.repairThreadDown(in: ctx)

        #expect(n == 1)
        let r = p.recipients.first
        #expect(r?.gmailThreadId == "lead-thread-Old Show")
        #expect(r?.gmailMessageId == "lead-msg-Old Show")
        #expect(r?.sentAt == p.sentAt)
        #expect(r?.sendState == .sent)   // both detection and isSilent require .sent
    }

    @Test func repairIsIdempotent() throws {
        let ctx = try makeInMemoryContext()
        let p = legacyContacted(ctx, key: "Old Show")
        p.setRecipients([act("a@act.example")])

        #expect(RecipientBackfill.repairThreadDown(in: ctx) == 1)
        #expect(RecipientBackfill.repairThreadDown(in: ctx) == 0)   // second run is a no-op
    }

    // A #415-era show already stamped a per-recipient thread; its genuinely-pending recipient must NOT
    // be given the lead thread (that thread belongs to the first contact, not this un-sent one).
    @Test func repairSkipsAShowWhereAnyRecipientAlreadyHasAThread() throws {
        let ctx = try makeInMemoryContext()
        let p = legacyContacted(ctx, key: "Partial Show")
        let sent = act("a@act.example"); sent.gmailThreadId = "r1-thread"; sent.sendState = .sent
        let stillPending = Recipient(id: "b@present.example", email: "b@present.example", provenance: .presenter)
        p.setRecipients([sent, stillPending])

        #expect(RecipientBackfill.repairThreadDown(in: ctx) == 0)
        #expect(p.recipients.first { $0.id == "b@present.example" }?.gmailThreadId == nil)
        #expect(p.recipients.first { $0.id == "b@present.example" }?.sendState == .pending)
    }

    // A never-contacted show (no lead thread) is left entirely alone.
    @Test func repairLeavesNeverContactedShowsAlone() throws {
        let ctx = try makeInMemoryContext()
        let p = Prospect(naturalKey: "Unsent", groupName: "Unsent", discipline: "music", venue: nil,
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        p.setRecipients([act("a@act.example")])

        #expect(RecipientBackfill.repairThreadDown(in: ctx) == 0)
        #expect(p.recipients.first?.gmailThreadId == nil)
        #expect(p.recipients.first?.sendState == .pending)
    }

    // On a legacy show, a manually-added presenter that was never sent stays pending (only .act repairs).
    @Test func repairDoesNotTouchANeverSentPresenter() throws {
        let ctx = try makeInMemoryContext()
        let p = legacyContacted(ctx, key: "Mixed Show")
        let presenter = Recipient(id: "p@present.example", email: "p@present.example", provenance: .presenter)
        p.setRecipients([act("a@act.example"), presenter])

        #expect(RecipientBackfill.repairThreadDown(in: ctx) == 1)
        #expect(p.recipients.first { $0.provenance == .act }?.sendState == .sent)
        #expect(p.recipients.first { $0.provenance == .presenter }?.sendState == .pending)
    }
}
