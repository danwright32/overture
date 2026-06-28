import Testing
import Foundation
import SwiftData
@testable import Overture

// Phase 1 (#391): the one-time, idempotent backfill that synthesizes recipients[0] from the legacy
// singular contact/send fields so every existing performance carries the new model. One synth helper
// is shared with DebugStaging (consolidation), so the per-field mapping is tested here once.
@Suite("Recipient backfill")
struct RecipientBackfillTests {
    private func makeProspect(contactEmail: String? = "ann@example.com") -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: nil,
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "neutral",
                         coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.contactEmail = contactEmail
        return p
    }

    private func makeInMemoryContext() throws -> ModelContext {
        let container = try ModelContainer(for: Schema([Prospect.self]),
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        return ModelContext(container)
    }

    @Test func synthesizesActRecipientFromLegacyContactFields() {
        let p = makeProspect(contactEmail: "Ann@Example.com ")
        p.contactName = "Ann Lee"
        p.contactRole = "manager"
        p.contactMethodRaw = "email"
        p.contactConfidenceRaw = "confident"
        p.contactFormURL = "https://example.com/contact"

        let r = RecipientBackfill.synthesizedRecipient(from: p)

        #expect(r?.email == "Ann@Example.com ")
        // id is the canonicalized email (lowercased, trimmed) — the stable join/dedupe key.
        #expect(r?.id == "ann@example.com")
        #expect(r?.name == "Ann Lee")
        #expect(r?.role == "manager")
        #expect(r?.provenance == .act)
        #expect(r?.contactMethodRaw == "email")
        #expect(r?.contactConfidenceRaw == "confident")
        #expect(r?.contactFormURL == "https://example.com/contact")
    }

    @Test func sendStateIsSentWhenAlreadySent() {
        let p = makeProspect()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        p.sentAt = when
        p.gmailThreadId = "t1"
        p.gmailMessageId = "m1"
        p.sendError = "prior error"
        p.followUpCount = 2
        p.lastFollowUpAt = when

        let r = RecipientBackfill.synthesizedRecipient(from: p)

        #expect(r?.sendState == .sent)
        #expect(r?.sentAt == when)
        #expect(r?.gmailThreadId == "t1")
        #expect(r?.gmailMessageId == "m1")
        #expect(r?.sendError == "prior error")
        #expect(r?.followUpCount == 2)
        #expect(r?.lastFollowUpAt == when)
    }

    @Test func sendStateIsPendingWhenNeverSent() {
        let p = makeProspect()
        p.sentAt = nil

        #expect(RecipientBackfill.synthesizedRecipient(from: p)?.sendState == .pending)
    }

    @Test func mirrorsLeadReplyStateSoARepliedRecipientIsNotSilent() {
        let p = makeProspect()
        let sent = Date(timeIntervalSince1970: 1_700_000_000)
        let replyAt = Date(timeIntervalSince1970: 1_700_100_000)
        p.sentAt = sent
        p.outcome = .replied
        p.lastReplyAt = replyAt
        p.lastReplyText = "Sounds great"
        p.lastReplyId = "r9"
        p.dismissedReplyId = "r0"

        let r = RecipientBackfill.synthesizedRecipient(from: p)

        #expect(r?.replied == true)
        #expect(r?.repliedAt == replyAt)
        #expect(r?.lastReplyText == "Sounds great")
        #expect(r?.lastReplyId == "r9")
        #expect(r?.dismissedReplyId == "r0")
        #expect(r?.isSilent == false)
    }

    @Test func noRecipientWhenThereIsNoContactEmail() {
        let p = makeProspect(contactEmail: nil)
        #expect(RecipientBackfill.synthesizedRecipient(from: p) == nil)
    }

    @Test func runSeedsEveryContactedProspectExactlyOnce() throws {
        let ctx = try makeInMemoryContext()
        let withEmail = makeProspect(contactEmail: "ann@example.com")
        let scoutOnly = makeProspect(contactEmail: nil)
        scoutOnly.naturalKey = "k2"
        ctx.insert(withEmail)
        ctx.insert(scoutOnly)

        let seeded = RecipientBackfill.run(in: ctx)

        #expect(seeded == 1)
        #expect(withEmail.recipients.count == 1)
        #expect(withEmail.recipients.first?.provenance == .act)
        #expect(scoutOnly.recipients.isEmpty)
    }

    // Phase 1 keeps the lead-level sentAt rollup as the source of truth for the ~14 "was this
    // contacted at all" readers; the backfill only ADDS recipients alongside, it must never touch it.
    @Test func backfillNeverMutatesTheLeadSentAtRollup() throws {
        let ctx = try makeInMemoryContext()
        let sent = makeProspect(contactEmail: "ann@example.com")
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        sent.sentAt = when
        let unsent = makeProspect(contactEmail: "bo@example.com")
        unsent.naturalKey = "k2"
        unsent.sentAt = nil
        ctx.insert(sent)
        ctx.insert(unsent)

        _ = RecipientBackfill.run(in: ctx)

        #expect(sent.sentAt == when)
        #expect(unsent.sentAt == nil)
    }

    @Test func runIsIdempotentAndNeverClobbersExistingRecipients() throws {
        let ctx = try makeInMemoryContext()
        let p = makeProspect(contactEmail: "ann@example.com")
        ctx.insert(p)

        _ = RecipientBackfill.run(in: ctx)
        // Simulate later per-recipient state (e.g. a manual edit) that the second run must not erase.
        p.updateRecipient(id: "ann@example.com") { $0.bounced = true }

        let seededSecondTime = RecipientBackfill.run(in: ctx)

        #expect(seededSecondTime == 0)
        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.bounced == true)
    }
}
