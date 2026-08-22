import Testing
import Foundation
import SwiftData

// #2575: Dan, at the closing-note send sheet on 2026-08-13: "I have no way to edit closing notes."
//
// Follow-ups and the post-event closing note were the only two outbound paths in the app with no text
// box. Both are composed end to end by Overture and were drawn as read-only text on the send sheet, so he
// read a message he could not change and then either sent it as written or cancelled. His rule from
// #2010 is "whatever is in the text box that I see is what's sent", and here there was no box.
//
// Every other outbound path already had an editor (DraftReviewView, ReplySheet, ReplyConversationView,
// ManualPrepSheet), so this was two callers out of step rather than a missing capability.
@MainActor
@Suite("Editing a follow-up or closing note before it sends (#2575)")
struct EditAFollowUpBeforeItSendsTests {

    private final class CapturingSender: MailSender, @unchecked Sendable {
        var last: OutgoingMail?
        func send(_ mail: OutgoingMail) async throws -> SentReceipt {
            last = mail
            return SentReceipt(threadId: "t", messageID: "<m>")
        }
    }

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: AppSchema.schema,
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func show(_ ctx: ModelContext, passed: Bool = false) -> (Prospect, Recipient) {
        let date = passed ? "2026-08-01" : "2026-12-01"
        let p = Prospect(naturalKey: "k", groupName: "Devin Marlowe", discipline: "music",
                         venue: "54 Below", performanceDate: date, sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 6, tier: "mid",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: .contacted)
        p.sentAt = Date(timeIntervalSince1970: 1_780_000_000)
        ctx.insert(p)
        let r = Recipient(id: "devin@devinmarlowe.example", email: "devin@devinmarlowe.example",
                          name: "Devin", provenance: .act)
        r.sendState = .sent
        r.sentAt = p.sentAt
        r.gmailMessageId = "m1"
        r.gmailThreadId = "t1"
        p.setRecipients([r])
        try? ctx.save()
        return (p, r)
    }

    // MARK: what actually leaves

    // THE test for the follow-up: the words that go out are the words in the box, not the composed
    // original. Anything less and the editor is decoration (L3: built is not wired).
    @Test func afollowUpSendsTheEditedWordsNotTheComposedOnes() async throws {
        let ctx = try context()
        let (p, r) = show(ctx)
        let sender = CapturingSender()

        let sent = await SendService.sendFollowUp(r, of: p, now: Date(), sender: sender,
                                                  body: "Devin, one more thought about August 11.")

        #expect(sent)
        #expect(sender.last?.body.contains("Devin, one more thought about August 11.") == true)
        #expect(sender.last?.body.contains("I wanted to follow up on my earlier note") == false)
    }

    // #2710: the closing note's own edited-body test stood here and went with the email. The
    // follow-up's, above, covers the same rule on the send that remains.

    // Untouched, both paths compose exactly what they composed before, so an unedited send is unchanged.
    @Test func anuneditedSendStillSendsTheComposedMessage() async throws {
        let ctx = try context()
        let (p, r) = show(ctx)
        let sender = CapturingSender()

        _ = await SendService.sendFollowUp(r, of: p, now: Date(), sender: sender)

        #expect(sender.last?.body.contains("I wanted to follow up on my earlier note") == true)
    }

    // The SUBJECT is not editable and must keep coming from the shared helper, because it is what threads
    // the reply onto the conversation Gmail is watching (#74). An edited body must not disturb it.
    @Test func editingTheBodyLeavesTheThreadingSubjectAlone() async throws {
        let ctx = try context()
        let (p, r) = show(ctx)
        p.draftSubject = "Photographing Devin Marlowe's December 1 show at 54 Below"
        let sender = CapturingSender()

        _ = await SendService.sendFollowUp(r, of: p, now: Date(), sender: sender, body: "Short note.")

        #expect(sender.last?.subject == "Re: Photographing Devin Marlowe's December 1 show at 54 Below")
    }

    // Failure path: an emptied box is not a message. Nothing leaves, and the send says so rather than
    // mailing a signature under Dan's name with nothing above it.
    @Test func anemptiedBodySendsNothing() async throws {
        let ctx = try context()
        let (p, r) = show(ctx)
        let sender = CapturingSender()

        let sent = await SendService.sendFollowUp(r, of: p, now: Date(), sender: sender, body: "   \n ")

        #expect(!sent)
        #expect(sender.last == nil)
    }

    // #2710: the emptied closing note's test stood here, including the assertion that an unsent note
    // closed nothing out. Both went with the email. Nothing writes an outcome on a send any more: the
    // ending is Dan's to record, from the close-out prompt the show now raises.
}

// #2575: the sheet itself. The rule is Dan's from #2010, "whatever is in the text box that I see is what's
// sent", so the sheet has to hand the send what the box holds at the moment Send is pressed, and must not
// offer Send at all when the box is empty.
@MainActor
@Suite("The send sheet's editable body (#2575)")
struct SendConfirmSheetEditingTests {

    @Test func anemptyBodyIsNotSendable() {
        #expect(!SendConfirmEditing.bodyIsSendable(""))
        #expect(!SendConfirmEditing.bodyIsSendable("   \n\t "))
        #expect(SendConfirmEditing.bodyIsSendable("Hi Devin,\n\nOne more thought."))
    }

    // The edit surface and the contact picker are mutually exclusive by construction. A rebuild for a
    // different set of recipients recomposes the body, which would silently throw away what Dan typed
    // (L5: never destroy good state), so a sheet that can edit never offers the picker.
    @Test func aneditableSheetNeverAlsoOffersTheContactPicker() {
        #expect(!SendConfirmEditing.offersChoice(hasRebuild: true, candidates: 3, isEditable: true))
        #expect(SendConfirmEditing.offersChoice(hasRebuild: true, candidates: 3, isEditable: false))
        #expect(!SendConfirmEditing.offersChoice(hasRebuild: false, candidates: 3, isEditable: false))
    }
}
