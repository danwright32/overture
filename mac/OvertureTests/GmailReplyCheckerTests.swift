import Testing
import Foundation
import SwiftData

// #2928: the one Gmail fixture builder, at file scope so the nonisolated fetch closures can read it.
private let replyCheckerGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")

// #84: marking a sent prospect .replied off a real thread response is now testable through an
// injected fetch (no network, no live token), driving the tested ReplyService/ReplyDetection.
@MainActor
@Suite("Gmail reply checker")
struct GmailReplyCheckerTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Detection watches recipient threads now (#418 A2), so the sent prospect carries a sent recipient
    // on the thread (lead gmailThreadId kept too for the A3 rollup readers).
    @discardableResult
    private func sentProspect(_ ctx: ModelContext, group: String, threadId: String) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
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

    // A Gmail threads.get metadata response whose only inbound From is `from`.
    private func threadFetch(from: String) -> (URLRequest) async throws -> (Data, URLResponse) {
        let messages = [GmailFixture.Message(from: from)]
        return { req in replyCheckerGmail.respond(to: req, thread: messages) }
    }

    @Test func marksRepliedWhenSomeoneElseRepliesOnTheThread() async throws {
        let ctx = ModelContext(try container())
        let p = sentProspect(ctx, group: "Bach Society", threadId: "t1")
        let checker = GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")

        await checker.markReplies(in: ctx, token: "tok", now: Date(),
                                  fetch: threadFetch(from: "manager@bachsociety.org"))

        // Phase F: the reply is marked on the CONTACT, not rolled up to the lead.
        #expect(p.recipients.first?.replied == true)
        #expect(p.recipients.first?.outcomeSource != .manual)
    }

    // Two-phase fetch (#181): metadata returned for the format=metadata request, a full thread with
    // the body for the format=full request. Proves the checker full-fetches the replied thread and
    // captures the body.
    private func twoPhaseFetch(from: String, body: String) -> (URLRequest) async throws -> (Data, URLResponse) {
        // #2928: one fixture answering BOTH formats, honouring the request the way Gmail does, so the
        // metadata call gets no body and only the headers it asked for.
        let messages = [GmailFixture.Message(from: from, text: body)]
        return { req in replyCheckerGmail.respond(to: req, thread: messages) }
    }

    @Test func capturesTheReplyBodyViaTheTwoPhaseFetch() async throws {
        let ctx = ModelContext(try container())
        let p = sentProspect(ctx, group: "Aurora Strings", threadId: "t3")
        let checker = GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")

        await checker.markReplies(in: ctx, token: "tok", now: Date(),
                                  fetch: twoPhaseFetch(from: "emma@aurora.example", body: "Yes, let's book."))

        #expect(p.recipients.first?.replied == true)
        #expect(p.recipients.first?.lastReplyText == "Yes, let's book.")
    }

    @Test func leavesNoResponseWhenOnlyDanIsOnTheThread() async throws {
        let ctx = ModelContext(try container())
        let p = sentProspect(ctx, group: "Quiet Quartet", threadId: "t2")
        let checker = GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")

        await checker.markReplies(in: ctx, token: "tok", now: Date(),
                                  fetch: threadFetch(from: "Dan Wright <dan@danwrightphotography.com>"))

        #expect(p.outcome == .noResponse)
    }

    // #617: a real save() failure (not just the source-scan guard in GmailReplyCheckerSaveGuardTests),
    // via ImmutableStoreFixture.
    @Test func markRepliesReturnsTrueOnAGenuineSaveFailure() async throws {
        let outcome = try await ImmutableStoreFixture.withFailingSave(
            schema: Schema([Prospect.self, Recipient.self]),
            seed: { _ = self.sentProspect($0, group: "Bach Society", threadId: "t1") },
            body: { ctx in
                let checker = GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")
                return await checker.markReplies(in: ctx, token: "tok", now: Date(),
                                                 fetch: self.threadFetch(from: "manager@bachsociety.org"))
            })

        // #2741: the same fact, now on a field of its own rather than as the one thing a Bool could say.
        #expect(outcome.saveFailed)
    }

    private func bounceThreadFetch(from: String, subject: String) -> (URLRequest) async throws -> (Data, URLResponse) {
        let messages = [GmailFixture.Message(from: from, subject: subject, id: "bounce-1")]
        return { req in replyCheckerGmail.respond(to: req, thread: messages) }
    }

    // #398: a hard bounce on the recipient's own thread marks it bounced, auto-sourced so Dan's
    // dismiss control still applies, and the save actually runs even though no reply was found.
    @Test func marksBouncedWhenTheThreadCarriesAHardBounce() async throws {
        let ctx = ModelContext(try container())
        let p = sentProspect(ctx, group: "Dead Inbox Trio", threadId: "t4")
        let checker = GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")

        await checker.markReplies(in: ctx, token: "tok", now: Date(),
                                  fetch: bounceThreadFetch(from: "mailer-daemon@googlemail.com",
                                                           subject: "Delivery Status Notification (Failure)"))

        #expect(p.recipients.first?.bounced == true)
        #expect(p.recipients.first?.lastBounceId == "bounce-1")
        #expect(p.recipients.first?.outcomeSource != .manual)
    }

    @Test func leavesUnbouncedOnASoftBounce() async throws {
        let ctx = ModelContext(try container())
        let p = sentProspect(ctx, group: "Slow Mailbox Quartet", threadId: "t5")
        let checker = GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")

        await checker.markReplies(in: ctx, token: "tok", now: Date(),
                                  fetch: bounceThreadFetch(from: "mailer-daemon@googlemail.com",
                                                           subject: "Delivery Status Notification (Delay)"))

        #expect(p.recipients.first?.bounced == false)
    }

    @Test func neverReflagsABounceDanDismissed() async throws {
        let ctx = ModelContext(try container())
        let p = sentProspect(ctx, group: "Reconsidered Ensemble", threadId: "t6")
        p.recipients.first?.dismissedBounceId = "bounce-1"
        let checker = GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")

        await checker.markReplies(in: ctx, token: "tok", now: Date(),
                                  fetch: bounceThreadFetch(from: "mailer-daemon@googlemail.com",
                                                           subject: "Delivery Status Notification (Failure)"))

        #expect(p.recipients.first?.bounced == false)
    }
}
