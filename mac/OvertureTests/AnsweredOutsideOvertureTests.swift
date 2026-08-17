import Testing
import Foundation
import SwiftData

// #2865. Dan reads a reply in his mail client and answers it there. Overture never learns, so the
// Reached out row goes on reading "waiting since <the day they wrote>" for the life of the row, and the
// Answer control goes on offering itself, about work he finished days earlier.
//
// `replyHandledAt` had three writers and every one was an act performed INSIDE Overture. A completion
// flag whose only writers are inside the product is permanently wrong for anyone who does the work in
// the tool that work actually lives in (L162), and the material to fix it was already on hand:
// detection re-reads the watched thread on every pass and never asked it.
//
// Every test here drives `GmailReplyChecker.markReplies`, so the thread comes from `threadsToCheck` and
// not from the test. That is deliberate: the same rule stated one guard too late would never execute for
// the rows it exists for, while passing any test that hands the detector its own thread. That has now
// happened three times in this area (#2196, #2815, and the placement question in this issue), so the
// entry point is the thing under test.
//
// The people and the words below are invented. Nothing here is anybody's real conversation.
@MainActor
@Suite("An answer Dan sent outside Overture (#2865)")
struct AnsweredOutsideOvertureTests {
    private static let me = "dan@danwrightphotography.com"
    private static let them = "priya.raman@example.com"
    private static let colleague = "wren.holloway@example.com"

    private let heFirstWrote = Date(timeIntervalSince1970: 1_000)
    private let theyWrote = Date(timeIntervalSince1970: 5_000)
    private let heAnsweredInGmail = Date(timeIntervalSince1970: 9_000)
    private let now = Date(timeIntervalSince1970: 30_000)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Fernbrook Players", discipline: "theatre",
                         venue: "Willow Street Playhouse", performanceDate: "2026-11-14",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect, _ address: String = them, thread: String = "t") -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .presenter)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.gmailMessageId = "msg-\(address)"
        r.gmailThreadId = thread
        r.sendGroupId = thread
        p.addRecipient(r)
        return r
    }

    // MARK: - Threads, as Gmail's `threads.get` returns them

    private enum Who { case dan, them }

    private static func message(_ id: String, from who: Who, at sentAt: Date, text: String,
                                headers extra: [(String, String)] = []) -> String {
        let body = Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let from = who == .dan ? me : "Priya Raman <\(them)>"
        let to = who == .dan ? them : me
        let headers = ([("From", from), ("To", to)] + extra)
            .map { #"{"name":"\#($0.0)","value":"\#($0.1)"}"# }
            .joined(separator: ",")
        return """
        {"id":"\(id)","internalDate":"\(Int(sentAt.timeIntervalSince1970) * 1000)",
         "payload":{"headers":[\(headers)],"mimeType":"text/plain","body":{"data":"\(body)"}}}
        """
    }

    private static func thread(_ messages: [String]) -> Data {
        Data("{\"messages\":[\(messages.joined(separator: ","))]}".utf8)
    }

    // Overture's send, then their reply. Nothing of his since.
    private var stillWaiting: Data {
        Self.thread([
            Self.message("m-0", from: .dan, at: Date(timeIntervalSince1970: 1_000), text: "My pitch."),
            Self.message("r-1", from: .them, at: theyWrote, text: "Interesting, what's your rate?"),
        ])
    }

    // The same conversation with his answer on the end, sent from his mail client.
    private func answeredInGmail(headers: [(String, String)] = []) -> Data {
        Self.thread([
            Self.message("m-0", from: .dan, at: Date(timeIntervalSince1970: 1_000), text: "My pitch."),
            Self.message("r-1", from: .them, at: theyWrote, text: "Interesting, what's your rate?"),
            Self.message("m-1", from: .dan, at: heAnsweredInGmail,
                         text: "It's $250 an hour plus tax, and I deliver within two weeks.",
                         headers: headers),
        ])
    }

    private final class StubGmail {
        var body: Data
        private(set) var requestedThreadIds: [String] = []
        init(body: Data) { self.body = body }
        var fetch: (URLRequest) async throws -> (Data, URLResponse) {
            { req in
                let url = req.url!
                if let id = url.path.split(separator: "/").last { self.requestedThreadIds.append(String(id)) }
                return (self.body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                                   headerFields: nil)!)
            }
        }
    }

    @discardableResult
    private func check(_ ctx: ModelContext, thread: Data, at when: Date) async -> StubGmail {
        let gmail = StubGmail(body: thread)
        await GmailReplyChecker(fromEmail: Self.me)
            .markReplies(in: ctx, token: "tok", now: when, fetch: gmail.fetch)
        return gmail
    }

    // The state this issue is about, reached through the shipping pipeline: they wrote, he has not
    // answered through Overture.
    private func waitingOnHim(_ ctx: ModelContext) async throws -> (Prospect, Recipient) {
        let p = show(ctx)
        let r = contact(p)
        await check(ctx, thread: stillWaiting, at: theyWrote)
        return (p, r)
    }

    // MARK: - The premise, measured rather than assumed (L1)

    @Test func thePremiseHolds_theRowIsAskingBeforeAnyAnswer() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = try await waitingOnHim(ctx)

        #expect(r.replied)
        #expect(r.hasUnhandledReply, "they wrote and nothing has answered")
        #expect(r.replyHandledAt == nil)
        #expect(r.replyWatchConversationIsOpen)
    }

    // MARK: - The defect

    @Test func hisAnswerFromTheMailClientClearsTheRow() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = try await waitingOnHim(ctx)

        let gmail = await check(ctx, thread: answeredInGmail(), at: now)

        #expect(gmail.requestedThreadIds.contains("t"),
                "the thread of a live conversation has to be ASKED for, or this can never see the answer")
        #expect(!r.hasUnhandledReply, "he answered it, in Gmail, and the row must stop asking")
    }

    // Dated by the message, never by the pass that noticed it. Stamping `now` would date an answer that
    // went last Tuesday as today's, which is a record about the past taking its value from the present
    // (L37), and every surface reading the gap between their message and his would then be wrong.
    @Test func theAnswerIsDatedByTheMessageNotByTheCheck() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = try await waitingOnHim(ctx)

        await check(ctx, thread: answeredInGmail(), at: now)

        #expect(r.replyHandledAt == heAnsweredInGmail)
        #expect(r.replyHandledAt != now)
    }

    // #463: `sentReplyBody` and `replySentAt` mean "the words Dan committed through Overture" and feed
    // the voice pair. A message sent from a mail client supplies neither, so this records the answered
    // FACT and nothing else, exactly as a peer's record does.
    @Test func itNeverClaimsWordsOvertureDidNotSend() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = try await waitingOnHim(ctx)

        await check(ctx, thread: answeredInGmail(), at: now)

        #expect(r.sentReplyBody == nil)
        #expect(r.replySentAt == nil)
    }

    // MARK: - What must NOT clear it

    // The one thing his own mailbox emits by itself, on exactly the threads this runs over. Reading it as
    // an answer would take a row that genuinely IS waiting on him off every surface that could say so,
    // which is the wrong direction to fail in (L42).
    @Test(arguments: [[("Auto-Submitted", "auto-replied")],
                      [("Auto-Submitted", "auto-generated")],
                      [("X-Autoreply", "yes")],
                      [("X-Autorespond", "yes")],
                      [("Precedence", "auto_reply")]])
    func anAutomatedSendFromHisOwnAddressIsNotAnAnswer(_ headers: [(String, String)]) async throws {
        let ctx = ModelContext(try container())
        let (_, r) = try await waitingOnHim(ctx)

        await check(ctx, thread: answeredInGmail(headers: headers), at: now)

        #expect(r.hasUnhandledReply, "an out of office is not an answer: \(headers)")
        #expect(r.replyHandledAt == nil)
    }

    // The control for the five above, in the same fixture: a message with an ordinary
    // `Auto-Submitted: no`, which is what the standard says a person's own send carries, still counts.
    // Without it the refusal could be "any header at all stops it" (L159).
    @Test func aMessageDeclaringItselfNotAutomatedStillCounts() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = try await waitingOnHim(ctx)

        await check(ctx, thread: answeredInGmail(headers: [("Auto-Submitted", "no")]), at: now)

        #expect(!r.hasUnhandledReply)
    }

    // Overture's OWN pitch is a message from him on this thread, and it went BEFORE they wrote. Reading
    // any message of his as an answer would clear every row the instant the first reply arrived.
    @Test func hisOriginalSendIsNotAnAnswerToAReplyThatCameAfterIt() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = try await waitingOnHim(ctx)

        // His pitch is on the thread, and it is older than their reply, so the newest message is theirs.
        await check(ctx, thread: stillWaiting, at: now)

        #expect(r.hasUnhandledReply)
        #expect(r.replyHandledAt == nil)
    }

    // No record of when THEIRS arrived is no evidence that his came after it, so it is refused and the
    // row keeps asking. Reached through the pipeline, on a row whose reply predates the fields that date
    // it, which is what an older stored row looks like.
    @Test func aReplyWithNoArrivalTimeIsNotClearedByAMessageOfHis() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = try await waitingOnHim(ctx)
        r.repliedAt = nil
        r.inboundReplySentAt = nil
        #expect(r.replyArrivedAt == nil, "the state this test is about")

        await check(ctx, thread: answeredInGmail(), at: now)

        #expect(r.hasUnhandledReply, "nothing can show his message came after theirs, so it is refused")
    }

    // The comparison itself, driven directly, because the ordering the pipeline enforces means a thread
    // whose newest message is his ALWAYS carries it after theirs: the only way to reach a non-strict
    // comparison is to ask the rule. Without this the `>` could be `>=` and nothing would notice.
    @Test func aMessageSentAtTheSameInstantAsTheirsIsNotAnAnswerToIt() {
        let sameInstant = Date(timeIntervalSince1970: 5_000)
        let thread = Self.thread([
            Self.message("r-1", from: .them, at: sameInstant, text: "What's your rate?"),
            Self.message("m-1", from: .dan, at: sameInstant, text: "Crossed in the post."),
        ])

        #expect(AnsweredElsewhere.answeredAt(threadJSON: thread, selfEmail: Self.me,
                                             theirMessageArrivedAt: sameInstant) == nil)
        #expect(AnsweredElsewhere.answeredAt(threadJSON: thread, selfEmail: Self.me,
                                             theirMessageArrivedAt: nil) == nil)
        // The control: one second later and it IS an answer, so the refusals above are about the
        // comparison rather than about this fixture being unreadable (L159).
        #expect(AnsweredElsewhere.answeredAt(threadJSON: thread, selfEmail: Self.me,
                                             theirMessageArrivedAt: sameInstant.addingTimeInterval(-1))
                == sameInstant)
    }

    // MARK: - The conversation, not one mailbox (#2191)

    @Test func aColleagueOnTheSameReplyIsClearedToo() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let her = contact(p)
        let him = contact(p, Self.colleague)
        await check(ctx, thread: stillWaiting, at: theyWrote)
        #expect(her.hasUnhandledReply && him.hasUnhandledReply, "both are on the one reply")

        await check(ctx, thread: answeredInGmail(), at: now)

        #expect(!her.hasUnhandledReply)
        #expect(!him.hasUnhandledReply, "an answer clears the conversation, not one mailbox")
    }

    // MARK: - Repeating, not one-shot

    // The stamp is written once and then left alone. Rewriting it with the same value on every pass would
    // be a write per contact per check for the life of the conversation.
    @Test func aLaterPassDoesNotRewriteTheStamp() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = try await waitingOnHim(ctx)
        await check(ctx, thread: answeredInGmail(), at: now)
        let first = r.replyHandledAt

        await check(ctx, thread: answeredInGmail(), at: now.addingTimeInterval(10_000))

        #expect(r.replyHandledAt == first)
    }

    // And a stamp already recorded by an in-app send is not moved BACKWARDS by an older message on the
    // thread, which is the same rule `markReplyAnswered` already enforces.
    @Test func anEarlierMessageDoesNotUndoALaterAnswer() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = try await waitingOnHim(ctx)
        let laterInApp = now.addingTimeInterval(50_000)
        AnsweredReply.record(on: r, in: p, now: laterInApp)

        await check(ctx, thread: answeredInGmail(), at: now)

        #expect(r.replyHandledAt == laterInApp)
    }

    // MARK: - The placement, which is the thing that has gone wrong three times here

    // The rows this issue is about have NO new reply id: they replied once, he answered elsewhere, and
    // nothing has happened since. So they take the `alreadyReplied` guard's `continue` on every pass, and
    // a check written after that guard would never run for them while passing every test that hands the
    // detector its own thread (L3). Held by a source guard because the ordering is the claim.
    @Test func theCheckRunsBeforeTheGuardThatSkipsAnAlreadyRepliedContact() throws {
        let source = SourceGuardHelper.source("Overture/Integration/ReplyService.swift")
        guard let body = SourceGuardHelper.bodyOfFunction(named: "detectReplies", in: source) else {
            Issue.record("detectReplies not found in ReplyService")
            return
        }
        guard let check = body.range(of: "AnsweredElsewhere.answeredAt("),
              let guardStart = body.range(of: "if alreadyReplied {") else {
            Issue.record("expected both the answered check and the alreadyReplied guard in detectReplies")
            return
        }
        #expect(check.lowerBound < guardStart.lowerBound,
                "the answered check has to run before the guard that skips these very rows")
    }
}
