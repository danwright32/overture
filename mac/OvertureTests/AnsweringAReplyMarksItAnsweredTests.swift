import Testing
import Foundation
import SwiftData

// #2170. Dan answered Nicole Becker's reply on The Pumpkin Singalong at 6:49pm on 2026-08-05. Two hours
// later the row still carried an Answer button, as though he had never replied.
//
// Nothing in the model meant "Dan answered this". `hasUnhandledReply` read replied && no resolution &&
// not bounced, and neither path that records an answer touched any of the three, so the control went on
// offering itself after it had been pressed and succeeded (L44) and the row stated something its own data
// disproved (L11).
//
// Both writers had the hole, which is why the fix is one shared routine and not a patch on the in-app
// send: answering by copying the draft into Gmail looks exactly like the bug being reported (L30).
@MainActor
@Suite("Answering a reply marks it answered (#2170)")
struct AnsweringAReplyMarksItAnsweredTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "The Pumpkin Singalong at Sakura Park",
                         discipline: "choral", venue: "Sakura Park", performanceDate: "2026-10-31",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private let theyWrote = Date(timeIntervalSince1970: 5_000)
    private let heAnswered = Date(timeIntervalSince1970: 9_000)

    @discardableResult
    private func awaitingAnAnswer(_ p: Prospect, _ address: String = "chelsea@everyvoicechoirs.org") -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .act)
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailMessageId = "msg"
        r.gmailThreadId = "t"
        r.replied = true
        r.repliedAt = theyWrote
        r.inboundReplySentAt = theyWrote
        r.replyAudience = [address]
        r.replyDraftBody = "Tuesday works, I will bring the 85mm."
        p.addRecipient(r)
        return r
    }

    // The premise, checked rather than assumed: this row really does offer the button before anything is
    // answered. Without this the tests below could pass on a row that was never answerable (L1).
    @Test func thePremiseHolds_anUnansweredReplyOffersTheButton() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = awaitingAnAnswer(p)
        #expect(r.hasUnhandledReply)
        #expect(ReplyPanel.isOffered(for: r, in: p))
    }

    // 1. The in-app send.
    @Test func answeringInTheAppClearsTheAnswerButton() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = awaitingAnAnswer(p)

        let sent = await ReplyPanel.commit(body: "Tuesday works.", on: r, of: p,
                                           now: heAnswered, sender: FakeSender())
        #expect(sent)
        #expect(!r.hasUnhandledReply)
        #expect(!ReplyPanel.isOffered(for: r, in: p))
    }

    // 2. The copy-out path, which is the harder case to notice because it looks exactly like the bug.
    @Test func answeringByCopyingIntoGmailClearsItToo() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = awaitingAnAnswer(p)

        r.recordAnswerSent(now: heAnswered)

        #expect(!r.hasUnhandledReply)
        #expect(!ReplyPanel.isOffered(for: r, in: p))
    }

    // 3. The failure path. A send that throws must leave the row exactly as answerable as it was: nothing
    // may mark a reply handled over an answer that did not go (L12).
    @Test func aSendThatFailedLeavesItStillNeedingAnAnswer() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = awaitingAnAnswer(p)

        let sent = await ReplyPanel.commit(body: "Tuesday works.", on: r, of: p,
                                           now: heAnswered, sender: AlwaysFails())
        #expect(sent == false)
        #expect(r.hasUnhandledReply, "a refused send must never look like an answer")
        #expect(ReplyPanel.isOffered(for: r, in: p))
    }

    // 4. They write again. A newer inbound reply re-opens it, or the second half of a conversation could
    // never be answered from the queue at all.
    //
    // This one sets the arrival time by hand, so it proves the MODEL reopens and nothing more. For two
    // months nothing in the shipping pipeline performed that write and this still read as full coverage
    // of the rule (L3, #2196). `ASecondReplyReachesDanTests` is the pipeline half: keep both.
    @Test func aNewReplyAfterTheAnswerMakesItAnswerableAgain() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = awaitingAnAnswer(p)
        r.recordAnswerSent(now: heAnswered)
        #expect(!r.hasUnhandledReply)

        // She writes again an hour later.
        r.inboundReplySentAt = heAnswered.addingTimeInterval(3_600)
        r.repliedAt = heAnswered.addingTimeInterval(3_600)

        #expect(r.hasUnhandledReply, "they have written again since he answered")
        #expect(ReplyPanel.isOffered(for: r, in: p))
    }

    // And a reply that arrived BEFORE the answer does not re-open it, which is the same message being
    // re-read rather than a new one.
    @Test func theSameReplyReReadDoesNotReopenIt() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = awaitingAnAnswer(p)
        r.recordAnswerSent(now: heAnswered)
        r.repliedAt = theyWrote     // unchanged: still the message he already answered
        #expect(!r.hasUnhandledReply)
    }

    // 5. Answering is not closing. Dan's decision, 2026-08-05: the show STAYS in Reached out asking him
    // where the conversation stands, and leaves only when he says it is booked, closed or declined.
    @Test func theShowStaysInReachedOutAfterBeingAnswered() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = awaitingAnAnswer(p)
        r.recordAnswerSent(now: heAnswered)

        #expect(r.resolution == nil, "answering must never quietly close the conversation")
        let next = ReachedOutQueue.nextReachOut(for: r, of: p, now: heAnswered)
        #expect(next != nil, "the row must still be in the reached-out queue")
    }

    // But it is no longer PRESSURE. It stops being due the moment he answers, and comes back later asking
    // where things stand, so the queue is not permanently gold over a conversation he has just replied to.
    @Test func answeringClearsTheDuePressureWithoutRemovingTheRow() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = awaitingAnAnswer(p)

        let beforeAnswer = try #require(ReachedOutQueue.nextReachOut(for: r, of: p, now: heAnswered))
        #expect(ReachedOutQueue.isDueNow(next: beforeAnswer, now: heAnswered),
                "an unanswered reply is due now")

        r.recordAnswerSent(now: heAnswered)

        let afterAnswer = try #require(ReachedOutQueue.nextReachOut(for: r, of: p, now: heAnswered))
        #expect(!ReachedOutQueue.isDueNow(next: afterAnswer, now: heAnswered),
                "answering clears the pressure")
        #expect(afterAnswer > heAnswered)
    }

    // #2397: with the states retired, answering is the whole of it. The reply stops being work Dan owes,
    // and the row keeps its place in the queue on the tracks that remain (the nudge sequence, and the
    // post-event prompt once the date passes) rather than on a cadence he had to set by hand.
    @Test func answeringIsTheWholeOfItNowThatThereIsNoStateToSet() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = awaitingAnAnswer(p)

        r.recordAnswerSent(now: heAnswered)

        #expect(!r.hasUnhandledReply)
        #expect(!p.hasUnhandledReply, "and the show agrees, from the one predicate")
    }
}

private struct FakeSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        SentReceipt(threadId: "t", messageID: "m-sent")
    }
}

private struct AlwaysFails: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt { throw MailSenderError.notConfigured }
}
