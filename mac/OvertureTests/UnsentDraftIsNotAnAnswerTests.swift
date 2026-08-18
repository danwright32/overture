import Testing
import Foundation
import SwiftData

// #2918. Dan starts a reply in Gmail, gets pulled away, and never sends it. Gmail keeps that draft on the
// thread, and `threads.get` returns it inside `messages` alongside real mail, carrying his own address in
// its `From` header and an `internalDate` newer than the reply it answers.
//
// Nothing on this path had ever looked at `labelIds`, so every reader that asks "did Dan write last" read
// the draft as his answer. `AnsweredElsewhere.answeredAt` then stamped `replyHandledAt`, `hasUnhandledReply`
// went false, and `markReplyAnswered` never moves the stamp backwards, so the reply was silenced for good:
// no badge, no task, nothing asking.
//
// Measured on a live thread on 2026-08-17: an abandoned draft sat 29 minutes above a real reply. Any
// reply-check tick inside that window would have buried it. It escaped by timing alone.
//
// The evidence Gmail already hands over is the label: a message his mailbox really sent carries `SENT`,
// and one he is still composing carries `DRAFT`. Both formats this app asks for (`format=metadata` and
// `format=full`) return `labelIds` on every message, so nothing extra is fetched to answer it.
//
// A message carrying NO label information at all is REFUSED rather than accepted. An absent field is not
// evidence that a message was sent, and the two failures are not symmetrical: a row wrongly cleared hides
// a real reply for ever, where a row wrongly left asking costs a glance (L42, L98).
//
// The people, addresses and words below are invented. Nothing here is anybody's real conversation.
@MainActor
@Suite("An unsent Gmail draft is not an answer (#2918)")
struct UnsentDraftIsNotAnAnswerTests {

    private static let me = "dan@danwrightphotography.com"
    private static let them = "priya.raman@example.com"

    private let theyWrote = Date(timeIntervalSince1970: 5_000)
    private let heDraftedIt = Date(timeIntervalSince1970: 9_000)
    private let heActuallySent = Date(timeIntervalSince1970: 7_000)
    private let now = Date(timeIntervalSince1970: 30_000)

    // MARK: - Threads, as Gmail's `threads.get` really returns them

    private enum Who { case dan, them }

    /// `labels` is what Gmail puts in `labelIds`. `nil` means the field is absent from the message
    /// altogether, which is the state the refusal has to fail closed on.
    private static func message(_ id: String, from who: Who, at sentAt: Date,
                                labels: [String]?, messageID: String? = nil,
                                text: String = "Some words.") -> [String: Any] {
        var headers: [[String: Any]] = [
            ["name": "From", "value": who == .dan ? me : "Priya Raman <\(them)>"],
            ["name": "To", "value": who == .dan ? them : me],
            ["name": "Subject", "value": "Re: Photography for the spring gala"],
        ]
        if let messageID { headers.append(["name": "Message-ID", "value": messageID]) }
        let body = Data(text.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var m: [String: Any] = [
            "id": id,
            "internalDate": "\(Int(sentAt.timeIntervalSince1970) * 1000)",
            "payload": ["headers": headers, "mimeType": "text/plain", "body": ["data": body]] as [String: Any],
        ]
        if let labels { m["labelIds"] = labels }
        return m
    }

    private static func thread(_ messages: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["messages": messages])
    }

    /// His pitch, their reply, and then a message of his on top. What that last message IS is the whole
    /// question, so its labels are the parameter.
    private func conversation(hisLastMessageLabels labels: [String]?,
                              hisLastMessageAt when: Date? = nil) -> Data {
        Self.thread([
            Self.message("m-0", from: .dan, at: Date(timeIntervalSince1970: 1_000), labels: ["SENT"],
                         messageID: "<pitch@mail.gmail.com>", text: "My pitch."),
            Self.message("r-1", from: .them, at: theyWrote, labels: ["INBOX"],
                         messageID: "<theirs@mail.gmail.com>", text: "What's your rate?"),
            Self.message("m-1", from: .dan, at: when ?? heDraftedIt, labels: labels,
                         messageID: "<his-latest@mail.gmail.com>", text: "It's $250 an hour."),
        ])
    }

    /// Their reply with nothing of his after it.
    private var stillWaiting: Data {
        Self.thread([
            Self.message("m-0", from: .dan, at: Date(timeIntervalSince1970: 1_000), labels: ["SENT"],
                         messageID: "<pitch@mail.gmail.com>", text: "My pitch."),
            Self.message("r-1", from: .them, at: theyWrote, labels: ["INBOX"],
                         messageID: "<theirs@mail.gmail.com>", text: "What's your rate?"),
        ])
    }

    // MARK: - The store, and the pipeline that reads it

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Fernbrook Players", discipline: "theatre",
                         venue: "Willow Street Playhouse", performanceDate: "2026-11-14",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        ctx.insert(p)
        return p
    }

    @discardableResult
    private func contact(_ p: Prospect) -> Recipient {
        let r = Recipient(id: Self.them, email: Self.them, provenance: .presenter)
        r.sendState = .sent
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.gmailMessageId = "msg-1"
        r.gmailThreadId = "t"
        r.sendGroupId = "t"
        p.addRecipient(r)
        return r
    }

    private final class StubGmail {
        var body: Data
        init(body: Data) { self.body = body }
        var fetch: (URLRequest) async throws -> (Data, URLResponse) {
            { req in (self.body, HTTPURLResponse(url: req.url!, statusCode: 200,
                                                 httpVersion: nil, headerFields: nil)!) }
        }
    }

    private func check(_ ctx: ModelContext, thread: Data, at when: Date) async {
        await GmailReplyChecker(fromEmail: Self.me)
            .markReplies(in: ctx, token: "tok", now: when, fetch: StubGmail(body: thread).fetch)
    }

    /// Reached through the shipping pipeline rather than by hand: they wrote, and nothing has answered.
    private func waitingOnHim(_ ctx: ModelContext) async -> Recipient {
        let r = contact(show(ctx))
        await check(ctx, thread: stillWaiting, at: theyWrote)
        return r
    }

    // MARK: - The defect, through the pipeline that produced it

    @Test("an abandoned draft above their reply does not silence it")
    func anAbandonedDraftDoesNotSilenceTheReply() async throws {
        let ctx = ModelContext(try container())
        let r = await waitingOnHim(ctx)
        #expect(r.hasUnhandledReply, "the premise: they wrote and nothing has answered")

        await check(ctx, thread: conversation(hisLastMessageLabels: ["DRAFT"]), at: now)

        #expect(r.hasUnhandledReply, "he never sent it, so the row must go on asking")
        #expect(r.replyHandledAt == nil)
    }

    /// The control for the refusal above, in the SAME fixture with one field changed (L159). Without it
    /// the refusal could be "this thread is unreadable" rather than "that message was never sent".
    @Test("the same message carrying SENT does clear the row")
    func aSentMessageStillClearsTheRow() async throws {
        let ctx = ModelContext(try container())
        let r = await waitingOnHim(ctx)

        await check(ctx, thread: conversation(hisLastMessageLabels: ["SENT"]), at: now)

        #expect(!r.hasUnhandledReply)
        #expect(r.replyHandledAt == heDraftedIt)
    }

    /// Fail closed. A message with no `labelIds` at all says nothing about whether it was ever sent, and
    /// treating silence as a yes is how this defect works in the first place.
    @Test("a message carrying no label information is refused, not accepted")
    func aMessageWithNoLabelsIsRefused() async throws {
        let ctx = ModelContext(try container())
        let r = await waitingOnHim(ctx)

        await check(ctx, thread: conversation(hisLastMessageLabels: nil), at: now)

        #expect(r.hasUnhandledReply, "nothing shows this message was ever sent, so it cannot answer")
        #expect(r.replyHandledAt == nil)
    }

    /// A draft is not a message anybody has seen, so it is skipped rather than fatal: a real answer of his
    /// underneath an abandoned draft still counts, and is dated by the SENT message rather than the draft.
    @Test("a draft sitting above a real answer of his does not hide it")
    func aDraftAboveARealAnswerDoesNotHideIt() async throws {
        let ctx = ModelContext(try container())
        let r = await waitingOnHim(ctx)
        let thread = Self.thread([
            Self.message("m-0", from: .dan, at: Date(timeIntervalSince1970: 1_000), labels: ["SENT"],
                         text: "My pitch."),
            Self.message("r-1", from: .them, at: theyWrote, labels: ["INBOX"], text: "What's your rate?"),
            Self.message("m-1", from: .dan, at: heActuallySent, labels: ["SENT"], text: "It's $250 an hour."),
            Self.message("m-2", from: .dan, at: heDraftedIt, labels: ["DRAFT"], text: "One more thought"),
        ])

        await check(ctx, thread: thread, at: now)

        #expect(!r.hasUnhandledReply)
        #expect(r.replyHandledAt == heActuallySent, "dated by the message he sent, not by the one he did not")
    }

    // MARK: - The same defect at the ATTACH, which stamps the same field (#2715)

    private func formPitch(_ ctx: ModelContext, on p: Prospect) -> Recipient {
        let r = Recipient(id: "form:https://example.com/contact", email: nil,
                          name: "Priya Raman", provenance: .act)
        r.contactFormURL = "https://example.com/contact"
        r.formOutreachURL = "https://example.com/contact"
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = Date(timeIntervalSince1970: 1)
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        p.addRecipient(r)
        return r
    }

    @Test("the attach does not read a draft as an answer Dan already gave")
    func theAttachRefusesADraft() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        let outcome = AttachConversation.attach(
            threadId: "t1", threadJSON: conversation(hisLastMessageLabels: ["DRAFT"]),
            subject: "Re: Photography for the spring gala", fromAddress: Self.them,
            to: r, on: p, ledger: .none, selfEmail: Self.me, now: now)

        #expect(outcome == .attached(repliesDetected: 1, alreadyAnswered: false))
        #expect(r.replyHandledAt == nil, "he never sent it, so the linked row must still ask")
        #expect(r.hasUnhandledReply)
    }

    /// And the attach fails closed on the same evidence the unattended pass does. Its own test rather
    /// than the pass's, because the draft filter alone already answers the DRAFT case here (the newest
    /// real message becomes theirs), so the label requirement at this call site is only observable on a
    /// message that claims nothing: without this the guard could be deleted and the suite stay green.
    @Test("the attach refuses a message of his carrying no label information")
    func theAttachRefusesAMessageWithNoLabels() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        let outcome = AttachConversation.attach(
            threadId: "t1", threadJSON: conversation(hisLastMessageLabels: nil),
            subject: "Re: Photography for the spring gala", fromAddress: Self.them,
            to: r, on: p, ledger: .none, selfEmail: Self.me, now: now)

        #expect(outcome == .attached(repliesDetected: 1, alreadyAnswered: false))
        #expect(r.replyHandledAt == nil, "nothing shows this message was ever sent")
        #expect(r.hasUnhandledReply)
    }

    /// The control for the attach, same fixture, label changed.
    @Test("the attach still reads a sent message as an answer Dan already gave")
    func theAttachAcceptsASentMessage() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        let outcome = AttachConversation.attach(
            threadId: "t1", threadJSON: conversation(hisLastMessageLabels: ["SENT"]),
            subject: "Re: Photography for the spring gala", fromAddress: Self.them,
            to: r, on: p, ledger: .none, selfEmail: Self.me, now: now)

        #expect(outcome == .attached(repliesDetected: 1, alreadyAnswered: true))
        #expect(r.replyHandledAt == now)
    }

    // MARK: - The two other readers that answer "what did Dan send"

    /// `AttachConversation.attach(to: Inquiry)` dates an inquiry from this. A draft would date the answer
    /// from a message that never went, and the follow-up nudge, the closing suggestion and the day it
    /// groups under all hang off that stamp.
    @Test("an inquiry is never dated from a message Dan never sent")
    func anInquiryIsNeverDatedFromADraft() {
        #expect(ReplyDetection.latestSentMessageSentAt(
            threadJSON: conversation(hisLastMessageLabels: ["DRAFT"]), selfEmail: Self.me) != heDraftedIt)
        // The control: the same thread, the same message, sent.
        #expect(ReplyDetection.latestSentMessageSentAt(
            threadJSON: conversation(hisLastMessageLabels: ["SENT"]), selfEmail: Self.me) == heDraftedIt)
        // And no label information is refused outright rather than dated.
        #expect(ReplyDetection.latestSentMessageSentAt(
            threadJSON: Self.thread([Self.message("m-1", from: .dan, at: heDraftedIt, labels: nil)]),
            selfEmail: Self.me) == nil)
    }

    /// `GmailThreadingRepair` stores this as the message Overture's next follow-up threads off. A draft's
    /// Message-ID would thread his next mail onto something nobody ever received.
    @Test("the threading repair never references a message Dan never sent")
    func theThreadingRepairNeverReferencesADraft() {
        #expect(ReplyDetection.latestSentMessageID(
            threadJSON: conversation(hisLastMessageLabels: ["DRAFT"]),
            selfEmail: Self.me) == "<pitch@mail.gmail.com>", "his real send underneath it, never the draft")
        // The control: sent, and it is the one referenced.
        #expect(ReplyDetection.latestSentMessageID(
            threadJSON: conversation(hisLastMessageLabels: ["SENT"]),
            selfEmail: Self.me) == "<his-latest@mail.gmail.com>")
        // No label information: refused, so nothing is stored, rather than a guess being stored.
        #expect(ReplyDetection.latestSentMessageID(
            threadJSON: Self.thread([Self.message("m-1", from: .dan, at: heDraftedIt, labels: nil,
                                                  messageID: "<unknown@mail.gmail.com>")]),
            selfEmail: Self.me) == nil)
    }

    // MARK: - The plumbing this rests on

    /// Everything above assumes Gmail already hands over `labelIds`, which it does on every format this
    /// app asks for. The ONE way to lose it is a `fields=` partial response, which would trim the field
    /// off and make every reader above fail closed on threads that are perfectly fine, quietly, across
    /// the whole store at once. Nothing here uses one today; this is what keeps it that way.
    @Test("no thread fetch trims Gmail's response down to a field list")
    func theThreadFetchesNeverTrimTheResponse() {
        for file in ["Overture/Integration/GmailReplyChecker.swift",
                     "Overture/Integration/GmailThreadingRepair.swift",
                     "Overture/Integration/ConfirmProposedConversation.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(source.contains("gmail.googleapis.com"), "\(file) should hold the thread fetch")
            #expect(!source.contains("fields="),
                    "\(file) asks Gmail for a partial response, and labelIds would go with it")
        }
    }

    // MARK: - What must NOT change

    /// The inbound half is a separate question and this must not disturb it. A draft of his sitting on the
    /// thread is still not a reply from anybody, and their reply underneath it is still found.
    @Test("a draft of his is still not a reply, and does not hide theirs")
    func aDraftIsStillNotAReplyAndDoesNotHideTheirs() {
        let thread = conversation(hisLastMessageLabels: ["DRAFT"])

        #expect(ReplyDetection.hasReply(
            fromAddresses: ReplyDetection.fromAddresses(threadJSON: thread), selfEmail: Self.me))
        #expect(ReplyDetection.latestReplyId(threadJSON: thread, selfEmail: Self.me) == "r-1")
        #expect(ReplyDetection.latestReplySender(threadJSON: thread, selfEmail: Self.me) == Self.them)
    }
}
