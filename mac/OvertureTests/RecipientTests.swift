import Testing
import Foundation
import SwiftData
@testable import Overture

// One party emailed for a performance. Multiple per performance, each with its own send state and
// engagement. The behaviors that matter to the rest of the system: who is "silent" (the only ones
// that get follow-ups), the provenance/send-state mapping, and a clean Codable round-trip (it is
// stored as a JSON blob on Prospect).
@Suite("Recipient")
struct RecipientTests {
    private func sent(replied: Bool = false, bounced: Bool = false) -> Recipient {
        var r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.sendState = .sent
        r.replied = replied
        r.bounced = bounced
        return r
    }

    @Test func aSentUnansweredRecipientIsSilent() {
        #expect(sent().isSilent)
    }

    @Test func aPendingRecipientIsNotSilent() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.sendState == .pending)
        #expect(!r.isSilent)
    }

    @Test func aRepliedRecipientIsNotSilent() {
        #expect(!sent(replied: true).isSilent)
    }

    @Test func aBouncedRecipientIsNotSilent() {
        #expect(!sent(bounced: true).isSilent)
    }

    @Test func firstNameUsesTheSharedSalutationHelper() {
        var r = Recipient(id: "x", email: "x@act.example", provenance: .act)
        r.name = "Anna Pierre"
        #expect(r.firstName == "Anna")
    }

    @Test func provenanceAndSendStateRoundTripThroughRawStrings() {
        var r = Recipient(id: "p@present.example", email: "p@present.example", provenance: .presenter)
        r.sendState = .suppressed
        #expect(r.provenance == .presenter)
        #expect(r.provenanceRaw == "presenter")
        #expect(r.sendState == .suppressed)
        #expect(r.sendStateRaw == "suppressed")
    }

    // Recipient is now a SwiftData @Model (#409): state persists through the store, not a JSON blob.
    @Test func persistsThroughTheStore() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .manual)
        r.name = "Virgile Roche"
        r.sendState = .sent
        r.replied = true
        r.gmailThreadId = "t1"
        ctx.insert(r)
        try ctx.save()

        let back = try ctx.fetch(FetchDescriptor<Recipient>()).first
        #expect(back?.name == "Virgile Roche")
        #expect(back?.sendState == .sent)
        #expect(back?.replied == true)
        #expect(back?.gmailThreadId == "t1")
        #expect(back?.provenance == .manual)
    }

    // A form-only contact (#368, the Ivalas Quartet case) has no published email, only a contact
    // form. It still becomes a recipient so it shows in the list and can be tracked; its id is the
    // form URL (not an email), so the SAME recipient is kept when Dan fills in an email later.
    @Test func aFormOnlyRecipientHasNoEmailAndAStableFormId() {
        let id = Recipient.makeId(email: nil, formURL: "https://www.ivalasquartet.com/contact")
        let r = Recipient(id: id!, email: nil, provenance: .act,
                          contactFormURL: "https://www.ivalasquartet.com/contact")
        #expect(r.email == nil)
        #expect(r.id == "form:https://www.ivalasquartet.com/contact")
    }

    // The id is the canonicalized email when there is one, the form URL otherwise, and nil when
    // there is neither (nothing to make a recipient from).
    @Test func makeIdPrefersTheCanonicalizedEmailThenTheForm() {
        #expect(Recipient.makeId(email: "Erobinson@Aurora.Example", formURL: "x") == "erobinson@aurora.example")
        #expect(Recipient.makeId(email: nil, formURL: "https://act.example/contact") == "form:https://act.example/contact")
        #expect(Recipient.makeId(email: "", formURL: "https://act.example/contact") == "form:https://act.example/contact")
        #expect(Recipient.makeId(email: nil, formURL: nil) == nil)
    }

    // A1b (#418): a per-recipient manual-outcome source, mirroring Prospect.outcomeSourceRaw, so
    // detection can tell "Dan judged this contact by hand" from "auto". nil = no manual mark.
    @Test func outcomeSourceMapsThroughRawString() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.outcomeSource == nil)
        #expect(r.outcomeSourceRaw == nil)
        r.outcomeSource = .manual
        #expect(r.outcomeSourceRaw == "manual")
        r.outcomeSourceRaw = "auto"
        #expect(r.outcomeSource == .auto)
    }

    // C0 (#420): the AI inbound-reply drafter writes a per-recipient draft + a non-binding intent hint;
    // replyDraftRequestedAt drives the request-response progress + needs-attention timeout. All additive.
    @Test func replyDraftFieldsRoundTripAndDefaultEmpty() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.replyDraftSubject == nil)
        #expect(r.replyDraftBody == nil)
        #expect(r.replyDraftRequestedAt == nil)
        #expect(r.intentHint == nil)

        let when = Date(timeIntervalSince1970: 1_700_000_000)
        r.replyDraftSubject = "Re: Photographing the Clarion Choir"
        r.replyDraftBody = "Thanks for getting back to me. July 4 works well..."
        r.replyDraftRequestedAt = when
        r.intentHint = ReplyIntent.wantsToBook.rawValue
        #expect(r.replyDraftSubject == "Re: Photographing the Clarion Choir")
        #expect(r.replyDraftBody?.hasPrefix("Thanks") == true)
        #expect(r.replyDraftRequestedAt == when)
        #expect(r.intentHint == "wants_to_book")
    }

    // A4 (#418): reply-triage auto-pause is its OWN flag, distinct from sendState .suppressed
    // (which means booking-freeze). Defaults off.
    @Test func pausedByReplyDefaultsOff() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.pausedByReply == false)
        r.pausedByReply = true
        #expect(r.pausedByReply == true)
    }

    // #418 B2 — manual-judge marking stamps the manual source flag (so detection won't overwrite) and
    // maps the locked vocabulary onto resolution + bounced with no new enum.
    @Test func manualMarkingMapsTheLockedVocabularyAndStampsManualSource() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)

        r.markOutcomeManually(resolution: .booked)                 // Booked (attribution only)
        #expect(r.resolution == .booked)
        #expect(r.bounced == false)
        #expect(r.outcomeSource == .manual)

        r.markOutcomeManually(resolution: .declinedSoft)           // Closed-not-now
        #expect(r.resolution == .declinedSoft)

        r.markOutcomeManually(resolution: .declinedHard)           // Closed-no
        #expect(r.resolution == .declinedHard)

        r.markOutcomeManually(resolution: nil, bounced: true)      // Bounced
        #expect(r.resolution == nil)
        #expect(r.bounced == true)

        r.markOutcomeManually(resolution: nil)                     // In conversation
        #expect(r.resolution == nil)
        #expect(r.bounced == false)
        #expect(r.outcomeSource == .manual)                        // still stamped manual
    }

    // #418 B2↔A2 — a hand-marked contact is never overwritten by auto reply detection.
    @MainActor
    @Test func aManuallyMarkedContactIsNotOverwrittenByDetection() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.sentAt = Date()
        ctx.insert(p)
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.gmailThreadId = "t1"; r.sendState = .sent
        r.markOutcomeManually(resolution: .declinedHard)   // Dan judged: not interested
        p.addRecipient(r)

        let reply = Data(#"{"messages":[{"payload":{"headers":[{"name":"From","value":"them@org.org"}]}}]}"#.utf8)
        let n = ReplyService.detectReplies(in: [p], selfEmail: "dan@danwrightphotography.com",
                                           now: Date()) { _ in reply }
        #expect(n == 0)                          // detection skips the hand-marked contact
        #expect(r.resolution == .declinedHard)   // Dan's call stands
        #expect(r.replied == false)
    }

    // #418 B1 — the conversation-surface action path: marking ONE contact locates exactly that
    // recipient, applies the manual mark, persists it, and leaves the other contacts untouched (the
    // substance of QueueView.markContact, which is `updateRecipient(id:) { markOutcomeManually }` + save).
    @MainActor
    @Test func markingOneContactLocatesPersistsAndLeavesOthersUntouched() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.sentAt = Date()
        ctx.insert(p)
        let a = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act); a.sendState = .sent
        let b = Recipient(id: "b@present.example", email: "b@present.example", provenance: .presenter); b.sendState = .sent
        p.setRecipients([a, b])
        try ctx.save()

        // Mark only contact B booked (attribution).
        p.updateRecipient(id: "b@present.example") { $0.markOutcomeManually(resolution: .booked) }
        try ctx.save()

        let back = try ctx.fetch(FetchDescriptor<Prospect>()).first
        #expect(back?.recipients.first { $0.id == "b@present.example" }?.resolution == .booked)
        #expect(back?.recipients.first { $0.id == "b@present.example" }?.outcomeSource == .manual)
        #expect(back?.recipients.first { $0.id == "a@act.example" }?.resolution == nil)   // others untouched
        #expect(back?.recipients.first { $0.id == "a@act.example" }?.outcomeSource == nil)
        // The lead booking is NOT set by a recipient attribution mark (decision g).
        #expect(back?.outcome != .booked)
    }

    // Per-recipient resolution (#389 derived-outcome model): an additive field capturing the
    // terminal commercial outcomes that aren't inferable from send/reply/bounce state. Phase 5
    // reads it to derive the performance status; here we only pin that it round-trips.
    @Test func resolutionMapsThroughRawString() {
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        #expect(r.resolution == nil)
        r.resolution = .declinedSoft
        #expect(r.resolutionRaw == "declined_soft")
        r.resolutionRaw = "booked"
        #expect(r.resolution == .booked)
    }
}
