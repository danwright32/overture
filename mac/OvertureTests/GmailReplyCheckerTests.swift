import Testing
import Foundation
import SwiftData
@testable import Overture

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
        let json = #"{"messages":[{"payload":{"headers":[{"name":"From","value":""#
            + from + #""}]}}]}"#
        return { req in
            (Data(json.utf8),
             HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func marksRepliedWhenSomeoneElseRepliesOnTheThread() async throws {
        let ctx = ModelContext(try container())
        let p = sentProspect(ctx, group: "Bach Society", threadId: "t1")
        let checker = GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")

        await checker.markReplies(in: ctx, token: "tok", now: Date(),
                                  fetch: threadFetch(from: "manager@bachsociety.org"))

        #expect(p.outcome == .replied)
        #expect(p.outcomeSourceRaw == OutcomeSource.auto.rawValue)
    }

    // Two-phase fetch (#181): metadata returned for the format=metadata request, a full thread with
    // the body for the format=full request. Proves the checker full-fetches the replied thread and
    // captures the body.
    private func twoPhaseFetch(from: String, body: String) -> (URLRequest) async throws -> (Data, URLResponse) {
        let meta = #"{"messages":[{"payload":{"headers":[{"name":"From","value":""# + from + #""}]}}]}"#
        let b64 = Data(body.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let full = #"{"messages":[{"payload":{"headers":[{"name":"From","value":""# + from
            + #""}],"mimeType":"text/plain","body":{"data":""# + b64 + #""}}}]}"#
        return { req in
            let isFull = req.url?.absoluteString.contains("format=full") == true
            return (Data((isFull ? full : meta).utf8),
                    HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    @Test func capturesTheReplyBodyViaTheTwoPhaseFetch() async throws {
        let ctx = ModelContext(try container())
        let p = sentProspect(ctx, group: "Aurora Strings", threadId: "t3")
        let checker = GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")

        await checker.markReplies(in: ctx, token: "tok", now: Date(),
                                  fetch: twoPhaseFetch(from: "emma@aurora.example", body: "Yes, let's book."))

        #expect(p.outcome == .replied)
        #expect(p.lastReplyText == "Yes, let's book.")
    }

    @Test func leavesNoResponseWhenOnlyDanIsOnTheThread() async throws {
        let ctx = ModelContext(try container())
        let p = sentProspect(ctx, group: "Quiet Quartet", threadId: "t2")
        let checker = GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")

        await checker.markReplies(in: ctx, token: "tok", now: Date(),
                                  fetch: threadFetch(from: "Dan Wright <dan@danwrightphotography.com>"))

        #expect(p.outcome == .noResponse)
    }
}
