import Testing
import Foundation
import SwiftData

// #3927: an answer to a hire inquiry started from "Re: your inquiry" whatever the conversation it was
// threaded onto was actually called. The headers said "this belongs to that conversation" and the
// subject said otherwise, and Spark files a message whose subject differs from its conversation's as a
// new conversation whatever its headers say. #3891 fixed the same thing for a scouted show's answer.
//
// The cause was that an inquiry recorded no subject for its conversation at all, so there was nothing to
// continue. It now records one where the conversation becomes known to it (Dan's own send and the attach
// of a conversation found in Gmail), the detach takes it back, and the answer continues it through the
// same "Re:" rule a show's answer uses.
private let me = "dan@danwrightphotography.com"
private let gmail = GmailFixture(selfEmail: me, threadId: "thread-1")

@MainActor
@Suite("An answer to an inquiry continues its conversation's subject (#3927)")
struct InquiryAnswerContinuesItsSubjectTests {
    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let them = "priya.raman@example.com"

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func inquiry(_ ctx: ModelContext) -> Inquiry {
        let i = Inquiry(source: .directEmail, inquirerName: "Priya Raman", inquirerEmail: them,
                        eventName: "Spring gala", createdAt: now.addingTimeInterval(-4 * 86_400))
        ctx.insert(i)
        return i
    }

    // They wrote, Dan answered in Gmail, they wrote again. The oldest message carries the name the
    // conversation goes by.
    private func answeredInGmail(firstSubject: String? = "Photography for our spring gala") -> Data {
        let base = Int64(now.timeIntervalSince1970) * 1000
        return gmail.thread([
            .init(from: "Priya Raman <\(them)>", subject: firstSubject, messageID: "<first@mail.gmail.com>",
                  id: "m1", internalDateMillis: base - 4 * 86_400_000),
            .init(from: "Dan Wright <\(me)>", subject: "Re: Photography for our spring gala",
                  messageID: "<mine@mail.gmail.com>", id: "m2", internalDateMillis: base - 3 * 86_400_000),
            .init(from: "Priya Raman <\(them)>", subject: "Re: Photography for our spring gala",
                  messageID: "<second@mail.gmail.com>", id: "m3", internalDateMillis: base - 3_600_000),
        ])
    }

    // MARK: - the defect

    // The whole issue in one test: a conversation found in Gmail, answered from Overture. The subject on
    // the mail that leaves is the conversation's, not "Re: your inquiry".
    @Test func anAnswerOnAnAttachedConversationContinuesItsSubject() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        _ = AttachConversation.attach(threadId: "thread-1", threadJSON: answeredInGmail(), to: i,
                                      selfEmail: me, now: now)
        let sender = SubjectCapturingSender()
        let c = ReplyComposition.answering(i, context: ctx, feedback: ActionFeedback(), sender: sender)

        #expect(c.editableSubject == "Re: Photography for our spring gala")
        // The sheet hands back what the field holds, which starts at `editableSubject`.
        #expect(await c.send("Thursday works.", c.editableSubject))
        #expect(sender.sent?.subject == "Re: Photography for our spring gala")
        #expect(sender.sent?.threadId == "thread-1")
    }

    // What he approves is the subject that ships (L64), including on the path where the sheet hands back
    // no subject at all.
    @Test func theConfirmationShowsTheSameSubject() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.gmailThreadId = "thread-1"
        i.conversationSubject = "Photography for our spring gala"
        let c = ReplyComposition.answering(i, context: ctx, feedback: ActionFeedback())

        #expect(c.confirmation("Thursday works.", nil)?.subject == "Re: Photography for our spring gala")
        #expect(c.confirmation("Thursday works.", c.editableSubject)?.subject
                == "Re: Photography for our spring gala")
    }

    // One "Re:", through the same rule the show path uses, never "Re: Re:".
    @Test func aSubjectAlreadyCarryingReIsNotPrefixedTwice() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        i.gmailThreadId = "thread-1"
        i.conversationSubject = "RE: Photography for our spring gala"
        #expect(InquiryReplySender.replySubject(for: i) == "RE: Photography for our spring gala")
    }

    // "Re: your inquiry" survives only where there is nothing to continue.
    @Test func anInquiryWithNoConversationStillStartsFromTheDefault() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        #expect(InquiryReplySender.replySubject(for: i) == InquiryCopy.replySubjectDefault)
        i.conversationSubject = "   "
        #expect(InquiryReplySender.replySubject(for: i) == InquiryCopy.replySubjectDefault)
    }

    // MARK: - the writers

    @Test func theAttachRecordsTheConversationsOwnSubject() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        _ = AttachConversation.attach(threadId: "thread-1", threadJSON: answeredInGmail(), to: i,
                                      selfEmail: me, now: now)
        #expect(i.conversationSubject == "Photography for our spring gala")
    }

    // A first message with no Subject header gives nothing to record, and nothing is invented.
    @Test func aThreadWithNoSubjectRecordsNone() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let base = Int64(now.timeIntervalSince1970) * 1000
        let bare = gmail.thread([.init(from: "Priya Raman <\(them)>", subject: nil,
                                       messageID: "<first@mail.gmail.com>", id: "m1",
                                       internalDateMillis: base - 3_600_000)])
        _ = AttachConversation.attach(threadId: "thread-1", threadJSON: bare, to: i, selfEmail: me, now: now)
        #expect(i.conversationSubject == nil)
        #expect(InquiryReplySender.replySubject(for: i) == InquiryCopy.replySubjectDefault)
    }

    // Dan's own send names the conversation it starts, so his second answer continues his first.
    @Test func aSentAnswerRecordsTheSubjectItWentOutUnder() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        let sender = SubjectCapturingSender()
        #expect(await InquiryReplySender.sendReply(i, subject: "Your spring gala", body: "b", now: now,
                                                   sender: sender))
        #expect(i.conversationSubject == "Your spring gala")
        #expect(InquiryReplySender.replySubject(for: i) == "Re: Your spring gala")

        // The issue names the FIRST send as the writer: a later answer does not rename the conversation.
        #expect(await InquiryReplySender.sendReply(i, subject: "Something else", body: "b2", now: now,
                                                   sender: sender))
        #expect(i.conversationSubject == "Your spring gala")
    }

    // A send that failed started no conversation, so it names none (L12).
    @Test func aFailedSendRecordsNoSubject() async throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        #expect(!(await InquiryReplySender.sendReply(i, subject: "Your spring gala", body: "b", now: now,
                                                     sender: FailingSubjectSender())))
        #expect(i.conversationSubject == nil)
    }

    // The detach takes the subject back with the conversation it names, or the next answer on this
    // inquiry would continue a conversation it is no longer on (L38).
    @Test func detachingTakesTheSubjectBack() throws {
        let ctx = ModelContext(try container())
        let i = inquiry(ctx)
        _ = AttachConversation.attach(threadId: "thread-1", threadJSON: answeredInGmail(), to: i,
                                      selfEmail: me, now: now)
        guard case .detached = DetachConversation.detach(i, now: now.addingTimeInterval(60),
                                                         omniFocusEnabled: false) else {
            Issue.record("the attached inquiry could not be detached")
            return
        }
        #expect(i.conversationSubject == nil)
        #expect(InquiryReplySender.replySubject(for: i) == InquiryCopy.replySubjectDefault)
    }
}

private final class SubjectCapturingSender: MailSender, @unchecked Sendable {
    var sent: OutgoingMail?
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        sent = mail
        return SentReceipt(threadId: "thread-1", messageID: "<ours@mail.gmail.com>")
    }
}

private struct FailingSubjectSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt { throw MailSenderError.notConfigured }
}
