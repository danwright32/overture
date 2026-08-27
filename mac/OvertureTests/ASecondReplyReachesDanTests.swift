import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let secondReplyGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com", threadId: "t")
// #2196. Somebody writes back. Dan answers. They write again. Overture never told him.
//
// `detectReplies` skipped any contact that had already replied, and that skip was the ONLY route to the
// fields the reopen rule reads. `Recipient.hasUnhandledReply` compares when their message arrived against
// when Dan answered, so with nothing ever moving the arrival forward, `theirs > handled` was false from
// his first answer onwards and could never become true again.
//
// It was invisible until #2170 and #2191, because before those a replied row stayed lit forever: a second
// reply arriving under it changed nothing about what Dan saw. Making the row go quiet once he answers is
// right, and it removed the accident that was covering this.
//
// The existing coverage of the reopen rule
// (`AnsweringAReplyMarksItAnsweredTests.aNewReplyAfterTheAnswerMakesItAnswerableAgain`) sets the arrival
// time by hand, so it proves the MODEL supports reopening while nothing in the shipping pipeline
// performed the write that would trigger it (L3). Every test here drives the real detection pass from a
// fetched thread instead.
@MainActor
@Suite("A second reply on an answered conversation reaches Dan (#2196)")
struct ASecondReplyReachesDanTests {
    private static let me = "dan@danwrightphotography.com"
    private let theyWrote = Date(timeIntervalSince1970: 5_000)
    private let heAnswered = Date(timeIntervalSince1970: 9_000)
    private let theyWroteAgain = Date(timeIntervalSince1970: 20_000)
    private let now = Date(timeIntervalSince1970: 30_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "The Pumpkin Singalong at Sakura Park",
                         discipline: "choral", venue: "Sakura Park", performanceDate: "2026-10-31",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect, _ address: String, thread: String = "t") -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .presenter)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.gmailMessageId = "msg-\(address)"
        r.gmailThreadId = thread
        r.sendGroupId = thread      // one email, so one send group: what #2191's fan-out walks
        p.addRecipient(r)
        return r
    }

    // One thread, seen through Gmail's metadata shape. `sentAt` is Gmail's internalDate in milliseconds.
    private static func thread(replies: [(id: String, from: String, sentAt: Date, text: String)]) -> Data {
        secondReplyGmail.thread(
            [GmailFixture.Message(from: me, to: "chelsea@everyvoicechoirs.org", id: "m-0",
                                  internalDateMillis: 1000)]
            + replies.map { r in
                .init(from: r.from, to: me, id: r.id,
                      internalDateMillis: Int64(r.sentAt.timeIntervalSince1970) * 1000, text: r.text)
            })
    }

    private static let firstOnly = thread(replies: [
        (id: "r-1", from: "chelsea@everyvoicechoirs.org",
         sentAt: Date(timeIntervalSince1970: 5_000), text: "Are you free that night?")
    ])
    private static let bothReplies = thread(replies: [
        (id: "r-1", from: "chelsea@everyvoicechoirs.org",
         sentAt: Date(timeIntervalSince1970: 5_000), text: "Are you free that night?"),
        (id: "r-2", from: "chelsea@everyvoicechoirs.org",
         sentAt: Date(timeIntervalSince1970: 20_000), text: "Our budget is 1,200. Does that work?")
    ])

    // Walk the real path: detection finds the first reply, Dan answers, detection runs again against a
    // thread that now carries a second message.
    private func answeredConversation(_ ctx: ModelContext, addresses: [String] = ["chelsea@everyvoicechoirs.org"])
        -> (Prospect, [Recipient]) {
        let p = show(ctx)
        let rs = addresses.map { contact(p, $0) }
        ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: theyWrote,
                                   fetchThread: { _ in Self.firstOnly },
                                   fetchFullThread: { _ in Self.firstOnly })
        AnsweredReply.record(on: rs[0], in: p, now: heAnswered)
        return (p, rs)
    }

    // The premise, measured rather than assumed: after the walk above the conversation really is quiet,
    // so a test below that finds it loud can only have found the second reply (L1).
    @Test func thePremiseHolds_theFirstReplyIsFoundAndThenGoesQuiet() throws {
        let ctx = ModelContext(try container())
        let (_, rs) = answeredConversation(ctx)
        #expect(rs[0].replied)
        #expect(rs[0].lastReplyId == "r-1")
        #expect(!rs[0].hasUnhandledReply, "he answered it, so it should be quiet")
    }

    // The defect. A second message on a conversation he has answered puts it back in front of him.
    @Test func aSecondReplyPutsTheConversationBackInFrontOfHim() throws {
        let ctx = ModelContext(try container())
        let (p, rs) = answeredConversation(ctx)

        let found = ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: now,
                                               fetchThread: { _ in Self.bothReplies },
                                               fetchFullThread: { _ in Self.bothReplies })

        #expect(found == 1, "the second reply is a reply found")
        #expect(rs[0].hasUnhandledReply, "she wrote again after he answered")
        #expect(ReplyPanel.isOffered(for: rs[0], in: p))
        #expect(rs[0].lastReplyId == "r-2")
        #expect(rs[0].replyArrivedAt == theyWroteAgain, "dated by the message she actually sent")
        #expect(rs[0].lastReplyText?.contains("1,200") == true, "the newest words, not the first ones")
    }

    // The same thread re-read changes nothing. This is what runs on every check for the whole life of a
    // conversation, so getting it wrong would re-open every answered row on a timer.
    @Test func theSameThreadReReadLeavesTheAnsweredConversationQuiet() throws {
        let ctx = ModelContext(try container())
        let (p, rs) = answeredConversation(ctx)

        let found = ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: now,
                                               fetchThread: { _ in Self.firstOnly },
                                               fetchFullThread: { _ in Self.firstOnly })

        #expect(found == 0)
        #expect(!rs[0].hasUnhandledReply, "nothing new arrived")
        #expect(rs[0].replyHandledAt == heAnswered, "his answer must not be walked backwards")
    }

    // A reply Dan said was not real stays not real, even arriving as the newest message on the thread.
    // Walked through the real dismiss, not a hand-set field: detection re-opens on r-2, he says that is
    // not a real reply, and the next check must leave it alone rather than flagging it straight back.
    @Test func aDismissedSecondReplyDoesNotReopenIt() throws {
        let ctx = ModelContext(try container())
        let (p, rs) = answeredConversation(ctx)
        ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: now,
                                   fetchThread: { _ in Self.bothReplies },
                                   fetchFullThread: { _ in Self.bothReplies })
        #expect(rs[0].hasUnhandledReply)

        rs[0].dismissAutoReply()
        #expect(rs[0].dismissedReplyId == "r-2")
        #expect(!rs[0].replied)

        ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: now,
                                   fetchThread: { _ in Self.bothReplies },
                                   fetchFullThread: { _ in Self.bothReplies })

        #expect(!rs[0].replied, "he already said this one was not real")
        #expect(!rs[0].hasUnhandledReply)
    }

    // #2191's fan-out has to survive the second reply, or the two contacts on one conversation disagree
    // about who is waiting: one row lit, its colleague quiet, from the same message.
    @Test func everyContactOnTheThreadReopensTogether() throws {
        let ctx = ModelContext(try container())
        let (p, rs) = answeredConversation(ctx, addresses: ["chelsea@everyvoicechoirs.org",
                                                           "office@everyvoicechoirs.org"])
        #expect(rs.allSatisfy { !$0.hasUnhandledReply }, "the answer reached both of them")

        ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: now,
                                   fetchThread: { _ in Self.bothReplies },
                                   fetchFullThread: { _ in Self.bothReplies })

        #expect(rs.allSatisfy { $0.hasUnhandledReply }, "one message, one conversation, one answer owed")
        #expect(rs.allSatisfy { $0.lastReplyId == "r-2" })
    }

    // A conversation Dan has closed out stays closed. Re-reading it forever would also be a Gmail call
    // per closed conversation on every check, growing with every show he ever pitched.
    @Test func aClosedOutConversationIsNotReReadAtAll() throws {
        let ctx = ModelContext(try container())
        let (p, rs) = answeredConversation(ctx)
        rs[0].resolution = .declinedHard

        var fetches = 0
        ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: now,
                                   fetchThread: { _ in fetches += 1; return Self.bothReplies },
                                   fetchFullThread: { _ in Self.bothReplies })

        #expect(fetches == 0, "a closed conversation costs nothing to keep not watching")
        #expect(!rs[0].hasUnhandledReply)
    }

    // A row that replied before any id was recorded cannot say whether the newest message is new. Adopting
    // it as the baseline is the honest reading; calling an unknown "new" would re-open every such row at
    // once on the first check after this ships, which is the crying-wolf failure (L36).
    @Test func aRowWithNoRecordedReplyIdAdoptsTheIdRatherThanReopening() throws {
        let ctx = ModelContext(try container())
        let (p, rs) = answeredConversation(ctx)
        rs[0].lastReplyId = nil

        ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: now,
                                   fetchThread: { _ in Self.bothReplies },
                                   fetchFullThread: { _ in Self.bothReplies })

        #expect(rs[0].lastReplyId == "r-2", "the baseline is recorded")
        #expect(!rs[0].hasUnhandledReply, "an unknown is not evidence that she wrote again")

        // And the NEXT genuinely new message on it is found normally.
        let third = Self.thread(replies: [
            (id: "r-1", from: "chelsea@everyvoicechoirs.org",
             sentAt: Date(timeIntervalSince1970: 5_000), text: "Are you free that night?"),
            (id: "r-2", from: "chelsea@everyvoicechoirs.org",
             sentAt: Date(timeIntervalSince1970: 20_000), text: "Our budget is 1,200."),
            (id: "r-3", from: "chelsea@everyvoicechoirs.org",
             sentAt: Date(timeIntervalSince1970: 25_000), text: "Any news?")
        ])
        ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: now,
                                   fetchThread: { _ in third }, fetchFullThread: { _ in third })
        #expect(rs[0].hasUnhandledReply)
        #expect(rs[0].lastReplyId == "r-3")
    }

    // The failure path for the fetch itself: Gmail refuses, so nothing comes back. A conversation must
    // never be re-opened, closed, or re-dated on the strength of an answer that never arrived (L11).
    @Test func aThreadThatCouldNotBeFetchedChangesNothing() throws {
        let ctx = ModelContext(try container())
        let (p, rs) = answeredConversation(ctx)

        let found = ReplyService.detectReplies(in: [p], selfEmail: Self.me, now: now,
                                               fetchThread: { _ in nil }, fetchFullThread: { _ in nil })

        #expect(found == 0)
        #expect(!rs[0].hasUnhandledReply)
        #expect(rs[0].lastReplyId == "r-1", "a failed read must not rewrite what is known")
        #expect(rs[0].replyArrivedAt == theyWrote)
    }
}
