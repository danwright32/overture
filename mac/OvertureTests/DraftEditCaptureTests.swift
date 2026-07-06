import Testing
import Foundation
import SwiftData
@testable import Overture

// #240 (milestone 6 / #119): capture the learning pair. The AI's draft must be snapshotted the
// first time Dan SUBSTANTIVELY edits it (trivial/no-op saves must not overwrite that baseline),
// and the exact body emailed must be frozen at send so a later draft edit can't make the "sent"
// side lie. Both halves feed the voice-learning loop.

private struct FixedSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        SentReceipt(threadId: "t-240", messageID: "<m-240@x.org>")
    }
}

@MainActor
@Suite("Draft edit capture (#240)")
struct DraftEditCaptureTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func drafted(subject: String = "Photographing the spring run",
                         body: String = "Hi there, I'd be glad to cover this.") -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.contactEmail = "to@org.org"
        p.draftSubject = subject
        p.draftBody = body
        return p
    }

    @Test func firstSubstantiveEditSnapshotsTheAIDraft() {
        let p = drafted()
        p.applyEdit(subject: "Photographing the spring run",
                    body: "Hi there, I'd be happy to photograph this run.")

        #expect(p.originalDraftSubject == "Photographing the spring run")
        #expect(p.originalDraftBody == "Hi there, I'd be glad to cover this.")
        #expect(p.draftBody == "Hi there, I'd be happy to photograph this run.")
        #expect(p.draftEditedByDan == true)
    }

    @Test func secondEditDoesNotClobberTheAIBaseline() {
        let p = drafted()
        p.applyEdit(subject: p.draftSubject!, body: "First revision.")
        p.applyEdit(subject: p.draftSubject!, body: "Second, later revision.")

        // The baseline stays the ORIGINAL AI draft, not the first revision.
        #expect(p.originalDraftBody == "Hi there, I'd be glad to cover this.")
        #expect(p.draftBody == "Second, later revision.")
    }

    @Test func noOpSaveDoesNotSnapshot() {
        let p = drafted()
        p.applyEdit(subject: p.draftSubject!, body: p.draftBody!)

        // Saving unchanged text is not a learning signal: no baseline captured.
        #expect(p.originalDraftBody == nil)
        #expect(p.originalDraftSubject == nil)
    }

    @Test func whitespaceOnlyEditDoesNotSnapshot() {
        let p = drafted()
        p.applyEdit(subject: "  Photographing the spring run  ",
                    body: "Hi there,   I'd be glad to cover this.\n")

        // Only whitespace differs: not substantive, so nothing is captured.
        #expect(p.originalDraftBody == nil)
    }

    @Test func sendFreezesTheExactSentBodyImmuneToLaterEdits() async throws {
        let ctx = ModelContext(try container())
        let p = drafted(subject: "Sent subject", body: "The exact body that went out.")
        ctx.insert(p)
        if let r = RecipientBackfill.synthesizedRecipient(from: p) { p.setRecipients([r]) }
        try ctx.save()

        #expect(await SendService.sendOne(p, now: Date(timeIntervalSince1970: 1), sender: FixedSender()) == true)
        #expect(p.sentBody == "The exact body that went out.")
        #expect(p.sentSubject == "Sent subject")

        // A later edit to the draft must NOT change the frozen sent copy.
        p.applyEdit(subject: "Sent subject", body: "Reworded after the fact.")
        #expect(p.sentBody == "The exact body that went out.")
    }

    @Test func sendOneFreezesTheSentBody() async throws {
        let ctx = ModelContext(try container())
        let p = drafted(subject: "One-off subject", body: "One-off body sent now.")
        ctx.insert(p)
        if let r = RecipientBackfill.synthesizedRecipient(from: p) { p.setRecipients([r]) }
        try ctx.save()

        #expect(await SendService.sendOne(p, now: Date(), sender: FixedSender()) == true)
        #expect(p.sentBody == "One-off body sent now.")
        #expect(p.sentSubject == "One-off subject")
    }
}
