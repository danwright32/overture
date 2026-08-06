import Testing
import Foundation
import SwiftData

// #2191. Reply detection treats an incoming reply as a fact about the whole send group: measured on the
// live store, both contacts on The Pumpkin Singalong carry the same `lastReplyId`, the same 1469 characters
// of reply text and the same arrival time. Answering it did not fan out the same way, because
// `recordAnswerSent` is a method on ONE recipient and both callers ran it on one.
//
// One incoming reply marks N contacts. One outgoing answer cleared one. The two could never agree, so a
// single unstamped peer kept `Prospect.hasUnhandledReply` true and went on feeding the Dock badge, the
// OmniFocus task and the conversation reminder after the answer had gone (L38: touching N minus 1 of N).
//
// Dan's call, 2026-08-06, on an answer whose audience is narrower than the group: mark everyone on the
// message. They are all attached to one incoming email, and the alternative leaves the show lit over a
// contact he has no way to clear by hand.
//
// What stays on the ONE contact that sent: the frozen sent body and the send time. Those are member facts
// and copying them would claim colleagues sent words they did not (L66).
@MainActor
@Suite("Answering marks the whole conversation (#2191)")
struct AnsweringMarksTheWholeConversationTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "The Pumpkin Singalong at Sakura Park",
                         discipline: "choral", venue: "Sakura Park", performanceDate: "2026-10-31",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    private let theyWrote = Date(timeIntervalSince1970: 5_000)
    private let heAnswered = Date(timeIntervalSince1970: 9_000)
    private let group = "35E15806-C348-4915-8FFE-ADAB4B24A955"
    private let herReply = "19fcf6b9a4dddb0a"

    // The live shape: two contacts, one send group, one reply fanned out onto both by detection.
    @discardableResult
    private func onTheReply(_ p: Prospect, _ address: String, replyId: String? = nil) -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .act)
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailMessageId = "msg-\(address)"
        r.gmailThreadId = "19fceac517b7f2d4"
        r.sendGroupId = group
        r.replied = true
        r.repliedAt = theyWrote
        r.inboundReplySentAt = theyWrote
        r.lastReplyId = replyId ?? herReply
        r.lastReplyText = "We would love to talk about the Singalong."
        r.replyFromAddress = "nicolebecker@everyvoicechoirs.org"
        r.replyAudience = ["nicolebecker@everyvoicechoirs.org", "chelsea@everyvoicechoirs.org"]
        r.replyDraftBody = "Tuesday works, I will bring the 85mm."
        p.addRecipient(r)
        return r
    }

    // The premise, checked rather than assumed: BOTH contacts really are waiting before anything is
    // answered, so a test below cannot pass on a peer that was never asking (L1).
    @Test func thePremiseHolds_bothContactsStartOutWaiting() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = onTheReply(p, "chelsea@everyvoicechoirs.org")
        let nicole = onTheReply(p, "nbecker@everyvoicechoirs.org")

        #expect(chelsea.hasUnhandledReply)
        #expect(nicole.hasUnhandledReply)
        #expect(p.hasUnhandledReply)
    }

    // 1. The copy-out path. Answering on the contact the row happens to stand on clears the whole
    // conversation, not just that one.
    @Test func answeringOnOnePeerClearsThePeerItDidNotSendTo() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = onTheReply(p, "chelsea@everyvoicechoirs.org")
        let nicole = onTheReply(p, "nbecker@everyvoicechoirs.org")

        AnsweredReply.record(on: chelsea, in: p, now: heAnswered)

        #expect(!chelsea.hasUnhandledReply)
        #expect(!nicole.hasUnhandledReply, "the peer on the same reply must stop asking too (#2191)")
        #expect(!p.hasUnhandledReply, "the show must stop feeding the badge and the OmniFocus task")
    }

    // 2. The in-app send path reaches the same place, or the fix lands on one of the two ways to answer
    // and the other goes on producing the defect (L30, the mistake #2170 already had to correct once).
    @Test func theInAppSendClearsTheWholeConversationToo() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = onTheReply(p, "chelsea@everyvoicechoirs.org")
        let nicole = onTheReply(p, "nbecker@everyvoicechoirs.org")

        let sent = await ReplyPanel.commit(body: "Tuesday works.", on: chelsea, of: p,
                                           now: heAnswered, sender: FakeReplySender())
        #expect(sent)
        #expect(!chelsea.hasUnhandledReply)
        #expect(!nicole.hasUnhandledReply, "both answer paths must fan out identically (#2191)")
    }

    // 3. The member facts stay put. A colleague did not write these words and did not send them at this
    // time, and stamping them would put somebody else's sent email on their record (L66).
    @Test func theSentWordsStayOnTheContactThatActuallySentThem() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = onTheReply(p, "chelsea@everyvoicechoirs.org")
        let nicole = onTheReply(p, "nbecker@everyvoicechoirs.org")

        AnsweredReply.record(on: chelsea, in: p, now: heAnswered)

        #expect(chelsea.sentReplyBody?.isEmpty == false)
        #expect(chelsea.replySentAt == heAnswered)
        #expect(nicole.sentReplyBody == nil, "a peer never sent these words")
        #expect(nicole.replySentAt == nil, "a peer never sent anything at this time")
    }

    // 4. The failure path. A peer carrying a DIFFERENT reply is a colleague who has written something of
    // their own, and answering Nicole says nothing about it. Clearing it would silently bury a message
    // nobody has read.
    @Test func aPeerOnADifferentReplyIsLeftAsking() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = onTheReply(p, "chelsea@everyvoicechoirs.org")
        let other = onTheReply(p, "jo@everyvoicechoirs.org", replyId: "19fd000000000000")

        AnsweredReply.record(on: chelsea, in: p, now: heAnswered)

        #expect(!chelsea.hasUnhandledReply)
        #expect(other.hasUnhandledReply, "a different reply is a different message and stays unanswered")
        #expect(p.hasUnhandledReply, "the show is still waiting on the message nobody answered")
    }

    // 5. And the fan-out cannot escape the conversation. A contact on the same show in a DIFFERENT send
    // group was never on this email at all.
    @Test func aContactInAnotherSendGroupIsUntouched() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = onTheReply(p, "chelsea@everyvoicechoirs.org")
        let stranger = onTheReply(p, "boxoffice@everyvoicechoirs.org")
        stranger.sendGroupId = "A-DIFFERENT-GROUP"

        AnsweredReply.record(on: chelsea, in: p, now: heAnswered)

        #expect(!chelsea.hasUnhandledReply)
        #expect(stranger.hasUnhandledReply, "a separate email is a separate conversation")
    }

    // 6. A reply with no id recorded cannot be proved to be the same message, so it is not cleared.
    // Fail closed: leaving a row asking costs Dan one glance, clearing it wrongly hides a real reply.
    @Test func aPeerWithNoRecordedReplyIdIsNotCleared() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = onTheReply(p, "chelsea@everyvoicechoirs.org")
        let unidentified = onTheReply(p, "nbecker@everyvoicechoirs.org")
        unidentified.lastReplyId = nil

        AnsweredReply.record(on: chelsea, in: p, now: heAnswered)

        #expect(!chelsea.hasUnhandledReply)
        #expect(unidentified.hasUnhandledReply,
                "nothing proves this is the same message, so it keeps asking (fail closed)")
    }

    // 7. Answering alone is still not closing, across the group. #2170 settled this for one contact and it
    // has to stay true for the peers the fan-out now touches.
    @Test func theFanOutNeverClosesAnybodysConversation() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = onTheReply(p, "chelsea@everyvoicechoirs.org")
        let nicole = onTheReply(p, "nbecker@everyvoicechoirs.org")

        AnsweredReply.record(on: chelsea, in: p, now: heAnswered)

        #expect(chelsea.resolution == nil)
        #expect(nicole.resolution == nil, "answering must never quietly close a peer's conversation")
        #expect(ReachedOutQueue.nextReachOut(for: chelsea, of: p, now: heAnswered) != nil)
    }
}

private struct FakeReplySender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        SentReceipt(threadId: "19fceac517b7f2d4", messageID: "m-sent")
    }
}
