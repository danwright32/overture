import Testing
import Foundation
import SwiftData

// #2007: prepping a show by hand from the card, and when that is even offered.
@MainActor
@Suite("Prep manually (#2007)")
struct ManualPrepMutationTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func kept(_ ctx: ModelContext, status: ReviewStatus = .queued) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Bargemusic", discipline: "classical",
                         venue: "Boathouse", performanceDate: "2026-11-14", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "booked", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 9, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil, status: status)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // MARK: - Saving

    @Test func savingWritesTheDraftAndTheContactInOneGo() throws {
        let ctx = try context()
        let p = kept(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.prepManually(QueueItem(p), email: "Olga@Bargemusic.org", name: "Olga",
                                       subject: "Your November dates",
                                       body: "Hi Olga, are the November dates set yet?",
                                       prospects: [p], context: ctx, feedback: feedback)

        #expect(p.status == .drafted)
        #expect(p.draftWrittenByDan)
        #expect(p.draftSubject == "Your November dates")
        #expect(p.recipients.count == 1)
        #expect(p.recipients.first?.email == "Olga@Bargemusic.org")
        #expect(p.recipients.first?.provenance == .manual)
        #expect(feedback.message == "Bargemusic is drafted and ready for you to review")
    }

    // He typed the address of somebody already on this show. Adding a second copy of one contact would
    // pitch them twice, so the existing one is used and nothing is duplicated.
    @Test func anAddressAlreadyOnTheShowIsNotAddedTwice() throws {
        let ctx = try context()
        let p = kept(ctx)
        p.addRecipient(Recipient(id: "olga@bargemusic.org", email: "olga@bargemusic.org", provenance: .act))
        try ctx.save()

        ProspectMutations.prepManually(QueueItem(p), email: "olga@bargemusic.org", name: nil,
                                       subject: "s", body: "b",
                                       prospects: [p], context: ctx, feedback: ActionFeedback())

        #expect(p.recipients.count == 1)
        #expect(p.status == .drafted)
    }

    // The failure path: an email with no words in it is not a draft. Nothing is written, and it says so
    // rather than moving the show to Review with an empty body.
    @Test func anEmptyBodyIsRefusedAndNothingIsWritten() throws {
        let ctx = try context()
        let p = kept(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.prepManually(QueueItem(p), email: "olga@bargemusic.org", name: nil,
                                       subject: "Your November dates", body: "   ",
                                       prospects: [p], context: ctx, feedback: feedback)

        #expect(p.status == .queued)
        #expect(p.hasDraft == false)
        #expect(p.recipients.isEmpty)
        #expect(feedback.message == "Write the email before saving it. Nothing was saved")
    }

    @Test func anEmptyRecipientIsRefusedAndNothingIsWritten() throws {
        let ctx = try context()
        let p = kept(ctx)
        let feedback = ActionFeedback()

        ProspectMutations.prepManually(QueueItem(p), email: " ", name: nil,
                                       subject: "s", body: "b",
                                       prospects: [p], context: ctx, feedback: feedback)

        #expect(p.status == .queued)
        #expect(p.hasDraft == false)
        #expect(feedback.message == "Add an address to send to. Nothing was saved")
    }

    // #901's gate holds here too. A hand-written pitch for a night Dan cannot work is the same wrong
    // email as an AI one, and the same sentence says so.
    @Test func aShowOnANightHeCannotWorkIsRefusedWithTheSameSentence() throws {
        let ctx = try context()
        let p = kept(ctx)
        p.setScoutConflict(BlockedCalendar.Day(date: "2026-11-14", kind: .dayOff, name: "Vacation").key)
        try ctx.save()
        let feedback = ActionFeedback()

        ProspectMutations.prepManually(QueueItem(p), email: "olga@bargemusic.org", name: nil,
                                       subject: "s", body: "b",
                                       prospects: [p], context: ctx, feedback: feedback)

        #expect(p.hasDraft == false)
        #expect(feedback.message == ActionAck.manualPrepBlockedByClash(org: "Bargemusic"))
    }

    // MARK: - What the editor will accept

    // The Save button and the refusal above are ONE rule, so a button that looks enabled can never be
    // refused on click, and a refusal can never name something the button did not gate on.
    @Test func theEditorAcceptsAnAddressAndAnEmail() {
        #expect(ManualPrepEditing.refusal(email: "olga@bargemusic.org", subject: "s", body: "b") == nil)
        #expect(ManualPrepEditing.canSave(email: "olga@bargemusic.org", subject: "s", body: "b"))
    }

    @Test func theEditorNamesWhichPieceIsMissing() {
        #expect(ManualPrepEditing.refusal(email: " ", subject: "s", body: "b") == ActionAck.manualPrepNeedsRecipient)
        #expect(ManualPrepEditing.refusal(email: "olga@bargemusic.org", subject: "s", body: "\n ")
                == ActionAck.manualPrepNeedsBody)
        #expect(ManualPrepEditing.canSave(email: "olga@bargemusic.org", subject: "s", body: " ") == false)
    }

    // #2052: a subject IS required, and this test used to assert the opposite. The reasoning then was
    // that he might be writing into a thread that already had one, so an empty subject was a choice.
    // Nothing downstream treated it as one: it saved, read as ready, and sent with an empty header.
    @Test func theEditorRequiresASubject() {
        #expect(ManualPrepEditing.refusal(email: "olga@bargemusic.org", subject: " ", body: "b")
                == ActionAck.manualPrepNeedsSubject)
    }

    // MARK: - When the control is offered

    @Test func offeredOnAKeptShowWithNoDraft() throws {
        let ctx = try context()
        #expect(QueueModel.manualPrepOffer(for: QueueItem(kept(ctx))) == .shown)
    }

    // Nothing to prep: it already has an email, whoever wrote it.
    @Test func notOfferedOnceTheShowHasADraft() throws {
        let ctx = try context()
        let p = kept(ctx)
        p.writeManualDraft(subject: "s", body: "b")
        #expect(QueueModel.manualPrepOffer(for: QueueItem(p)) == .hidden)
    }

    // Keep is the decision that makes a show prep work. An untriaged one is not offered a draft.
    @Test func notOfferedOnAShowHeHasNotKept() throws {
        let ctx = try context()
        #expect(QueueModel.manualPrepOffer(for: QueueItem(kept(ctx, status: .new))) == .hidden)
    }

    // Offered but inert, saying why, rather than vanishing: the sentence teaches, and "I can shoot this
    // anyway" sits on the same card to clear it.
    @Test func blockedWithItsReasonOnANightHeCannotWork() throws {
        let ctx = try context()
        let p = kept(ctx)
        p.setScoutConflict(BlockedCalendar.Day(date: "2026-11-14", kind: .dayOff, name: "Vacation").key)
        #expect(QueueModel.manualPrepOffer(for: QueueItem(p))
                == .blocked(ActionAck.manualPrepBlockedByClash(org: "Bargemusic")))
    }
}
