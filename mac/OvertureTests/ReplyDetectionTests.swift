import Testing
import Foundation
import SwiftData
@testable import Overture

// #40 reply detection: when someone other than Dan posts to a sent email's thread, that's
// a reply, and the prospect's outcome becomes .replied (source auto) — one of the two
// automatic outcome signals. Pure parse + decision here; manual outcomes stay sticky.
@Suite("Reply detection")
struct ReplyDetectionTests {
    private let me = "dan@danwrightphotography.com"

    @Test func aThreadWithOnlyDansMessageIsNotAReply() {
        #expect(ReplyDetection.hasReply(fromAddresses: ["Dan Wright <dan@danwrightphotography.com>"], selfEmail: me) == false)
    }

    @Test func aMessageFromSomeoneElseIsAReply() {
        let froms = ["Dan Wright <dan@danwrightphotography.com>", "Emma Robinson <emma@icchoir.org>"]
        #expect(ReplyDetection.hasReply(fromAddresses: froms, selfEmail: me) == true)
    }

    @Test func matchesDanRegardlessOfDisplayNameOrCase() {
        #expect(ReplyDetection.hasReply(fromAddresses: ["DAN@DanWrightPhotography.com"], selfEmail: me) == false)
    }

    @Test func bouncesAndAutomatedSendersAreNotReplies() {
        // A delivery bounce means the opposite of a reply.
        #expect(ReplyDetection.hasReply(fromAddresses: ["Mail Delivery Subsystem <mailer-daemon@googlemail.com>"], selfEmail: me) == false)
        #expect(ReplyDetection.hasReply(fromAddresses: ["postmaster@icchoir.org"], selfEmail: me) == false)
        // No-reply autoresponders don't count.
        #expect(ReplyDetection.hasReply(fromAddresses: ["no-reply@org.org"], selfEmail: me) == false)
        #expect(ReplyDetection.hasReply(fromAddresses: ["DoNotReply@org.org"], selfEmail: me) == false)
        // A real human reply alongside an autoresponder still counts.
        #expect(ReplyDetection.hasReply(fromAddresses: ["no-reply@org.org", "Emma <emma@icchoir.org>"], selfEmail: me) == true)
    }

    @Test func parsesFromHeadersOutOfAGmailThreadResponse() {
        let json = #"""
        {"messages":[
          {"payload":{"headers":[{"name":"To","value":"x"},{"name":"From","value":"Dan <dan@danwrightphotography.com>"}]}},
          {"payload":{"headers":[{"name":"From","value":"emma@icchoir.org"}]}}
        ]}
        """#
        let froms = ReplyDetection.fromAddresses(threadJSON: Data(json.utf8))
        #expect(froms.count == 2)
        #expect(ReplyDetection.hasReply(fromAddresses: froms, selfEmail: me) == true)
    }
}

@MainActor
@Suite("Reply service")
struct ReplyServiceTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    @discardableResult
    private func make(_ ctx: ModelContext, group: String, threadId: String?, sentAt: Date?,
                      outcome: Outcome = .noResponse, source: OutcomeSource? = nil) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: "choral", venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .approved)
        p.gmailThreadId = threadId
        p.sentAt = sentAt
        p.outcome = outcome
        p.outcomeSourceRaw = source?.rawValue
        ctx.insert(p)
        return p
    }

    private let replyThread = Data(#"{"messages":[{"payload":{"headers":[{"name":"From","value":"dan@danwrightphotography.com"}]}},{"payload":{"headers":[{"name":"From","value":"them@org.org"}]}}]}"#.utf8)
    private let noReplyThread = Data(#"{"messages":[{"payload":{"headers":[{"name":"From","value":"dan@danwrightphotography.com"}]}}]}"#.utf8)

    @Test func marksRepliedWhenThreadHasAReply() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "A", threadId: "t1", sentAt: Date())
        let n = ReplyService.detectReplies(in: [p], selfEmail: "dan@danwrightphotography.com",
                                           now: Date(timeIntervalSince1970: 9)) { _ in self.replyThread }
        #expect(n == 1)
        #expect(p.outcome == .replied)
        #expect(p.outcomeSourceRaw == OutcomeSource.auto.rawValue)
    }

    @Test func leavesAloneWhenNoReplyOrNotSentOrManual() throws {
        let ctx = ModelContext(try container())
        let noReply = make(ctx, group: "A", threadId: "t1", sentAt: Date())
        let notSent = make(ctx, group: "B", threadId: nil, sentAt: nil)
        let manual = make(ctx, group: "C", threadId: "t3", sentAt: Date(), outcome: .passed, source: .manual)

        let n = ReplyService.detectReplies(in: [noReply, notSent, manual],
                                           selfEmail: "dan@danwrightphotography.com", now: Date()) { id in
            id == "t3" ? self.replyThread : self.noReplyThread
        }
        #expect(n == 0)
        #expect(noReply.outcome == .noResponse)
        #expect(manual.outcome == .passed)   // manual is never overwritten
    }
}
