import Testing
import Foundation
import SwiftData

// #2145, step six: the question the issue was actually filed over.
//
// Sharing the SCREEN is the cheap half. The expensive half is whether both halves of the Reached out
// list agree about when Dan is being waited on, because that is what decides whether an answer control
// appears at all. They are two implementations with different bookkeeping: a show stamps when he
// answered and compares it against when their message arrived, while an inquiry clears its replied flag
// on the way out. Written as a comment, that difference enforces nothing and drifts the first time
// either side is touched (L57).
//
// So it is asserted instead: one conversation, walked event by event, with a show and an inquiry side by
// side, and the control's answer compared at every step. The ONE genuine difference is named and pinned
// too, so it cannot quietly become two.
@MainActor
@Suite("A show and an inquiry agree about who is waiting on Dan (#2145)")
struct OneWaitingOnDanRuleTests {
    private struct StubSender: MailSender {
        func send(_ mail: OutgoingMail) async throws -> SentReceipt {
            SentReceipt(threadId: "th-1", messageID: "mid-1")
        }
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "k", groupName: "Every Voice Choirs", discipline: "choral",
                         venue: "Merkin Hall", performanceDate: "2026-10-31", sourceListingURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 8, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: "nbecker@evc.org", email: "nbecker@evc.org", provenance: .act)
        p.addRecipient(r)
        return (p, r)
    }

    private func inquiry(_ ctx: ModelContext) -> Inquiry {
        let i = Inquiry(source: .contactForm, inquirerName: "Marta Reyes",
                        inquirerEmail: "marta@example.org", eventName: "Winter recital")
        ctx.insert(i)
        return i
    }

    // Asked of each entity the way its own surface asks it.
    private func showOffersAnswer(_ r: Recipient, _ p: Prospect) -> Bool {
        ReplyPanel.isOffered(for: r, in: p)
    }
    private func inquiryOffersReply(_ i: Inquiry) -> Bool {
        InquiryMutations.showsReplyAction(sentAt: i.sentAt, hasUnhandledReply: i.hasUnhandledReply,
                                          bounced: i.bounced)
    }

    // The one genuine difference, pinned so it cannot silently become two. An inquiry is somebody
    // WAITING on Dan from the moment he logs it: answering is the whole point and nothing has been sent.
    // A show is the other way round, since he pitches first, so there is nothing to answer yet.
    @Test func beforeAnythingIsSentOnlyTheInquiryIsWaitingOnHim() throws {
        let ctx = ModelContext(try container())
        let (p, r) = show(ctx)
        let i = inquiry(ctx)
        #expect(inquiryOffersReply(i), "a logged inquiry is somebody waiting on an answer")
        #expect(!showOffersAnswer(r, p), "a show has not been pitched yet, so there is nothing to answer")
    }

    // From the send onwards the two must agree at every step, because from there they are the same
    // situation: he wrote to somebody and is waiting to hear.
    @Test func fromTheSendOnwardsTheTwoAgreeAtEveryStep() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = show(ctx)
        let i = inquiry(ctx)
        let sent = Date(timeIntervalSince1970: 1_000)

        // 1. He has written and is waiting on them. Chasing is the follow-up nudge's job, not an answer.
        r.sentAt = sent
        r.sendState = .sent
        r.gmailThreadId = "th-1"
        _ = await InquiryReplySender.sendReply(i, subject: "Re: your inquiry", body: "Happy to help",
                                               now: sent, sender: StubSender())
        #expect(showOffersAnswer(r, p) == false)
        #expect(inquiryOffersReply(i) == false)

        // 2. They write back. Both are now waiting on him.
        let theirs = Date(timeIntervalSince1970: 2_000)
        r.replied = true
        r.repliedAt = theirs
        r.lastReplyText = "Tuesday works."
        i.replied = true
        i.repliedAt = theirs
        i.lastReplyText = "Tuesday works."
        #expect(showOffersAnswer(r, p) == true)
        #expect(inquiryOffersReply(i) == true)

        // 3. He answers. Neither is waiting on him any more, which is the state that used to go on
        // offering itself after the button had been pressed and succeeded (#2170, L44).
        let his = Date(timeIntervalSince1970: 3_000)
        r.recordAnswerSent(now: his)
        _ = await InquiryReplySender.sendReply(i, subject: "Re: your inquiry", body: "Tuesday it is",
                                               now: his, sender: StubSender())
        #expect(showOffersAnswer(r, p) == false)
        #expect(inquiryOffersReply(i) == false)

        // 4. They write AGAIN. Both re-open, or the back half of every conversation would be
        // unanswerable from the queue.
        let theirSecond = Date(timeIntervalSince1970: 4_000)
        r.replied = true
        r.repliedAt = theirSecond
        r.lastReplyText = "One more thing."
        i.replied = true
        i.repliedAt = theirSecond
        i.lastReplyText = "One more thing."
        #expect(showOffersAnswer(r, p) == true)
        #expect(inquiryOffersReply(i) == true)
    }

    // A bounced thread is not somebody waiting on him, on either side.
    //
    // Asserted with the reply flag ALSO set, which is the only shape that tells the two rules apart: with
    // it clear, both answer no for a reason that has nothing to do with the bounce, and the test would
    // pass while proving nothing about bounces at all. A bounce notice arriving on a thread that has been
    // flagged as replied is exactly what the show side guards against.
    @Test func neitherOffersToAnswerABouncedThread() throws {
        let ctx = ModelContext(try container())
        let arrived = Date(timeIntervalSince1970: 2_000)

        let (p, r) = show(ctx)
        r.sentAt = Date(timeIntervalSince1970: 1_000)
        r.sendState = .sent
        r.replied = true
        r.repliedAt = arrived
        r.bounced = true
        #expect(showOffersAnswer(r, p) == false)

        let i = inquiry(ctx)
        i.sentAt = Date(timeIntervalSince1970: 1_000)
        i.replied = true
        i.repliedAt = arrived
        i.bounced = true
        #expect(inquiryOffersReply(i) == false,
                "a bounced inquiry must not offer an answer any more than a bounced show does")
    }
}
