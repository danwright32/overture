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
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

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

    @Test func leavesNoResponseWhenOnlyDanIsOnTheThread() async throws {
        let ctx = ModelContext(try container())
        let p = sentProspect(ctx, group: "Quiet Quartet", threadId: "t2")
        let checker = GmailReplyChecker(fromEmail: "dan@danwrightphotography.com")

        await checker.markReplies(in: ctx, token: "tok", now: Date(),
                                  fetch: threadFetch(from: "Dan Wright <dan@danwrightphotography.com>"))

        #expect(p.outcome == .noResponse)
    }
}
