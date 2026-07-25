import Testing
import Foundation
import SwiftData
@testable import Overture

// #1436: the inquiry actions that CHANGE something, moved out of QueueView and InquiryReplySheet so
// each is a plain function a test can call (#863, the ExcludedTownMutations / WatchlistMutations
// idiom). The reason this matters beyond testability: both surfaces persisted with a bare
// `try? context.save()` (QueueView) or a hand-rolled do/catch (InquiryReplySheet), so a failed write
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

    // "Mark lost" is the SOFT lost case, not lostHard: Dan is closing an inquiry that went quiet, which
    // is not the same as a hard refusal, and the two feed #16's outcome reporting differently.
    @Test("marking lost closes it as the soft lost case, never lostHard")
    func lostIsTheSoftCase() throws {
        let ctx = ModelContext(try container())
        let inquiry = make(ctx)

        InquiryMutations.mark(inquiry, as: .lost, context: ctx, feedback: ActionFeedback(), now: Date())

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
        #expect(InquiryMutations.showsReplyAction(sentAt: nil))
        #expect(!InquiryMutations.showsReplyAction(sentAt: Date()))
    }
}
