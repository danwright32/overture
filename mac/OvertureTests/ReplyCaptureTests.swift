import Testing
import Foundation
import SwiftData
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

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Detection reads recipient threads now (#418 A2), so the sent lead carries a sent recipient on
    // thread "t". The lead gmailThreadId is kept for the A3 rollup readers.
    private func sentLead(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.gmailThreadId = "t"
        p.sentAt = Date(timeIntervalSince1970: 1)
        ctx.insert(p)
        let r = Recipient(id: "emma@org.example", email: "emma@org.example", provenance: .act)
        r.gmailThreadId = "t"
        r.sentAt = p.sentAt
        r.sendState = .sent
        p.addRecipient(r)
        return p
    }

    @Test func capturesReplyBodyWhenMarkingReplied() throws {
        let ctx = ModelContext(try container())
        let p = sentLead(ctx)
        let meta = Data(#"{"messages":[{"payload":{"headers":[{"name":"From","value":"emma@org.example"}]}}]}"#.utf8)
        let full = Data("""
        {"messages":[{"payload":{"headers":[{"name":"From","value":"emma@org.example"}],"mimeType":"text/plain","body":{"data":"\(b64url("Yes, let's book."))"}}}]}
        """.utf8)
        let now = Date(timeIntervalSince1970: 5000)
        let n = ReplyService.detectReplies(in: [p], selfEmail: me, now: now,
                                           fetchThread: { _ in meta }, fetchFullThread: { _ in full })
        #expect(n == 1)
        // Phase F: the reply is captured on the CONTACT, not rolled up to the lead.
        #expect(p.recipients.first?.replied == true)
        #expect(p.recipients.first?.lastReplyText == "Yes, let's book.")
        #expect(p.recipients.first?.repliedAt == now)
    }

    // #219: the id of the newest message from someone other than Dan, used to dismiss one specific
    // auto-detected reply while still catching a genuinely new one later.
    @Test func latestReplyIdIsTheNewestNonSelfMessage() {
        let json = Data(#"{"messages":[{"id":"m1","payload":{"headers":[{"name":"From","value":"dan@danwrightphotography.com"}]}},{"id":"m2","payload":{"headers":[{"name":"From","value":"emma@org.example"}]}}]}"#.utf8)
        #expect(ReplyDetection.latestReplyId(threadJSON: json, selfEmail: me) == "m2")
    }

    // #219: marking a reply "not real" reverts it and stops THAT reply re-detecting, but a genuinely
    // new reply on the thread still flags.
    @Test func dismissedReplyIsNotReDetectedButANewReplyIs() throws {
        let ctx = ModelContext(try container())
        let p = sentLead(ctx)
        let oneReply = Data(#"{"messages":[{"id":"s1","payload":{"headers":[{"name":"From","value":"dan@danwrightphotography.com"}]}},{"id":"r1","payload":{"headers":[{"name":"From","value":"emma@org.example"}]}}]}"#.utf8)
        _ = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(timeIntervalSince1970: 100),
                                       fetchThread: { _ in oneReply })
        // Phase F: detection + dismiss are per-contact now (no lead rollup).
        #expect(p.recipients.first?.replied == true)
        #expect(p.recipients.first?.lastReplyId == "r1")

        p.recipients.first?.dismissAutoReply()
        #expect(p.recipients.first?.replied == false)
        #expect(p.recipients.first?.dismissedReplyId == "r1")

        let n2 = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(timeIntervalSince1970: 300),
                                            fetchThread: { _ in oneReply })
        #expect(n2 == 0)
        #expect(p.recipients.first?.replied == false)

        let twoReplies = Data(#"{"messages":[{"id":"s1","payload":{"headers":[{"name":"From","value":"dan@danwrightphotography.com"}]}},{"id":"r1","payload":{"headers":[{"name":"From","value":"emma@org.example"}]}},{"id":"r2","payload":{"headers":[{"name":"From","value":"emma@org.example"}]}}]}"#.utf8)
        let n3 = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(timeIntervalSince1970: 400),
                                            fetchThread: { _ in twoReplies })
        #expect(n3 == 1)
        #expect(p.recipients.first?.replied == true)
        #expect(p.recipients.first?.lastReplyId == "r2")
    }

    @Test func doesNotFullFetchWhenThereIsNoReply() throws {
        let ctx = ModelContext(try container())
        let p = sentLead(ctx)
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
