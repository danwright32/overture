import Testing
import Foundation
import SwiftData

// #1513 follow-on. Overture could compose the FIRST reply to a hire inquiry and nothing after it: once
// they wrote back, the row said "They replied" and offered no way to answer. That gap is why moving a
// replied inquiry to Follow-ups would not have helped, since it would still have had no action there.
//
// Replying again is the same act as replying the first time (Dan types it himself, it goes on the same
// thread), so it runs through the same sender. What has to change is the WAITING state: after he
// answers he is waiting on them again, and their old reply must not immediately re-flag the row as
// needing him.
@MainActor
@Suite("Replying again to an inquiry (#1513)")
struct InquiryReplyAgainTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private struct StubSender: MailSender {
        let receipt: SentReceipt
        func send(_ mail: OutgoingMail) async throws -> SentReceipt { receipt }
    }
    private struct FailingSender: MailSender {
        func send(_ mail: OutgoingMail) async throws -> SentReceipt { throw MailSenderError.notConfigured }
    }

    // An inquiry Dan already replied to, which they have since answered.
    private func repliedTo(_ ctx: ModelContext) -> Inquiry {
        let inq = Inquiry(source: .contactForm, inquirerName: "Ada", inquirerEmail: "ada@x.org",
                          eventName: "Gala")
        inq.sentAt = Date(timeIntervalSince1970: 1_000)
        inq.gmailThreadId = "th-1"
        inq.gmailMessageId = "m-1"
        inq.replied = true
        inq.repliedAt = Date(timeIntervalSince1970: 2_000)
        inq.lastReplyId = "reply-1"
        inq.lastReplyText = "Sounds good, what are your rates?"
        ctx.insert(inq)
        return inq
    }

    @Test("the row offers a way to answer once they have replied")
    func replyActionReturnsAfterTheyReply() {
        // Before this, Reply was offered ONLY before the first send, so a replied inquiry had none.
        #expect(InquiryMutations.showsReplyAction(sentAt: nil, replied: false, bounced: false))
        #expect(!InquiryMutations.showsReplyAction(sentAt: Date(), replied: false, bounced: false),
                "still no action while waiting on them")
        #expect(InquiryMutations.showsReplyAction(sentAt: Date(), replied: true, bounced: false),
                "they answered, so Dan can answer back")
    }

    @Test("answering again puts the inquiry back to waiting on them")
    func answeringAgainRestartsTheWait() async throws {
        let ctx = ModelContext(try container())
        let inq = repliedTo(ctx)
        let now = Date(timeIntervalSince1970: 3_000)

        let result = await InquiryMutations.sendReply(
            inq, subject: "Re: your inquiry", body: "Here are my rates", now: now,
            sender: StubSender(receipt: SentReceipt(threadId: "th-1", messageID: "m-2")),
            context: ctx, feedback: ActionFeedback())

        #expect(result == .sent)
        #expect(inq.sentAt == now, "the wait restarts from this reply")
        #expect(!inq.replied, "he is waiting on them again, not sitting on an unanswered reply")
        #expect(inq.isOpen)
    }

    // The one that would bite silently: reply detection keys off the last reply id, so unless the reply
    // he just answered is marked handled, the very next check would flag the row as needing him again
    // and it would never leave the "they replied" state.
    @Test("their old reply does not immediately re-flag the row")
    func theAnsweredReplyIsMarkedHandled() async throws {
        let ctx = ModelContext(try container())
        let inq = repliedTo(ctx)

        _ = await InquiryMutations.sendReply(
            inq, subject: "s", body: "b", now: Date(timeIntervalSince1970: 3_000),
            sender: StubSender(receipt: SentReceipt(threadId: "th-1", messageID: "m-2")),
            context: ctx, feedback: ActionFeedback())

        #expect(inq.dismissedReplyId == "reply-1")
    }

    // A refused send must leave the inquiry exactly as it was: still showing their reply, still
    // offering the action, with nothing looking answered that was not.
    @Test("a refused send leaves it still needing an answer")
    func aRefusedSendChangesNothing() async throws {
        let ctx = ModelContext(try container())
        let inq = repliedTo(ctx)
        let before = inq.sentAt

        let result = await InquiryMutations.sendReply(
            inq, subject: "s", body: "b", now: Date(timeIntervalSince1970: 3_000),
            sender: FailingSender(), context: ctx, feedback: ActionFeedback())

        #expect(result == .sendFailed)
        #expect(inq.replied, "they still await an answer")
        #expect(inq.sentAt == before)
        #expect(inq.dismissedReplyId == nil)
    }

    // The first reply still behaves exactly as it did: nothing to mark handled, and the same stamps.
    @Test("the first reply is unchanged by this")
    func theFirstReplyStillWorks() async throws {
        let ctx = ModelContext(try container())
        let fresh = Inquiry(source: .directEmail, inquirerName: "Bob", inquirerEmail: "bob@x.org",
                            eventName: "Recital")
        ctx.insert(fresh)
        let now = Date(timeIntervalSince1970: 5_000)

        let result = await InquiryMutations.sendReply(
            fresh, subject: "s", body: "b", now: now,
            sender: StubSender(receipt: SentReceipt(threadId: "th-9", messageID: "m-9")),
            context: ctx, feedback: ActionFeedback())

        #expect(result == .sent)
        #expect(fresh.sentAt == now)
        #expect(fresh.gmailThreadId == "th-9")
        #expect(fresh.dismissedReplyId == nil)
    }
}
