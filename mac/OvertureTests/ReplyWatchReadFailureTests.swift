import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let replyWatchReadFailureGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")
// #2741: a Gmail read that FAILED used to be indistinguishable from a conversation nobody answered.
//
// `fetchThread` returned nil for every non-200 and every thrown error alike, its callers omitted that
// thread from the dictionary, and `detectReplies` read a missing thread as a thread with no reply on it.
// A 401 after a token expiry, a 429 during a burst and a genuinely quiet conversation all produced the
// same answer: the row went on saying nobody had written.
//
// The consequence is the worst kind, which is why this is worth a suite of its own: the product was
// quietest exactly when it had stopped working, and a presenter's reply sat unread while every surface
// said nothing arrived (L10, L11, L98).
@MainActor
@Suite("A Gmail read that failed is not a quiet conversation (#2741)")
struct ReplyWatchReadFailureTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func sent(_ ctx: ModelContext, group: String, threadId: String) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "music", venue: "Merkin Hall",
                         performanceDate: "2026-11-02", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.sentAt = Date()
        p.gmailThreadId = threadId
        ctx.insert(p)
        let r = Recipient(id: group + "@act.example", email: group + "@act.example", provenance: .act)
        r.gmailThreadId = threadId
        r.sentAt = p.sentAt
        r.sendState = .sent
        p.addRecipient(r)
        return p
    }

    private func replying(from: String) -> (URLRequest) async throws -> (Data, URLResponse) {
        let messages = [GmailFixture.Message(from: from)]
        return { req in replyWatchReadFailureGmail.respond(to: req, thread: messages) }
    }

    private func refusing(status: Int) -> (URLRequest) async throws -> (Data, URLResponse) {
        { req in (Data(), HTTPURLResponse(url: req.url!, statusCode: status,
                                          httpVersion: nil, headerFields: nil)!) }
    }

    private struct Unreachable: Error {}
    private func unreachable() -> (URLRequest) async throws -> (Data, URLResponse) {
        { _ in throw Unreachable() }
    }

    // MARK: the three states that used to be one

    @Test("a thread that read fine and is quiet is not an unreadable one")
    func aQuietThreadIsNotAFailure() async throws {
        let ctx = ModelContext(try container())
        sent(ctx, group: "Bach Society", threadId: "t1")
        let outcome = await GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")
            .markReplies(in: ctx, token: "tok", now: Date(),
                         fetch: replying(from: "dan@danwrightphotography.com"))

        #expect(outcome.threadsChecked == 1)
        #expect(outcome.unreadable == 0)
        #expect(!outcome.everyThreadUnreadable)
    }

    @Test("a refusal is counted as unreadable, whatever the status")
    func aRefusalIsUnreadable() async throws {
        for status in [401, 403, 429, 500] {
            let ctx = ModelContext(try container())
            sent(ctx, group: "Bach Society", threadId: "t1")
            let outcome = await GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")
                .markReplies(in: ctx, token: "tok", now: Date(), fetch: refusing(status: status))

            #expect(outcome.unreadable == 1, "a \(status) was not counted")
            #expect(outcome.everyThreadUnreadable, "and it was the only thread on the tick")
        }
    }

    @Test("a thrown error is unreadable too, not a quiet thread")
    func anUnreachableGmailIsUnreadable() async throws {
        let ctx = ModelContext(try container())
        sent(ctx, group: "Bach Society", threadId: "t1")
        let outcome = await GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")
            .markReplies(in: ctx, token: "tok", now: Date(), fetch: unreachable())

        #expect(outcome.unreadable == 1)
        #expect(outcome.everyThreadUnreadable)
    }

    // The row must not be marked on a read that failed, which is the damage this prevents: a refusal
    // reaching detection as "no reply" is how a row goes on saying nobody wrote.
    @Test("an unreadable thread leaves the row exactly as it was")
    func anUnreadableThreadMarksNothing() async throws {
        let ctx = ModelContext(try container())
        let p = sent(ctx, group: "Bach Society", threadId: "t1")
        _ = await GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")
            .markReplies(in: ctx, token: "tok", now: Date(), fetch: refusing(status: 401))

        #expect(p.recipients.allSatisfy { !$0.replied })
    }

    // MARK: the rate, not the count (L77)

    // One unreadable thread among several is ordinary contention. An alert that fires on it is an alert
    // Dan learns to ignore, and then the one that matters arrives on a channel he skims.
    @Test("one unreadable thread among several is not an outage")
    func oneOfSeveralIsNotAnOutage() async throws {
        let ctx = ModelContext(try container())
        sent(ctx, group: "Bach Society", threadId: "t1")
        sent(ctx, group: "Aurora Strings", threadId: "t2")
        sent(ctx, group: "City Brass", threadId: "t3")

        // Only the first thread asked for is refused; the rest read fine and are quiet.
        var seen = 0
        let outcome = await GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")
            .markReplies(in: ctx, token: "tok", now: Date()) { req in
                seen += 1
                let status = seen == 1 ? 429 : 200
                let json = replyWatchReadFailureGmail
                    .thread([.init(from: "dan@danwrightphotography.com")])
                return (json, HTTPURLResponse(url: req.url!, statusCode: status,
                                              httpVersion: nil, headerFields: nil)!)
            }

        #expect(outcome.threadsChecked == 3)
        #expect(outcome.unreadable == 1)
        #expect(!outcome.everyThreadUnreadable, "one of three is contention, not an outage")
    }

    @Test("every thread unreadable is an outage")
    func allOfThemIsAnOutage() async throws {
        let ctx = ModelContext(try container())
        sent(ctx, group: "Bach Society", threadId: "t1")
        sent(ctx, group: "Aurora Strings", threadId: "t2")
        let outcome = await GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")
            .markReplies(in: ctx, token: "tok", now: Date(), fetch: refusing(status: 401))

        #expect(outcome.everyThreadUnreadable)
    }

    // Finding no subjects is its own outcome and must never read as an outage: a pass with nothing to
    // watch is the ordinary state of a quiet week (L98).
    @Test("a tick with nothing to watch is not an outage")
    func nothingToWatchIsNotAnOutage() async throws {
        let ctx = ModelContext(try container())
        let outcome = await GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")
            .markReplies(in: ctx, token: "tok", now: Date(), fetch: refusing(status: 401))

        #expect(outcome.threadsChecked == 0)
        #expect(!outcome.everyThreadUnreadable)
    }

    // MARK: what the tick says

    // Its own field, not folded into saveFailed: a read that failed is not a save that failed, and a
    // pass from either would erase the other's failure (L53).
    @Test("the summary says a read failed, in its own words")
    func theSummarySaysARead() {
        let readFailed = ReconcileSummary(omniFocusChanged: 0, replyWatchUnreadable: true)
        #expect(readFailed.message.contains("couldn't read Gmail"))
        #expect(!readFailed.message.contains("couldn't save"))

        let saveFailed = ReconcileSummary(omniFocusChanged: 0, saveFailed: true)
        #expect(saveFailed.message.contains("couldn't save"))
        #expect(!saveFailed.message.contains("couldn't read Gmail"))
    }

    @Test("an ordinary tick says neither")
    func anOrdinaryTickSaysNeither() {
        let quiet = ReconcileSummary(omniFocusChanged: 0)
        #expect(!quiet.message.contains("couldn't read Gmail"))
        #expect(!quiet.message.contains("couldn't save"))
    }

    // Not connected is not a failure. Nothing was attempted, so nothing was established, and reporting it
    // as an outage would wake Dan for a tick that did nothing wrong.
    @Test("not connected is its own answer, and never an outage")
    func notConnectedIsNotAnOutage() {
        let outcome = GmailReplyChecker.Outcome(notConnected: true)
        #expect(outcome.notConnected)
        #expect(!outcome.everyThreadUnreadable)
        #expect(!outcome.saveFailed)
    }
}
