import Testing
import Foundation
import SwiftData

// #1436: the inquiry actions that CHANGE something, moved out of QueueView and the inquiry reply sheet so
// each is a plain function a test can call (#863, the ExcludedTownMutations / WatchlistMutations
// idiom). The reason this matters beyond testability: both surfaces persisted with a bare
// `try? context.save()` (QueueView) or a hand-rolled do/catch (the reply sheet), so a failed write
// either went nowhere at all or duplicated the message #623 already consolidated into
// `saveOrWarnSendNotConfirmed`. Marking an inquiry booked pulls it out of the queue on screen, so a
// silently-lost write is a state Dan cannot see and cannot get back to.
@MainActor
@Suite("Inquiry mutations (#1436)")
struct InquiryMutationsTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func make(_ ctx: ModelContext, name: String = "Ada Lovelace") -> Inquiry {
        let inquiry = Inquiry(source: .contactForm, inquirerName: name, inquirerEmail: "ada@x.org",
                              eventName: "Spring Gala", performanceDate: "2026-05-01", venue: "Weill")
        ctx.insert(inquiry)
        return inquiry
    }

    @Test("marking booked records Dan's own call and confirms it saved")
    func bookedIsManualAndConfirmed() throws {
        let ctx = ModelContext(try container())
        let feedback = ActionFeedback()
        let inquiry = make(ctx)
        inquiry.bookingSuggested = true
        let now = Date(timeIntervalSince1970: 1_780_000_000)

        let saved = InquiryMutations.mark(inquiry, as: .booked, context: ctx, feedback: feedback, now: now)

        #expect(saved)
        #expect(inquiry.outcome == .booked)
        #expect(inquiry.outcomeSourceRaw == OutcomeSource.manual.rawValue)
        #expect(inquiry.outcomeAt == now)
        #expect(!inquiry.bookingSuggested)
        #expect(!inquiry.isOpen)
        #expect(feedback.message == nil)
    }

    // Closing an inquiry that went quiet is the SOFT lost case: the door stays open for future work,
    // which is not the same as a refusal. InquiryLostReasonTests covers the full split.
    @Test("closing a silence is the soft lost case, never lostHard")
    func lostIsTheSoftCase() throws {
        let ctx = ModelContext(try container())
        let inquiry = make(ctx)

        InquiryMutations.mark(inquiry, as: .lost(.neverHeardBack), context: ctx,
                              feedback: ActionFeedback(), now: Date())

        #expect(inquiry.outcome == .lostSoft)
        #expect(inquiry.outcome != .lostHard)
        #expect(!inquiry.isOpen)
    }

    // The failure path, which is the whole point of the extraction: a genuine save() throw must reach
    // Dan. Before this, QueueView's `try? context.save()` discarded it and the row still vanished from
    // the queue, so the screen showed an outcome the store did not have.
    @Test("a failing save warns Dan instead of silently dropping the outcome")
    func failedSaveIsSurfaced() async throws {
        let feedback = ActionFeedback()

        let (saved, outcomeInMemory, stillPending) = try await ImmutableStoreFixture.withFailingSave(
            schema: Schema([Inquiry.self]),
            seed: { _ = self.make($0, name: "Seed Person") },
            body: { ctx in
                let inquiry = self.make(ctx, name: "Ada Lovelace")
                let saved = InquiryMutations.mark(inquiry, as: .booked, context: ctx,
                                                  feedback: feedback, now: Date())
                return (saved, inquiry.outcome, ctx.hasChanges)
            })

        #expect(!saved)
        #expect(feedback.message == "Couldn't save the change for Ada Lovelace")
        #expect(feedback.tone == .warning)
        // The change stays pending rather than being rolled back, so a retry fails the same way
        // instead of reporting a clean context over a lost write (the #1417 property).
        #expect(outcomeInMemory == .booked)
        #expect(stillPending)
    }

    // The Send button's enablement rule, lifted out of the sheet body so it is reachable. An inquiry
    // logged without an email cannot be replied to from here at all, which is why the sheet says so.
    @Test("a reply can only be sent with an address, a subject, and a body")
    func canSendRequiresAllThree() {
        #expect(InquiryMutations.canSend(email: "ada@x.org", subject: "Re: your inquiry", body: "Hello"))
        #expect(!InquiryMutations.canSend(email: nil, subject: "Re: your inquiry", body: "Hello"))
        #expect(!InquiryMutations.canSend(email: "", subject: "Re: your inquiry", body: "Hello"))
        #expect(!InquiryMutations.canSend(email: "ada@x.org", subject: "   ", body: "Hello"))
        #expect(!InquiryMutations.canSend(email: "ada@x.org", subject: "Re: your inquiry", body: "  \n "))
    }

    // The row only offers Reply for a first reply. Once Dan has sent one, replying again is a
    // different, unbuilt thing (#1497 covers the stalled follow-up), so the button must not imply it.
    @Test("the Reply action is offered only before the first reply has been sent")
    func replyActionOnlyBeforeFirstReply() {
        #expect(InquiryMutations.showsReplyAction(sentAt: nil, replied: false, bounced: false))
        #expect(!InquiryMutations.showsReplyAction(sentAt: Date(), replied: false, bounced: false))
    }

    private struct StubSender: MailSender {
        let receipt: SentReceipt
        func send(_ mail: OutgoingMail) async throws -> SentReceipt { receipt }
    }
    private struct FailingSender: MailSender {
        func send(_ mail: OutgoingMail) async throws -> SentReceipt { throw MailSenderError.notConfigured }
    }

    @Test("a sent first reply is recorded and the sheet closes clean")
    func sendSucceedsAndSaves() async throws {
        let ctx = ModelContext(try container())
        let feedback = ActionFeedback()
        let inquiry = make(ctx)
        let now = Date(timeIntervalSince1970: 42)

        let result = await InquiryMutations.sendReply(
            inquiry, subject: "Re: your inquiry", body: "Hello Ada", now: now,
            sender: StubSender(receipt: SentReceipt(threadId: "th-1", messageID: "mid-1")),
            context: ctx, feedback: feedback)

        #expect(result == .sent)
        #expect(inquiry.sentAt == now)
        #expect(feedback.message == nil)
    }

    // The mail is already gone in this case, so the sheet must still close; what must NOT happen is it
    // closing quietly. Dan gets the shared "check Gmail" warning rather than a fifth bespoke sentence.
    @Test("a send that goes out but fails to save still closes, and warns Dan to check Gmail")
    func sendSucceedsButSaveFails() async throws {
        let feedback = ActionFeedback()

        let result = try await ImmutableStoreFixture.withFailingSave(
            schema: Schema([Inquiry.self]),
            seed: { _ = self.make($0, name: "Seed Person") },
            body: { ctx in
                let inquiry = self.make(ctx, name: "Ada Lovelace")
                return await InquiryMutations.sendReply(
                    inquiry, subject: "s", body: "b", now: Date(),
                    sender: StubSender(receipt: SentReceipt(threadId: "th-2", messageID: "mid-2")),
                    context: ctx, feedback: feedback)
            })

        #expect(result == .sent)
        #expect(feedback.message == "Couldn't save what happened sending to Ada Lovelace: check Gmail to see if it went out.")
        #expect(feedback.tone == .warning)
    }

    // A refused send must leave the inquiry visibly unsent and keep the sheet open on an actionable
    // error, never a dead spinner and never a silent fake success.
    @Test("a refused send reports failure and leaves the inquiry unsent")
    func sendFails() async throws {
        let ctx = ModelContext(try container())
        let feedback = ActionFeedback()
        let inquiry = make(ctx)

        let result = await InquiryMutations.sendReply(
            inquiry, subject: "s", body: "b", now: Date(),
            sender: FailingSender(), context: ctx, feedback: feedback)

        #expect(result == .sendFailed)
        #expect(inquiry.sentAt == nil)
        #expect(!inquiry.wasProvablyContacted)
    }
}

// #1436: the intake sheet's own rules, lifted out of the SwiftUI body for the same reason as the rest
// (#863). Only the name is required; everything else about the event can be unknown at intake.
@MainActor
@Suite("Inquiry intake rules (#1436)")
struct InquiryIntakeRulesTests {
    @Test("an inquiry can be logged with only a name, but not without one")
    func nameIsTheOnlyRequirement() {
        #expect(InquiryIntake.canSave(name: "Ada"))
        #expect(!InquiryIntake.canSave(name: ""))
        #expect(!InquiryIntake.canSave(name: "   "))
    }

    // The "date is known" toggle is the whole point: an inquiry often arrives before a date exists, and
    // an unknown date must stay genuinely unknown rather than defaulting to today, which would both
    // mis-key the event and file it under the wrong day in the queue.
    @Test("an unknown date stays nil rather than defaulting to today")
    func unknownDateStaysUnknown() {
        let someDay = Date(timeIntervalSince1970: 1_780_000_000)
        #expect(InquiryIntake.performanceDate(hasDate: false, date: someDay) == nil)
        #expect(InquiryIntake.performanceDate(hasDate: true, date: someDay)
                == EasternDate.dayString(from: someDay))
    }
}
