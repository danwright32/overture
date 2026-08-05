import Testing
import Foundation
import SwiftData

// #2128: answering a reply from the Reached out queue. Dan (2026-08-05): "The reply itself should be
// done in the reached out queue. I'm never going to archive unless I need to look at something in the
// past." And: "I'll respond to whatever it is they say, usually by hand."
//
// Everything the panel decides lives here, in pure types, because the panel itself is SwiftUI and a
// decision made inside it is a decision no test can reach.
@MainActor
@Suite("The reply panel")
struct ReplyPanelTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Pumpkin Singalong", discipline: "choral", venue: "V",
                         performanceDate: "2026-10-31", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect, _ address: String, group: String? = "g") -> Recipient {
        let r = Recipient(id: address, email: address, provenance: .act)
        r.sendGroupId = group
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailMessageId = "msg-\(address)"
        r.gmailThreadId = "t"
        p.setRecipients(p.recipients + [r])
        return r
    }

    // MARK: what the panel is allowed to send

    // Dan types the words himself, so there is nothing to send until he has typed some.
    @Test func nothingSendsUntilSomethingIsTyped() {
        #expect(!ReplyPanel.canSend(body: "", audience: ["a@x.org"], gmailConnected: true, writer: nil))
        #expect(!ReplyPanel.canSend(body: "   \n  ", audience: ["a@x.org"], gmailConnected: true, writer: nil))
        #expect(ReplyPanel.canSend(body: "Sounds good.", audience: ["a@x.org"], gmailConnected: true, writer: nil))
    }

    // An audience of nobody means the send has no destination, so the button must refuse rather than
    // fail at the network and report it as an error Dan cannot act on.
    @Test func nothingSendsWithNobodyToSendTo() {
        #expect(!ReplyPanel.canSend(body: "Sounds good.", audience: [], gmailConnected: true, writer: nil))
    }

    @Test func nothingSendsWhileGmailIsDisconnected() {
        #expect(!ReplyPanel.canSend(body: "Sounds good.", audience: ["a@x.org"], gmailConnected: false, writer: nil))
    }

    // MARK: the audience Dan approves

    // L64: what he reviews has to include WHO it goes to. The panel states the audience outright rather
    // than only naming the extras, because it is the approval surface for the send.
    @Test func theAudienceIsStatedInFull() {
        #expect(ReplyPanel.audienceLine(["nbecker@everyvoicechoirs.org"])
                == "Goes to nbecker@everyvoicechoirs.org")
        #expect(ReplyPanel.audienceLine(["nbecker@everyvoicechoirs.org", "ray@elsewhere.example"])
                == "Goes to nbecker@everyvoicechoirs.org and ray@elsewhere.example")
    }

    // A panel with nobody to write to says so, rather than showing a bare "Goes to" with nothing after it.
    @Test func anEmptyAudienceSaysSoRatherThanTrailingOff() {
        #expect(ReplyPanel.audienceLine([]) == "No address to reply to")
    }

    // MARK: which contact the panel is about

    // The panel opens from a row that stands on the alphabetically first contact, but the reply, its
    // words and its audience all belong to whoever wrote. Everything the panel shows and sends must key
    // on that peer, or Dan answers Nicole and Overture emails Chelsea.
    @Test func thePanelIsAboutTheContactWhoWrote() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        for r in [chelsea, nicole] {
            r.replied = true
            r.replyFromAddress = "nbecker@everyvoicechoirs.org"
        }
        nicole.lastReplyText = "Thanks, that sounds good."
        nicole.replyAudience = ["nbecker@everyvoicechoirs.org"]

        let answering = ReplyIdentity.answering(for: chelsea, in: p)
        #expect(answering.id == nicole.id)
        #expect(ReplyPanel.theirWords(answering) == "Thanks, that sounds good.")
    }

    // Nothing was captured (a reply detected before the words were stored, or a reply-all somebody else
    // wrote). The panel says so plainly instead of showing an empty quote box.
    @Test func aReplyWithNoCapturedWordsSaysSo() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "solo@example.org", group: nil)
        r.replied = true
        #expect(ReplyPanel.theirWords(r) == nil)
    }

    // MARK: which rows offer the panel at all

    // Only a row where somebody is actually waiting on an answer. A silent row's next email is a
    // follow-up, which is a different thing entirely and is not written in this panel.
    @Test func onlyARowAwaitingAnAnswerOffersOne() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let silent = contact(p, "silent@example.org", group: nil)
        #expect(!ReplyPanel.isOffered(for: silent, in: p))

        let wrote = contact(p, "wrote@example.org", group: nil)
        wrote.replied = true
        #expect(ReplyPanel.isOffered(for: wrote, in: p))
    }

    // A row standing on the contact who did NOT write still offers the panel, because the answer is owed
    // on that thread and this is the only row the list shows for it.
    //
    // The shape is measured, not invented: on a shared thread ReplyService marks EVERY peer replied and
    // records the writer on each, filing only the WORDS with whoever wrote. The live store agrees, both
    // rows of Dan's one real joint send carry 2026-08-04 20:56.
    @Test func aRowStandingOnTheColleagueWhoDidNotWriteStillOffersOne() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let chelsea = contact(p, "chelsea@everyvoicechoirs.org")
        let nicole = contact(p, "nbecker@everyvoicechoirs.org")
        for r in [chelsea, nicole] {
            r.replied = true
            r.replyFromAddress = "nbecker@everyvoicechoirs.org"
        }
        nicole.lastReplyText = "Thanks, that sounds good."
        #expect(ReplyPanel.isOffered(for: chelsea, in: p))
        #expect(ReplyIdentity.answering(for: chelsea, in: p).id == nicole.id)
    }

    // A contact already resolved is not waiting on anything, so the panel is not offered on their row.
    @Test func aResolvedContactIsNotOfferedOne() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "done@example.org", group: nil)
        r.replied = true
        r.resolution = .declinedHard
        #expect(!ReplyPanel.isOffered(for: r, in: p))
    }

    // MARK: sending, and what survives a send that fails

    // The failure path Dan actually meets: Gmail refuses, and his words must not be lost. They are
    // written to the recipient BEFORE the send precisely so a failure leaves them stored, not living
    // only in a text box the panel is about to redraw (L5).
    @Test func aFailedSendKeepsTheWordsHeTyped() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "nbecker@everyvoicechoirs.org", group: nil)
        r.replied = true

        let sent = await ReplyPanel.commit(body: "Tuesday works, I will bring the 85mm.", on: r, of: p,
                                           now: Date(timeIntervalSince1970: 5_000), sender: AlwaysFailSender())
        #expect(sent == false, "a refused send must never report as sent")
        #expect(r.replyDraftBody == "Tuesday works, I will bring the 85mm.")
    }

    // And a send that works reports so, so the panel closes on a real send rather than a hopeful one.
    @Test func aSuccessfulSendReportsTrue() async throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = contact(p, "nbecker@everyvoicechoirs.org", group: nil)
        r.replied = true
        r.replyAudience = ["nbecker@everyvoicechoirs.org"]

        let sent = await ReplyPanel.commit(body: "Sounds good, see you then.", on: r, of: p,
                                           now: Date(timeIntervalSince1970: 5_000), sender: FakeReplySender())
        #expect(sent)
        // The send consumes the draft and freezes the committed copy, so the words Dan typed are what
        // went out and the box is not left holding a reply that has already gone.
        #expect(r.replyDraftBody == nil)
        #expect(r.sentReplyBody == "Sounds good, see you then.")
    }
}

private struct AlwaysFailSender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt { throw MailSenderError.notConfigured }
}

private struct FakeReplySender: MailSender {
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        SentReceipt(threadId: "t", messageID: "m-sent")
    }
}
