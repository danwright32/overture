import Testing
import Foundation
import SwiftData

// #2653: Dan's approved reply threaded off `recipient.gmailMessageId`, which is the id of OVERTURE'S OWN
// last outgoing message, not the id of the message being answered.
//
// `In-Reply-To` is defined as the message this one is a direct response to. Pointing it at Dan's previous
// email makes the contact's reply a sibling of Dan's answer rather than its parent, so a client that
// draws the conversation as a tree hangs his answer off his own earlier message instead of under theirs.
//
// The correct parent was being FETCHED AND DISCARDED: `ReplyService` and `GmailReplyChecker` read the
// thread to detect a reply and extract its text, and neither kept the id of the message they found
// (confirmed by reading every writer of the field, and nothing in the app stored an incoming
// `Message-ID` at all).
//
// Lower severity than #2647, #2648 and #2649 on purpose: the whole conversation still threads, because
// the ancestry links up through the shared chain. This is nesting and attribution.
@MainActor
@Suite("A reply answers their message, not our own (#2653)")
struct ReplyAnswersTheirMessageTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A Gmail thread as the API returns it: Dan's send, then their answer.
    private func thread(theirMessageID: String = "<theirs@example.com>") -> Data {
        let json = """
        {"messages": [
          {"internalDate": "1000",
           "payload": {"headers": [
             {"name": "From", "value": "Dan Wright <dwright@danwrightphotography.com>"},
             {"name": "Message-ID", "value": "<ours@mail.gmail.com>"}]}},
          {"internalDate": "2000",
           "payload": {"headers": [
             {"name": "From", "value": "Nora Vance <nora@example.com>"},
             {"name": "Message-ID", "value": "\(theirMessageID)"}]}}
        ]}
        """
        return Data(json.utf8)
    }

    private let me = "dwright@danwrightphotography.com"

    // MARK: - Reading their id off the thread

    // The mirror of `latestSentMessageID`, which reads the newest message DAN sent. This one reads the
    // newest real reply, through the same `latestReplyMessage` every other inbound reader here uses, so
    // "which message" cannot be answered two ways.
    @Test func theNewestRealReplyNamesItsOwnMessageId() {
        #expect(ReplyDetection.latestReplyMessageID(threadJSON: thread(), selfEmail: me)
                == "<theirs@example.com>")
    }

    // Dan's own message is never the answer, whichever way round the thread arrives, or the fix would
    // reintroduce the defect by a different route.
    @Test func aThreadWithNothingButDansOwnMessagesNamesNoReply() {
        let onlyMine = Data("""
        {"messages": [{"internalDate": "1000", "payload": {"headers": [
          {"name": "From", "value": "dwright@danwrightphotography.com"},
          {"name": "Message-ID", "value": "<ours@mail.gmail.com>"}]}}]}
        """.utf8)
        #expect(ReplyDetection.latestReplyMessageID(threadJSON: onlyMine, selfEmail: me) == nil)
    }

    // A reply that carries no Message-ID at all reads as nil rather than as an empty string, so the
    // caller can tell "not known" from a value and fall back rather than emitting an empty header.
    @Test func aReplyWithNoMessageIdHeaderNamesNothing() {
        let noID = Data("""
        {"messages": [{"internalDate": "2000", "payload": {"headers": [
          {"name": "From", "value": "nora@example.com"}]}}]}
        """.utf8)
        #expect(ReplyDetection.latestReplyMessageID(threadJSON: noID, selfEmail: me) == nil)
    }

    // MARK: - Storing it where the answer can reach it

    // Captured in `recordWriter`, the ONE place inbound reply facts are read off a thread, shared by first
    // detection and the backfill so the two cannot disagree about which message wrote.
    @Test func theCaptureStoresTheirMessageIdOnTheContact() throws {
        let ctx = ModelContext(try container())
        let r = Recipient(id: "nora@example.com", email: "nora@example.com", provenance: .act)
        ctx.insert(r)

        ReplyService.recordWriterForTesting(on: r, threadJSON: thread(), selfEmail: me)

        #expect(r.inboundReplyMessageId == "<theirs@example.com>")
        // And the facts it already captured are untouched.
        #expect(r.replyFromAddress == "nora@example.com")
    }

    // MARK: - The send that uses it

    // The defect itself, at the only place it shows: the header Dan's answer carries.
    @Test func theAnswerNamesTheirMessageAsItsParent() throws {
        let r = Recipient(id: "nora@example.com", email: "nora@example.com", provenance: .act)
        r.gmailMessageId = "<ours@mail.gmail.com>"
        r.inboundReplyMessageId = "<theirs@example.com>"

        #expect(ReplyThreading.inReplyTo(for: r) == "<theirs@example.com>")
    }

    // A reply detected before this shipped carries no inbound id, and the answer still has to thread.
    // Falling back to our own last message is exactly today's behaviour, which is imperfect nesting rather
    // than a broken thread, so it degrades to what it always did rather than to nothing (L5).
    @Test func aReplyDetectedBeforeThisShippedStillThreads() throws {
        let r = Recipient(id: "nora@example.com", email: "nora@example.com", provenance: .act)
        r.gmailMessageId = "<ours@mail.gmail.com>"

        #expect(ReplyThreading.inReplyTo(for: r) == "<ours@mail.gmail.com>")
    }

    // The ancestry keeps BOTH, and in order. Their message is the new parent, and Dan's own earlier
    // message stays in the chain: dropping it would be #2648's defect arriving by a new route, since a
    // client that threads by walking References would lose the link back through his side of it.
    @Test func theAncestryKeepsOurOwnMessageAsWellAsTheirs() throws {
        let r = Recipient(id: "nora@example.com", email: "nora@example.com", provenance: .act)
        r.gmailReferences = "<first@mail.gmail.com>"
        r.gmailMessageId = "<ours@mail.gmail.com>"
        r.inboundReplyMessageId = "<theirs@example.com>"

        #expect(ReplyThreading.references(for: r)
                == "<first@mail.gmail.com> <ours@mail.gmail.com> <theirs@example.com>")
    }

    @Test func theAncestryDegradesToTodaysChainWhenTheirIdIsUnknown() throws {
        let r = Recipient(id: "nora@example.com", email: "nora@example.com", provenance: .act)
        r.gmailReferences = "<first@mail.gmail.com>"
        r.gmailMessageId = "<ours@mail.gmail.com>"

        #expect(ReplyThreading.references(for: r) == "<first@mail.gmail.com> <ours@mail.gmail.com>")
    }

    // MARK: - Wired, not merely built

    // A rule the send does not call is no rule (L3). This drives the real prospect reply path and reads
    // the header off the mail it actually handed to the sender.
    @Test func theProspectReplySendCarriesTheirMessageAsItsParent() async throws {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: "V",
                         performanceDate: "2026-09-12", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        ctx.insert(p)
        let r = Recipient(id: "nora@example.com", email: "nora@example.com", provenance: .act)
        r.gmailThreadId = "thread-1"
        r.gmailMessageId = "<ours@mail.gmail.com>"
        r.inboundReplyMessageId = "<theirs@example.com>"
        r.replyDraftBody = "Happy to help."
        p.setRecipients([r])

        let sender = ReplyCapturingSender()
        #expect(await SendService.sendReplyDraft(r, of: p, now: Date(), sender: sender))

        let mail = try #require(sender.sent)
        #expect(mail.inReplyTo == "<theirs@example.com>")
        #expect(mail.references == "<ours@mail.gmail.com> <theirs@example.com>")
    }

    // MARK: - The inquiry side, which is the same conversation shape

    // An inquiry is a conformer of the same protocol and answers the same way, so the rule is one
    // implementation rather than two that can drift (#2661 threaded this path; this is which message it
    // threads ONTO).
    @Test func anInquiryAnswersTheirMessageToo() throws {
        let ctx = ModelContext(try container())
        let i = Inquiry(source: .directEmail, inquirerName: "Nora Vance",
                        inquirerEmail: "nora@example.com", eventName: "A recital")
        ctx.insert(i)
        i.gmailMessageId = "<ours@mail.gmail.com>"
        i.inboundReplyMessageId = "<theirs@example.com>"

        #expect(ReplyThreading.inReplyTo(for: i) == "<theirs@example.com>")
    }

    @Test func theInquiryReplySendCarriesTheirMessageAsItsParent() async throws {
        let ctx = ModelContext(try container())
        let i = Inquiry(source: .directEmail, inquirerName: "Nora Vance",
                        inquirerEmail: "nora@example.com", eventName: "A recital")
        ctx.insert(i)
        i.gmailThreadId = "thread-1"
        i.gmailMessageId = "<ours@mail.gmail.com>"
        i.inboundReplyMessageId = "<theirs@example.com>"

        let sender = ReplyCapturingSender()
        #expect(await InquiryReplySender.sendReply(i, subject: "s", body: "b", now: Date(),
                                                   sender: sender))

        let mail = try #require(sender.sent)
        #expect(mail.inReplyTo == "<theirs@example.com>")
        #expect(mail.references == "<ours@mail.gmail.com> <theirs@example.com>")
    }
}

// Captures the mail it was handed, so the headers a real send path builds can be asserted with no
// network and no live mailbox (L2).
private final class ReplyCapturingSender: MailSender, @unchecked Sendable {
    var sent: OutgoingMail?
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        sent = mail
        return SentReceipt(threadId: "thread-1", messageID: "<new@mail.gmail.com>")
    }
}
