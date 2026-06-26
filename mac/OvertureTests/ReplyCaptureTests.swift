import Testing
import Foundation
@testable import Overture

// Capturing the reply text onto the prospect when a reply is first detected (#181). The full-format
// thread (with the body) is fetched LAZILY: only for a thread that actually has a reply, never for
// the whole sent list on every launch.
@MainActor
@Suite("Reply capture")
struct ReplyCaptureTests {
    private let me = "dan@danwrightphotography.com"

    private func b64url(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func sentLead() -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.gmailThreadId = "t"
        p.sentAt = Date(timeIntervalSince1970: 1)
        return p
    }

    @Test func capturesReplyBodyWhenMarkingReplied() {
        let p = sentLead()
        let meta = Data(#"{"messages":[{"payload":{"headers":[{"name":"From","value":"emma@org.example"}]}}]}"#.utf8)
        let full = Data("""
        {"messages":[{"payload":{"headers":[{"name":"From","value":"emma@org.example"}],"mimeType":"text/plain","body":{"data":"\(b64url("Yes, let's book."))"}}}]}
        """.utf8)
        let now = Date(timeIntervalSince1970: 5000)
        let n = ReplyService.detectReplies(in: [p], selfEmail: me, now: now,
                                           fetchThread: { _ in meta }, fetchFullThread: { _ in full })
        #expect(n == 1)
        #expect(p.outcome == .replied)
        #expect(p.lastReplyText == "Yes, let's book.")
        #expect(p.lastReplyAt == now)
    }

    @Test func doesNotFullFetchWhenThereIsNoReply() {
        let p = sentLead()
        let selfOnly = Data(#"{"messages":[{"payload":{"headers":[{"name":"From","value":"dan@danwrightphotography.com"}]}}]}"#.utf8)
        var fullFetched = false
        let n = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(),
                                           fetchThread: { _ in selfOnly },
                                           fetchFullThread: { _ in fullFetched = true; return nil })
        #expect(n == 0)
        #expect(fullFetched == false)   // lazy: never pulls the full body for a non-replied thread
        #expect(p.lastReplyText == nil)
    }
}
