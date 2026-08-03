import Testing
import Foundation
import SwiftData

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

    // #481: a token merely appearing inside a real local part (not as the whole address or a
    // bounded prefix/suffix) must not be treated as automated.
    @Test func aLocalPartThatMerelyContainsATokenIsNotAutomated() {
        #expect(ReplyDetection.isAutomated("eleanoreply@gmail.com") == false)
        #expect(ReplyDetection.isAutomated("bouncebackband@gmail.com") == false)
        #expect(ReplyDetection.isAutomated("postmasterclass@school.com") == false)
        #expect(ReplyDetection.hasReply(fromAddresses: ["Eleanor <eleanoreply@gmail.com>"], selfEmail: me) == true)
        #expect(ReplyDetection.hasReply(fromAddresses: ["Bounce Back Band <bouncebackband@gmail.com>"], selfEmail: me) == true)
    }

    // #481: a token set off by a separator (a real automated address's usual shape) is still
    // caught even though it's not the entire local part.
    @Test func aTokenBoundedBySeparatorsIsStillAutomated() {
        #expect(ReplyDetection.isAutomated("notifications-noreply@github.com") == true)
        #expect(ReplyDetection.isAutomated("noreply-support@org.org") == true)
        #expect(ReplyDetection.isAutomated("team.donotreply@org.org") == true)
        #expect(ReplyDetection.hasReply(fromAddresses: ["notifications-noreply@github.com"], selfEmail: me) == false)
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
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Detection now reads recipient threads (#418 A2), so a sent prospect needs a sent recipient
    // carrying the thread (the lead gmailThreadId rollup is kept too for the A3 bridge readers).
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
        if let threadId {
            addRecipient(p, id: group + "@act.example", threadId: threadId, sentAt: sentAt)
        }
        return p
    }

    @discardableResult
    private func addRecipient(_ p: Prospect, id: String, threadId: String?, sentAt: Date?) -> Recipient {
        let r = Recipient(id: id, email: id, provenance: .act)
        r.gmailThreadId = threadId
        r.sentAt = sentAt
        r.sendState = sentAt != nil ? .sent : .pending
        p.addRecipient(r)
        return r
    }

    private let replyThread = Data(#"{"messages":[{"payload":{"headers":[{"name":"From","value":"dan@danwrightphotography.com"}]}},{"payload":{"headers":[{"name":"From","value":"them@org.org"}]}}]}"#.utf8)
    private let noReplyThread = Data(#"{"messages":[{"payload":{"headers":[{"name":"From","value":"dan@danwrightphotography.com"}]}}]}"#.utf8)

    @Test func marksRepliedWhenThreadHasAReply() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "A", threadId: "t1", sentAt: Date())
        let n = ReplyService.detectReplies(in: [p], selfEmail: "dan@danwrightphotography.com",
                                           now: Date(timeIntervalSince1970: 9)) { _ in self.replyThread }
        #expect(n == 1)
        // Phase F: the reply lives on the CONTACT now (no lead rollup).
        #expect(p.recipients.first?.replied == true)
        #expect(p.recipients.first?.outcomeSource != .manual)
    }

    @Test func leavesAloneWhenNoReplyOrNotSentOrManual() throws {
        let ctx = ModelContext(try container())
        let noReply = make(ctx, group: "A", threadId: "t1", sentAt: Date())
        let notSent = make(ctx, group: "B", threadId: nil, sentAt: nil)
        let manual = make(ctx, group: "C", threadId: "t3", sentAt: Date(), outcome: .lostSoft, source: .manual)

        let n = ReplyService.detectReplies(in: [noReply, notSent, manual],
                                           selfEmail: "dan@danwrightphotography.com", now: Date()) { id in
            id == "t3" ? self.replyThread : self.noReplyThread
        }
        #expect(n == 0)
        #expect(noReply.outcome == .noResponse)
        #expect(manual.outcome == .lostSoft)   // manual is never overwritten
    }

    // #418 A2 — the core fix: a reply on a NON-first recipient's thread is detected and attributed to
    // that recipient (not lost behind the first contact's state), and rolls up to the lead.
    @Test func detectsAReplyOnANonFirstRecipientThread() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Show", threadId: "t1", sentAt: Date())   // recipient A on t1
        addRecipient(p, id: "b@present.example", threadId: "t2", sentAt: Date())  // recipient B on t2

        let n = ReplyService.detectReplies(in: [p], selfEmail: "dan@danwrightphotography.com",
                                           now: Date(timeIntervalSince1970: 9)) { id in
            id == "t2" ? self.replyThread : self.noReplyThread
        }
        #expect(n == 1)
        #expect(p.recipients.first { $0.gmailThreadId == "t2" }?.replied == true)
        #expect(p.recipients.first { $0.gmailThreadId == "t1" }?.replied == false)
        #expect(p.hasUnhandledReply)   // Phase F: the show reads as having an unhandled reply, derived
    }

    // #418 A2 — the regression for the swallow bug: once contact A replies (lead becomes auto .replied),
    // a LATER reply from contact B is still detected. Before this phase the lead-level guard buried B.
    @Test func anAlreadyRepliedLeadStillDetectsASecondContactsReply() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Show", threadId: "t1", sentAt: Date())
        addRecipient(p, id: "b@present.example", threadId: "t2", sentAt: Date())
        let me = "dan@danwrightphotography.com"

        // Round 1: only A (t1) has replied.
        _ = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(timeIntervalSince1970: 9)) {
            $0 == "t1" ? self.replyThread : self.noReplyThread
        }
        #expect(p.recipients.first { $0.gmailThreadId == "t1" }?.replied == true)   // contact A replied

        // Round 2: B (t2) now replies too — must NOT be swallowed by the lead's .replied state.
        let n2 = ReplyService.detectReplies(in: [p], selfEmail: me, now: Date(timeIntervalSince1970: 99)) { _ in
            self.replyThread
        }
        #expect(n2 == 1)
        #expect(p.recipients.first { $0.gmailThreadId == "t2" }?.replied == true)
    }

    // #418 A2 — a per-recipient MANUAL mark on one contact does not blind detection of another.
    @Test func aManualMarkOnOneRecipientDoesNotBlindAnother() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Show", threadId: "t1", sentAt: Date())
        p.recipients.first?.outcomeSource = .manual   // contact A hand-judged
        addRecipient(p, id: "b@present.example", threadId: "t2", sentAt: Date())

        let n = ReplyService.detectReplies(in: [p], selfEmail: "dan@danwrightphotography.com",
                                           now: Date(timeIntervalSince1970: 9)) { _ in self.replyThread }
        #expect(n == 1)   // only B is newly detected
        #expect(p.recipients.first { $0.gmailThreadId == "t1" }?.replied == false)  // manual A untouched
        #expect(p.recipients.first { $0.gmailThreadId == "t2" }?.replied == true)
    }

    // The contact's reply body + time are captured so ReplyClassifyService.needsClassify (which
    // re-fires on repliedAt) can queue it. Per-contact now (Phase F removed the lead rollup).
    @Test func capturesReplyBodyAndTimeOnTheContactForClassify() throws {
        let ctx = ModelContext(try container())
        let p = make(ctx, group: "Show", threadId: "t1", sentAt: Date())
        // "WWVz" is base64url for "Yes"; a valid text/plain part so latestReplyBody returns it.
        let full = Data(#"{"messages":[{"payload":{"headers":[{"name":"From","value":"them@org.org"}],"mimeType":"text/plain","body":{"data":"WWVz"}}}]}"#.utf8)
        _ = ReplyService.detectReplies(in: [p], selfEmail: "dan@danwrightphotography.com",
                                       now: Date(timeIntervalSince1970: 50),
                                       fetchThread: { _ in self.replyThread },
                                       fetchFullThread: { _ in full })
        #expect(p.recipients.first?.repliedAt == Date(timeIntervalSince1970: 50))
        #expect(p.recipients.first?.lastReplyText == "Yes")
    }
}
