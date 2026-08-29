import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let secondMessageGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com", threadId: "t")
// #2815. A second message arriving on a conversation that has already recorded a reply is never fetched,
// so it never reaches Dan.
//
// #2196's fix landed in the DETECTOR and never reached the FETCHER. `ReplyService.detectReplies` re-reads
// an already-replied contact for as long as its conversation is open, but it reads whatever `fetchThread`
// hands it, and `GmailReplyChecker.markReplies` hands it only the threads `threadsToCheck` collected. That
// collection kept a replied row only while `ReplyGap.needsFilling` was true, and the gap closes on the very
// pass that records the first reply, so the thread was never pulled again. The detector was willing and the
// fetcher never supplied it, which means the case #2196 was filed for could not occur in production at all
// (L3, L16, L70).
//
// Every test here drives `GmailReplyChecker.markReplies`, so the thread comes from `threadsToCheck` and not
// from the test. `ASecondReplyReachesDanTests` injects the thread directly, which is exactly what the
// shipping pipeline stops doing, so it cannot see this and passed throughout.
//
// The people and the words below are invented. Nothing here is anybody's real conversation.
@MainActor
@Suite("A second message on an answered conversation is fetched (#2815)")
struct ASecondMessageIsFetchedTests {
    private static let me = "dan@danwrightphotography.com"
    private static let them = "marion.alcott@example.com"
    private let theyWrote = Date(timeIntervalSince1970: 5_000)
    private let heAnswered = Date(timeIntervalSince1970: 9_000)
    private let theyWroteAgain = Date(timeIntervalSince1970: 20_000)
    private let now = Date(timeIntervalSince1970: 30_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Harborlight Chorale", discipline: "choral",
                         venue: "Rivercrest Hall", performanceDate: "2026-10-31", sourceListingURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect, thread: String = "t") -> Recipient {
        let r = Recipient(id: Self.them, email: Self.them, provenance: .presenter)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.gmailMessageId = "msg"
        r.gmailThreadId = thread
        r.sendGroupId = thread
        p.addRecipient(r)
        return r
    }

    // One Gmail thread as `threads.get` returns it. `internalDate` is what orders the messages.
    private static func thread(replies: [(id: String, sentAt: Date, text: String)]) -> Data {
        secondMessageGmail.thread(
            [GmailFixture.Message(from: me, to: them, id: "m-0", internalDateMillis: 1000)]
            + replies.map { r in
                .init(from: "Marion Alcott <\(them)>", to: me, id: r.id,
                      internalDateMillis: Int64(r.sentAt.timeIntervalSince1970) * 1000, text: r.text)
            })
    }

    // The shape that matters is WHEN each message lands, not what it says: one before Dan's answer, one
    // after it. The words are only here so the text capture has something to capture.
    private var firstOnly: Data {
        Self.thread(replies: [(id: "r-1", sentAt: theyWrote, text: "Thanks for writing, tell me more.")])
    }

    private var bothMessages: Data {
        Self.thread(replies: [
            (id: "r-1", sentAt: theyWrote, text: "Thanks for writing, tell me more."),
            (id: "r-2", sentAt: theyWroteAgain, text: "One more question before we decide.")
        ])
    }

    // A recording fetch: what the checker actually asked Gmail for, so a test can tell "the thread was
    // pulled and held nothing new" apart from "the thread was never pulled". Those are the two states
    // this whole issue is about and they are indistinguishable from the row alone (L98).
    private final class RecordingGmail {
        var body: Data
        var status: Int
        private(set) var requestedThreadIds: [String] = []

        init(body: Data, status: Int = 200) {
            self.body = body
            self.status = status
        }

        var fetch: (URLRequest) async throws -> (Data, URLResponse) {
            { req in
                let url = req.url!
                // .../threads/<id>?format=...
                if let id = url.path.split(separator: "/").last { self.requestedThreadIds.append(String(id)) }
                return (self.status == 200 ? self.body : Data(),
                        HTTPURLResponse(url: url, statusCode: self.status, httpVersion: nil,
                                        headerFields: nil)!)
            }
        }
    }

    // The state this issue is about, reached entirely through the shipping pipeline: the checker finds the
    // first message, Dan answers it.
    private func answeredConversation(_ ctx: ModelContext) async throws -> (Prospect, Recipient) {
        let p = show(ctx)
        let r = contact(p)
        let gmail = RecordingGmail(body: firstOnly)
        await GmailReplyChecker(fromEmail: Self.me)
            .markReplies(in: ctx, token: "tok", now: theyWrote, fetch: gmail.fetch)
        AnsweredReply.record(on: r, in: p, now: heAnswered)
        return (p, r)
    }

    // The premise, measured rather than assumed. If any of this is untrue the tests below would pass for
    // reasons unrelated to the defect (L1).
    @Test func thePremiseHolds_theFirstMessageIsFoundTheGapClosesAndTheRowGoesQuiet() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = try await answeredConversation(ctx)

        #expect(r.replied)
        #expect(r.lastReplyId == "r-1")
        #expect(!r.hasUnhandledReply, "he answered it, so the row is quiet")
        #expect(!ReplyGap.needsFilling(r),
                "the writer and the words are both recorded, which is the state that stopped the refetch")
        #expect(r.replyWatchConversationIsOpen, "nothing has closed this conversation out")
    }

    // The defect itself, asserted where the blindness lived: the watcher's own entry point, with the
    // thread supplied by `threadsToCheck` rather than by the test.
    @Test func aSecondMessageOnAnAnsweredConversationIsPulledAndReachesHim() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = try await answeredConversation(ctx)

        let gmail = RecordingGmail(body: bothMessages)
        await GmailReplyChecker(fromEmail: Self.me)
            .markReplies(in: ctx, token: "tok", now: now, fetch: gmail.fetch)

        #expect(gmail.requestedThreadIds.contains("t"),
                "the checker has to ASK for the thread of a conversation that is still going")
        #expect(r.lastReplyId == "r-2", "the newest message on it")
        #expect(r.hasUnhandledReply, "he answered, and then they wrote again")
        #expect(r.replyArrivedAt == theyWroteAgain, "dated by the message they actually sent")
        #expect(r.lastReplyText?.contains("One more question") == true,
                "the newest words, not the first ones")
    }

    // The fetch scope's own question, at the level the two predicates meet. An open conversation is
    // collected whether or not it has a gap left to fill.
    @Test func theFetchScopeKeepsAnAnsweredRowWhoseConversationIsStillOpen() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = try await answeredConversation(ctx)

        #expect(!ReplyGap.needsFilling(r), "nothing is missing on this row")
        #expect(GmailReplyChecker.threadsToCheck(in: [p]).contains("t"),
                "and it is still watched, because a NEW message could arrive on it")
    }

    // The bound on that cost, which is what makes the scope safe to widen: a conversation Dan has closed
    // out is not collected at all. Without this the pass would grow with every show he ever pitched.
    @Test func aClosedOutConversationIsNotCollectedAtAll() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = try await answeredConversation(ctx)
        r.resolution = .declinedHard

        #expect(GmailReplyChecker.threadsToCheck(in: [p]).isEmpty)

        let gmail = RecordingGmail(body: bothMessages)
        await GmailReplyChecker(fromEmail: Self.me)
            .markReplies(in: ctx, token: "tok", now: now, fetch: gmail.fetch)

        #expect(gmail.requestedThreadIds.isEmpty, "a closed conversation costs nothing to keep not watching")
        #expect(r.lastReplyId == "r-1")
    }

    // The failure path. Gmail refuses the read, so nothing came back: the row must not be re-dated,
    // re-opened or closed on the strength of an answer that never arrived, and the pass has to SAY the
    // thread was unreadable rather than letting it read as a quiet conversation (L11).
    @Test func aRefusedFetchLeavesTheAnsweredConversationExactlyAsItWas() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = try await answeredConversation(ctx)

        let gmail = RecordingGmail(body: bothMessages, status: 401)
        let outcome = await GmailReplyChecker(fromEmail: Self.me)
            .markReplies(in: ctx, token: "tok", now: now, fetch: gmail.fetch)

        #expect(outcome.threadsChecked == 1, "it was in scope, which is the whole fix")
        #expect(outcome.unreadable == 1, "and Gmail refused, which is not the same as nobody writing")
        #expect(r.lastReplyId == "r-1", "a failed read must not rewrite what is known")
        #expect(r.replyArrivedAt == theyWrote)
        #expect(!r.hasUnhandledReply)
    }

    // The sibling: an inquiry rides the same checker and the same `threadsToCheck`, so it was blind in
    // exactly the same way. Its own open/closed judgement (`Inquiry.isOpen`) is what keeps it watched.
    @Test func anAnsweredInquiryConversationIsWatchedTheSameWay() async throws {
        let ctx = ModelContext(try container())
        let i = Inquiry(source: .directEmail, inquirerName: "Marion Alcott", inquirerEmail: Self.them,
                        eventName: "Winter concert", performanceDate: nil, venue: "Rivercrest Hall",
                        notes: nil, createdAt: Date(timeIntervalSince1970: 1))
        i.gmailThreadId = "t"
        i.gmailMessageId = "msg"
        ctx.insert(i)

        let first = RecordingGmail(body: firstOnly)
        await GmailReplyChecker(fromEmail: Self.me)
            .markReplies(in: ctx, token: "tok", now: theyWrote, fetch: first.fetch)
        #expect(i.replied)
        #expect(!ReplyGap.needsFilling(i), "the gap that used to be the only reason to refetch is closed")
        #expect(i.isOpen)

        let second = RecordingGmail(body: bothMessages)
        await GmailReplyChecker(fromEmail: Self.me)
            .markReplies(in: ctx, token: "tok", now: now, fetch: second.fetch)

        #expect(second.requestedThreadIds.contains("t"))
        #expect(i.lastReplyId == "r-2", "their second message reaches the inquiry row too")
    }
}
