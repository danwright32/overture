import Testing
import Foundation
import SwiftData

// #2943. `Inquiry` had no answered stamp, so both paths that record "Dan has dealt with this" said it by
// clearing `replied`. That does not merely fail to REPORT the exchange the way #2919's half did: it
// destroys it. The row reverted from "They replied" to "Sent, waiting to hear back", identical to an
// inquiry nobody ever wrote back to, and #16's funnel filed a real two way conversation as silence.
//
// L163 in its plainest form: when the model has no field for a fact, never express that fact by negating
// a neighbouring one, because the neighbour goes on being read as its own fact everywhere else.
@MainActor
@Suite("Answering an inquiry keeps the reply on the record (#2943)")
struct AnsweringAnInquiryKeepsTheReplyTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private struct StubSender: MailSender {
        let receipt: SentReceipt
        func send(_ mail: OutgoingMail) async throws -> SentReceipt { receipt }
    }

    // Both ends of every date pair are pinned, so real time cannot walk a fixture into a different case
    // than the one it was written for (L130).
    private func day(_ s: String) -> Date { EasternDate.date(from: s)! }
    // Gmail's own `internalDate`, derived from the SAME pinned day rather than typed as a raw epoch, so a
    // fixture's two ends cannot drift a year apart from each other while both still look deliberate.
    private func millis(_ s: String) -> Int64 { Int64(day(s).timeIntervalSince1970 * 1000) }

    private let selfEmail = "dan@dwphoto.example"

    // An inquiry Dan replied to, which they have since answered.
    private func repliedTo(_ ctx: ModelContext) -> Inquiry {
        let inq = Inquiry(source: .contactForm, inquirerName: "Ada", inquirerEmail: "ada@x.example",
                          eventName: "Gala")
        inq.sentAt = day("2026-08-10")
        inq.gmailThreadId = "th-1"
        inq.gmailMessageId = "m-1"
        inq.replied = true
        inq.repliedAt = day("2026-08-14")
        inq.inboundReplySentAt = day("2026-08-14")
        inq.lastReplyId = "reply-1"
        inq.lastReplyText = "Sounds good, what are your rates?"
        ctx.insert(inq)
        return inq
    }

    // The defect itself, on the path the issue was filed from.
    @Test func answeringAnInquiryDoesNotUnReplyIt() async throws {
        let ctx = ModelContext(try container())
        let inq = repliedTo(ctx)

        let sent = await InquiryReplySender.sendReply(
            inq, subject: "s", body: "b", now: day("2026-08-15"),
            sender: StubSender(receipt: SentReceipt(threadId: "th-1", messageID: "m-2")))

        #expect(sent)
        #expect(inq.replied, "answering erased the evidence that a reply ever arrived (#2943)")
        #expect(inq.repliedAt == day("2026-08-14"), "their message still dates the exchange")
    }

    // The sibling writer, one line away and the same defect: linking a conversation Dan had already
    // answered in Gmail said so by taking the reply back (#2868).
    @Test func linkingAnAlreadyAnsweredConversationDoesNotUnReplyIt() throws {
        let ctx = ModelContext(try container())
        let inq = Inquiry(source: .directEmail, inquirerName: "Bo", inquirerEmail: "bo@x.example",
                          eventName: "Recital")
        ctx.insert(inq)

        let gmail = GmailFixture(selfEmail: selfEmail, threadId: "th-9")
        let thread = gmail.thread([
            .init(from: "bo@x.example", messageID: "<t1>", id: "a",
                  internalDateMillis: millis("2026-08-13")),
            .init(from: selfEmail, messageID: "<t2>", id: "b",
                  internalDateMillis: millis("2026-08-14")),
        ])

        _ = AttachConversation.attach(threadId: "th-9", threadJSON: thread, to: inq,
                                      selfEmail: selfEmail, now: day("2026-08-15"))

        #expect(inq.replied, "linking an answered conversation erased the reply it found (#2943)")
    }

    // #16's funnel. A conversation that genuinely happened must be counted as one, not as a pitch nobody
    // ever answered, which is a confident wrong number rather than a gap (L90).
    @Test func anAnsweredInquiryIsReportedAsAConversation() async throws {
        let ctx = ModelContext(try container())
        let inq = repliedTo(ctx)

        _ = await InquiryReplySender.sendReply(
            inq, subject: "s", body: "b", now: day("2026-08-15"),
            sender: StubSender(receipt: SentReceipt(threadId: "th-1", messageID: "m-2")))

        #expect(InquiryReporting.stage(for: inq) == .inConversation)
        inq.markOutcomeManually(.lostSoft, now: day("2026-09-30"))
        #expect(InquiryReporting.lostAfter(inq) == .conversationDied)
    }

    // What Dan actually reads, through the live row builder rather than by calling the copy directly, so
    // this is the sentence the queue really puts on screen. The SAME words #2919 gave the scouted row,
    // from the same function: the two kinds of row sit in one list under one set of date headings, and
    // one exchange described two ways is the collision that only shows when they are read together (L118).
    @Test func theRowSaysTheReplyArrivedAndWasAnswered() async throws {
        let ctx = ModelContext(try container())
        let inq = repliedTo(ctx)

        _ = await InquiryReplySender.sendReply(
            inq, subject: "s", body: "b", now: day("2026-08-15"),
            sender: StubSender(receipt: SentReceipt(threadId: "th-1", messageID: "m-2")))

        let row = try #require(QueueModel.inquiryRows([inq], now: day("2026-08-18")).first)
        #expect(InquiryCopy.rowState(sentAt: row.sentAt, replied: row.replied,
                                     answeredReplyLine: row.answeredReplyLine)
                    == "Replied Aug 14, you answered Aug 15")
    }

    // The control retires itself, the way the show side's has since #2170. With `replied` no longer
    // cleared, a Reply button keyed on it would go on offering itself after it had been pressed and
    // succeeded (L44).
    @Test func theReplyControlRetiresOnceHeHasAnswered() async throws {
        let ctx = ModelContext(try container())
        let inq = repliedTo(ctx)
        #expect(inq.hasUnhandledReply, "they are waiting on him before he answers")

        _ = await InquiryReplySender.sendReply(
            inq, subject: "s", body: "b", now: day("2026-08-15"),
            sender: StubSender(receipt: SentReceipt(threadId: "th-1", messageID: "m-2")))

        #expect(!inq.hasUnhandledReply)
        #expect(!InquiryMutations.showsReplyAction(sentAt: inq.sentAt,
                                                   hasUnhandledReply: inq.hasUnhandledReply,
                                                   bounced: inq.bounced))
    }

    // And it comes back when they write again, or the back half of every conversation would be
    // unanswerable from the queue. This is why the stamp is COMPARED against their arrival rather than
    // being a plain answered flag.
    @Test func aLaterReplyReopensTheRow() async throws {
        let ctx = ModelContext(try container())
        let inq = repliedTo(ctx)

        _ = await InquiryReplySender.sendReply(
            inq, subject: "s", body: "b", now: day("2026-08-15"),
            sender: StubSender(receipt: SentReceipt(threadId: "th-1", messageID: "m-2")))

        inq.reopenOnReply(at: day("2026-08-17"))
        inq.inboundReplySentAt = day("2026-08-17")
        inq.lastReplyId = "reply-2"

        #expect(inq.hasUnhandledReply, "a newer message is his move again")
        #expect(!inq.replyIsAnswered)
        let row = try #require(QueueModel.inquiryRows([inq], now: day("2026-08-18")).first)
        #expect(InquiryCopy.rowState(sentAt: row.sentAt, replied: row.replied,
                                     answeredReplyLine: row.answeredReplyLine) == "They replied")
    }

    // Answering restarts the wait on THEM, which is the behaviour clearing `replied` used to buy and
    // which the answered stamp has to keep: the row groups under the nudge it is next due for, not under
    // the day they wrote, and the follow-up badge becomes reachable again.
    @Test func answeringRestartsTheNudgeClockRatherThanFreezingTheRow() async throws {
        let ctx = ModelContext(try container())
        let inq = repliedTo(ctx)
        let his = day("2026-08-15")

        _ = await InquiryReplySender.sendReply(
            inq, subject: "s", body: "b", now: his,
            sender: StubSender(receipt: SentReceipt(threadId: "th-1", messageID: "m-2")))

        let due = BusinessDay.advance(his, byBusinessDays: Inquiry.followUpNudgeBusinessDays)
        #expect(inq.nextReachOutDate(now: day("2026-08-16")) == due,
                "it is dated by the nudge his answer restarted, not by the day they wrote")
        #expect(!inq.followUpNudgeDue(now: day("2026-08-16")))
        #expect(inq.followUpNudgeDue(now: day("2026-08-24")), "three business days of silence since")
    }

    // The masthead. The due pill counts rows that are owed something, and an answered inquiry is not one:
    // keyed on `replied` it would have counted this conversation as owing Dan an answer on every launch
    // for the rest of its life.
    @Test func theDuePillStopsCountingAnInquiryHeHasAnswered() async throws {
        let ctx = ModelContext(try container())
        let inq = repliedTo(ctx)

        func due() -> Int {
            AgentInputs.from(prospects: [], allProspects: [], inquiries: [inq],
                             context: .at("2026-08-18", now: day("2026-08-18")),
                             gmailConnected: true, runInFlight: nil, replyRunAlive: false).reachedOutDue
        }
        #expect(due() == 1, "an unanswered reply is somebody waiting on him")

        _ = await InquiryReplySender.sendReply(
            inq, subject: "s", body: "b", now: day("2026-08-15"),
            sender: StubSender(receipt: SentReceipt(threadId: "th-1", messageID: "m-2")))

        #expect(due() == 0)
    }

    // #2865's inquiry half, which had no home until this field existed: the protocol's default is a no-op
    // and named #2868 as where the decision belonged. Dan reading a reply in his mail client and answering
    // it there is the ordinary thing to do, and the row asked forever (L162).
    @Test func answeringFromHisMailClientRetiresTheRowToo() throws {
        let ctx = ModelContext(try container())
        let inq = repliedTo(ctx)
        inq.replyHandledAt = nil

        let gmail = GmailFixture(selfEmail: selfEmail, threadId: "th-1")
        let thread = gmail.thread([
            .init(from: "ada@x.example", messageID: "<r1>", id: "reply-1",
                  internalDateMillis: millis("2026-08-14")),
            .init(from: selfEmail, messageID: "<a1>", id: "answer-1",
                  internalDateMillis: millis("2026-08-16")),
        ])

        _ = ReplyService.detectReplies(in: [inq], selfEmail: selfEmail, now: day("2026-08-18"),
                                       fetchThread: { $0 == "th-1" ? thread : nil })

        #expect(inq.replied, "the reply is still on the record")
        #expect(inq.replyHandledAt != nil, "and his answer, read off the thread, retires it")
        #expect(!inq.hasUnhandledReply)
    }

    // Never backwards, exactly as `Recipient.markReplyAnswered` is not, so an earlier answer arriving out
    // of order cannot undo a later one.
    @Test func theAnsweredStampNeverMovesBackwards() throws {
        let ctx = ModelContext(try container())
        let inq = repliedTo(ctx)

        inq.markReplyAnswered(now: day("2026-08-16"))
        inq.markReplyAnswered(now: day("2026-08-15"))
        #expect(inq.replyHandledAt == day("2026-08-16"))
    }
}
