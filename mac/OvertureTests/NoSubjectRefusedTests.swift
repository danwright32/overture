import Testing
import Foundation
import SwiftData

// Records every mail it is handed, so a test can prove nothing left rather than only that a
// function returned false.
private final class RecordingSender: MailSender, @unchecked Sendable {
    var sent: [OutgoingMail] = []
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        sent.append(mail)
        return SentReceipt(threadId: "t", messageID: "<m@x.org>")
    }
}

// #2052: an email with no subject could be sent, on every path.
//
// Found by Dan on the send confirmation for his first hand-prepped show: the sheet rendered
// "SUBJECT  (no subject)" with the Send button fully enabled beside it, and pressing it sent a real
// email with an empty Subject header. The placeholder was a DETECTION that the value was missing
// (L67), so it had to block the action it appeared in rather than label it.
//
// Four refusals, because a guard on one screen is not a guard (L27): the by-hand editor will not
// save one, the show does not read as sendable, no confirmation sheet is built for it, and the
// boundary that composes the outgoing mail refuses it if it somehow got that far.
@MainActor
@Suite("An email with no subject is refused (#2052)")
struct NoSubjectRefusedTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func show(_ ctx: ModelContext, subject: String?, body: String? = "Hi there.",
                      status: ReviewStatus = .approved) -> Prospect {
        let key = Prospect.makeNaturalKey(groupName: "G", performanceDate: "2026-09-01", venue: "V")
        let p = Prospect(naturalKey: key, groupName: "G", discipline: "choral", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status, ingestedAt: Date())
        p.draftSubject = subject
        p.draftBody = body
        ctx.insert(p)
        let r = Recipient(id: "olga@org.example", email: "olga@org.example", name: "Olga",
                          provenance: .presenter)
        p.setRecipients([r])
        try? ctx.save()
        return p
    }

    // MARK: - 1. The by-hand editor will not save one

    @Test func theByHandEditorRefusesToSaveWithoutASubject() {
        #expect(ManualPrepEditing.refusal(email: "olga@org.example", subject: "  \n", body: "b")
                == ActionAck.manualPrepNeedsSubject)
        #expect(ManualPrepEditing.canSave(email: "olga@org.example", subject: "", body: "b") == false)
        #expect(ManualPrepEditing.canSave(email: "olga@org.example", subject: "s", body: "b"))
    }

    // The refusal and the save are one rule, so the show is left untouched rather than half written.
    @Test func prepManuallyWritesNothingWhenTheSubjectIsBlank() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, subject: nil, body: nil, status: .queued)
        let feedback = ActionFeedback()

        ProspectMutations.prepManually(QueueItem(p), email: "olga@org.example", name: nil,
                                       subject: "   ", body: "A real email body.",
                                       prospects: [p], context: ctx, feedback: feedback)

        #expect(p.draftBody == nil, "Nothing may be written when the save is refused")
        #expect(p.status == .queued)
        #expect(feedback.message == ActionAck.manualPrepNeedsSubject)
    }

    // MARK: - 2. The show does not read as sendable

    @Test func aDraftWithNoSubjectIsNotSendable() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, subject: "")
        let r = try #require(p.recipients.first)

        #expect(r.isSendablePending == false)
        #expect(SendService.nextPendingRecipient(for: p) == nil)

        p.draftSubject = "Photographs of your September concert"
        #expect(r.isSendablePending, "A subject is all that was holding it")
    }

    // A show with no draft at all is untouched by this rule: it has no subject because it has no
    // email yet, which is a different state from a written email missing its subject line.
    @Test func aShowWithNoDraftAtAllIsUnaffected() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, subject: nil, body: nil, status: .queued)
        let r = try #require(p.recipients.first)

        #expect(p.draftIsMissingSubject == false)
        #expect(r.isSendablePending)
    }

    // MARK: - 3. The confirmation sheet is never built for one

    @Test func noConfirmationIsBuiltForADraftWithNoSubject() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, subject: "   ")

        #expect(SendConfirmation(prospect: p, signature: .none) == nil)
    }

    // The greyed Send button says why, rather than leaving Dan looking at a control that does
    // nothing (the #1311 shape, for the same reason).
    @Test func theGreyedSendButtonSaysWhy() {
        #expect(DraftReviewNotes.noSubject(isApproved: true, subject: " ")
                == "Approved, but no subject line. Edit the draft to add one.")
        #expect(DraftReviewNotes.noSubject(isApproved: true, subject: "A subject") == nil)
        #expect(DraftReviewNotes.noSubject(isApproved: false, subject: nil) == nil)
    }

    // MARK: - 4. The boundary that composes the mail refuses it

    @Test func anOutgoingMailCannotBeBuiltWithoutASubject() {
        #expect(OutgoingMail(to: ["olga@org.example"], subject: "", body: "b") == nil)
        #expect(OutgoingMail(to: ["olga@org.example"], subject: " \n ", body: "b") == nil)
        #expect(OutgoingMail(to: ["olga@org.example"], subject: "S", body: "b") != nil)
    }

    // The whole stack, from the press of Send: nothing reaches the sender at all.
    @Test func pressingSendOnASubjectlessShowSendsNothing() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx, subject: "")
        let sender = RecordingSender()

        let didSend = await SendService.sendNext(p, now: Date(), sender: sender)

        #expect(didSend == false)
        #expect(sender.sent.isEmpty, "No email may leave with an empty Subject header")
        #expect(p.recipients.first?.sentAt == nil)
    }
}
