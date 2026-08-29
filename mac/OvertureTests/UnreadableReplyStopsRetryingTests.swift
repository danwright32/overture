import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let unreadableReplyGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")
// #2149. #2147 widened the repair gap so a replied row missing its message text is refetched and filled.
// The condition was not self-terminating.
//
// ReplyDetection.latestReplyBody returns nil when the newest real reply has no decodable body, which
// covers an HTML-only or attachment-only message. The row then keeps `lastReplyText == nil`, stays in the
// gap, and its thread is refetched on EVERY reply check from now on with nothing ever changing: a
// permanent no-progress loop against Gmail, invisible from the app, growing by one thread each time a
// reply arrives that cannot be read.
//
// L47: a pass that fails on an item must record the attempt ON that item, or the work is silently
// selected and paid for again forever.
@MainActor
@Suite("An unreadable reply is tried once, not forever (#2149)")
struct UnreadableReplyStopsRetryingTests {
    private let me = "dan@danwrightphotography.com"

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Pumpkin Singalong", discipline: "choral", venue: "V",
                         performanceDate: "2026-10-31", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func repliedRow(_ p: Prospect, _ address: String) -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .act)
        r.gmailThreadId = "t"
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailMessageId = "msg"
        r.replied = true
        p.addRecipient(r)
        return r
    }

    // A reply Overture can see but cannot read: a real sender, and a body in a part it cannot decode.
    // This is the message shape the whole issue is about.
    private func unreadableThread(from: String) -> Data {
        unreadableReplyGmail.thread([
            .init(from: from, to: me, id: "m1", internalDateMillis: 1_754_355_390_000,
                  attachmentOnly: true),
        ])
    }

    private func readableThread(from: String, body: String) -> Data {
        unreadableReplyGmail.thread([
            .init(from: from, to: me, id: "m1", internalDateMillis: 1_754_355_390_000, text: body),
        ])
    }

    // The premise, checked rather than assumed: this really is a message whose body cannot be read. If
    // Gmail's shape or the decoder changed so that it CAN be read, every test below would pass while
    // testing nothing (L1).
    @Test func thePremiseHolds_thisMessageBodyCannotBeRead() {
        let json = unreadableThread(from: "Nicole <nicole@everyvoicechoirs.org>")
        #expect(ReplyDetection.latestReplyBody(threadJSON: json, selfEmail: me) == nil)
        #expect(ReplyDetection.latestReplySender(threadJSON: json, selfEmail: me) != nil,
                "the sender must still be readable, or this is a different failure entirely")
    }

    // The fix. One pass over a message that cannot be read, and the row leaves the gap, so the next check
    // does not fetch that thread again.
    @Test func aMessageThatCannotBeReadIsFetchedOnceAndThenLeftAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedRow(p, "nicole@everyvoicechoirs.org")
        let json = unreadableThread(from: "Nicole <nicole@everyvoicechoirs.org>")

        var fullFetches = 0
        let fetchFull: (String) -> Data? = { _ in fullFetches += 1; return json }

        _ = ReplyService.backfillResponders(in: [p], selfEmail: me,
                                            now: Date(timeIntervalSince1970: 9_999),
                                            fetchThread: { _ in json }, fetchFullThread: fetchFull)
        #expect(fullFetches == 1)
        #expect(r.lastReplyText == nil, "there was nothing readable to store")
        #expect(r.replyTextCheckedAt != nil, "the attempt has to be recorded on the row that failed")
        #expect(!ReplyGap.needsFilling(r), "and the row must leave the gap it cannot make progress in")

        // Every later check: nothing fetched, nothing changed.
        for _ in 0..<3 {
            _ = ReplyService.backfillResponders(in: [p], selfEmail: me,
                                            now: Date(timeIntervalSince1970: 9_999),
                                                fetchThread: { _ in json }, fetchFullThread: fetchFull)
        }
        #expect(fullFetches == 1, "a thread that cannot yield a body must never be refetched")
    }

    // And the ordinary case still works: a readable message is filled in, exactly as #2147 built it.
    @Test func aMessageThatCanBeReadIsStillFilledIn() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedRow(p, "nicole@everyvoicechoirs.org")
        let json = readableThread(from: "Nicole <nicole@everyvoicechoirs.org>", body: "Tuesday works for us.")

        _ = ReplyService.backfillResponders(in: [p], selfEmail: me,
                                            now: Date(timeIntervalSince1970: 9_999),
                                            fetchThread: { _ in json }, fetchFullThread: { _ in json })
        #expect(r.lastReplyText == "Tuesday works for us.")
        #expect(!ReplyGap.needsFilling(r))
    }

    // A row that has never been tried is still in the gap, or the fix would close the repair pass
    // entirely and #2147's actual defect would come back.
    @Test func aRowNeverTriedIsStillInTheGap() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedRow(p, "nicole@everyvoicechoirs.org")
        #expect(ReplyGap.needsFilling(r))
    }

    // A row missing its WRITER is in the gap whatever its text says, because that is a different repair
    // with its own success condition and it always succeeds when a sender exists.
    @Test func aRowMissingItsWriterIsInTheGapEvenAfterATextAttempt() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedRow(p, "nicole@everyvoicechoirs.org")
        r.lastReplyText = "Tuesday works."
        r.replyTextCheckedAt = Date(timeIntervalSince1970: 10)
        #expect(r.replyFromAddress == nil)
        #expect(ReplyGap.needsFilling(r))
    }

    // A row that never replied is nobody's repair job.
    @Test func aRowThatNeverRepliedIsNotInTheGap() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedRow(p, "nicole@everyvoicechoirs.org")
        r.replied = false
        #expect(!ReplyGap.needsFilling(r))
    }

    // The two places that ask this question have to ask it the same way. GmailReplyChecker decides which
    // THREADS to fetch and ReplyService decides which ROWS to fill, and if they disagree the checker
    // fetches threads nothing will use (the loop this issue is about) or starves a row that needs one.
    //
    // #2815: the fill's gap is no longer the ONLY reason to collect a thread, so this asserts what it
    // always meant rather than what it happened to say. The conversation here is CLOSED, which is the
    // state in which the gap is the last reason left; with it still open the checker keeps the thread on
    // purpose, because a new message could arrive on it (asserted below, and in
    // `ASecondMessageIsFetchedTests`). Written the old way this test passed on the defect: it read as the
    // checker correctly giving up, when what it had given up on was Dan's live conversation.
    @Test func theThreadCollectionAndTheFillAskOneQuestion() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedRow(p, "nicole@everyvoicechoirs.org")
        r.resolution = .declinedHard          // closed out: nothing new can arrive here
        let json = unreadableThread(from: "Nicole <nicole@everyvoicechoirs.org>")

        #expect(GmailReplyChecker.threadsToCheck(in: [p]) == ["t"],
                "still collected, because the fill has a gap it could make progress on")
        _ = ReplyService.backfillResponders(in: [p], selfEmail: me,
                                            now: Date(timeIntervalSince1970: 9_999),
                                            fetchThread: { _ in json }, fetchFullThread: { _ in json })
        #expect(GmailReplyChecker.threadsToCheck(in: [p]).isEmpty,
                "the checker must stop collecting a thread the fill has given up on")
    }

    // And the half that is NOT the fill's business. The same row with its conversation still open stays
    // collected after the fill has given up, because the reason to read it is no longer the gap (#2815).
    @Test func anOpenConversationIsStillCollectedAfterTheFillGivesUp() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedRow(p, "marion.alcott@example.com")
        let json = unreadableThread(from: "Marion Alcott <marion.alcott@example.com>")

        _ = ReplyService.backfillResponders(in: [p], selfEmail: me,
                                            now: Date(timeIntervalSince1970: 9_999),
                                            fetchThread: { _ in json }, fetchFullThread: { _ in json })

        #expect(!ReplyGap.needsFilling(r), "the repair pass is done with this row for ever")
        #expect(GmailReplyChecker.threadsToCheck(in: [p]) == ["t"],
                "and it is still watched, because they can still write again")
    }

    // What Dan reads. "Overture didn't capture what they wrote" is true of a reply nothing was tried on;
    // it is the wrong sentence for one that was read and could not be understood, and the two need
    // different words or the screen claims something its own check never measured (L11).
    @Test func anUnreadableMessageSaysSoRatherThanClaimingNothingWasCaptured() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = repliedRow(p, "nicole@everyvoicechoirs.org")

        let untried = ReplyPanel.missingWordsReason(r)
        r.replyTextCheckedAt = Date(timeIntervalSince1970: 10)
        let unreadable = ReplyPanel.missingWordsReason(r)

        #expect(untried != nil)
        #expect(unreadable != nil)
        #expect(untried != unreadable, "a message that was read and one that was not are different states")

        r.lastReplyText = "Tuesday works."
        #expect(ReplyPanel.missingWordsReason(r) == nil, "there is nothing to explain when the words are there")
    }
}
