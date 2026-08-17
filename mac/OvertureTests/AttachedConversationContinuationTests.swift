import Testing
import Foundation
import SwiftData

// #2796: `AttachedConversation.refusalToContinue` had no caller anywhere in the shipping app, so #2717's
// refusal was built and unwired, and an unwired guard is indistinguishable from no guard (L3).
//
// WHY IT HAD NO CALLER, established from the code rather than assumed. #2717 wrote it for three send
// paths. The closing note is gone with #2710. The follow-up cannot reach an attached conversation at all,
// because `Recipient.isAwaitingFollowUp` demands `outreachChannel == .email` and an attached conversation
// only ever sits on a `.contactForm` row. And both reply paths were deliberately exempted, on the
// reasoning that answering threads on THEIR message, which an attached conversation has.
//
// That last verdict is right in the ordinary case and wrong in one: `ReplyThreading.inReplyTo` falls back
// to `gmailMessageId`, which an attached conversation never has, so a row that replied with no readable
// `Message-ID` of theirs leaves the answer with NOTHING to hang off. Overture would then drop an
// unparented message into a conversation it never sent on, which is #2647, #2649 and #2653's defect
// arriving by exactly the new route #2717 was filed to close.
//
// So the refusal is wired to the state that is actually wrong (attached AND no parent) rather than to
// every attached row, which keeps the milestone's central promise, full parity once attached, true. Every
// refusal here is checked against what it must still PERMIT (L104).
@MainActor
@Suite("Continuing a conversation Overture never sent on (#2796)")
struct AttachedConversationContinuationTests {
    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let me = "dan@danwrightphotography.com"
    private let them = "priya.raman@example.com"

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // MARK: fixtures

    // A form pitch with a conversation attached: a thread Dan linked, the address they wrote from, and,
    // by design, no `gmailMessageId` ever, because Overture sent nothing here. `theirMessageId` is the
    // one fact this suite turns on: nil is a reply detected off a message carrying no `Message-ID`.
    private func attachedFormPitch(_ ctx: ModelContext,
                                   theirMessageId: String?) -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "54 Sings|2027-08-17", groupName: "54 Sings Shuffle Along",
                         discipline: "theater", venue: "The Green Room 42",
                         performanceDate: "2027-08-17", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .drafted)
        p.draftSubject = "Photographing 54 Sings Shuffle Along."
        p.draftBody = "Hello,"
        ctx.insert(p)
        let form = "https://caseengaines.example/contact"
        let r = Recipient(id: Recipient.makeId(email: nil, formURL: form)!, email: nil,
                          name: "Caseen Gaines", provenance: .act,
                          contactMethodRaw: ContactMethod.formOrDM.rawValue, contactFormURL: form)
        p.setRecipients([r])
        p.recordFormOutreach(r, now: now.addingTimeInterval(-20 * 86_400), formURL: form)
        r.gmailThreadId = "thread-abc"
        r.attachedThreadSubject = "Photography for the anniversary show"
        r.conversationAttachedAt = now.addingTimeInterval(-3600)
        r.email = "caseen.gaines@gmail.example"
        r.replied = true
        r.repliedAt = now.addingTimeInterval(-86_400)
        r.inboundReplyMessageId = theirMessageId
        return (p, r)
    }

    // An ordinary emailed contact whose send receipt could not be read back (#2647): no stored id of
    // Overture's and no id of theirs either. The conversation is still Overture's own.
    private func emailedContactWithNoStoredIds(_ ctx: ModelContext) -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "Aurora|2027-08-17", groupName: "Aurora Strings", discipline: "music",
                         venue: "Jalopy", performanceDate: "2027-08-17", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .contacted)
        p.draftSubject = "Photographing Aurora Strings at Jalopy."
        p.draftBody = "Hello,"
        ctx.insert(p)
        let r = Recipient(id: "jake@aurorastrings.example", email: "jake@aurorastrings.example",
                          name: "Jake Berg", provenance: .act)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-20 * 86_400)
        r.gmailThreadId = "thread-real"
        r.gmailMessageId = nil
        r.threadingDegraded = true
        r.replied = true
        r.repliedAt = now.addingTimeInterval(-86_400)
        p.setRecipients([r])
        p.sentAt = r.sentAt
        return (p, r)
    }

    // An inquiry with a conversation attached by #2712's sweep: a thread, no message of Overture's.
    private func attachedInquiry(_ ctx: ModelContext, theirMessageId: String?) -> Inquiry {
        let i = Inquiry(source: .directEmail, inquirerName: "Priya Raman", inquirerEmail: them,
                        eventName: "Spring gala", performanceDate: nil, venue: "Merkin Hall",
                        notes: nil, createdAt: now.addingTimeInterval(-4 * 86_400))
        ctx.insert(i)
        i.gmailThreadId = "thread-1"
        i.conversationAttachedAt = now.addingTimeInterval(-3600)
        i.replied = true
        i.repliedAt = now.addingTimeInterval(-3600)
        i.inboundReplyMessageId = theirMessageId
        return i
    }

    // MARK: the prospect reply path

    // The refusal, on the send that would actually do it. Driven through `SendService.sendReplyDraft`
    // rather than by asking the predicate, because the predicate answering correctly is what the code
    // already did and it protected nothing (L3).
    @Test("answering a linked conversation is refused when there is nothing to thread the answer off")
    func theProspectReplyPathRefusesAnUnparentedAnswer() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = attachedFormPitch(ctx, theirMessageId: nil)
        r.replyDraftBody = "Thanks for getting back to me."
        let sender = RecordingSender()

        let sent = await SendService.sendReplyDraft(r, of: p, now: now, sender: sender)

        #expect(!sent)
        #expect(sender.sent.isEmpty)
        // Refused BEFORE the claim, so a refusal cannot leave the send held on a reply that never went.
        #expect(r.replySendClaimedAt == nil)
        // And nothing recorded as answered, which would take the row off Dan's list on the strength of a
        // message that does not exist (L12).
        #expect(r.replyHandledAt == nil)
    }

    // The half that keeps the guard from being an over-refusal reading exactly like the feature working
    // (L104). This is the ordinary attached row and the whole point of attaching one.
    @Test("answering a linked conversation still works when their message is known")
    func theProspectReplyPathStillAnswersAParentedReply() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = attachedFormPitch(ctx, theirMessageId: "<theirs@mail.gmail.com>")
        r.replyDraftBody = "Thanks for getting back to me."
        let sender = RecordingSender()

        let sent = await SendService.sendReplyDraft(r, of: p, now: now, sender: sender)

        #expect(sent)
        #expect(sender.sent.first?.inReplyTo == "<theirs@mail.gmail.com>")
        #expect(sender.sent.first?.threadId == "thread-abc")
    }

    // The other half: a conversation Overture DID send on, whose ids were merely lost when the receipt
    // could not be read back. Imperfect nesting there is a great deal better than refusing a working
    // control, and the refusal must not reach it: this is Overture's own conversation.
    @Test("a real send whose ids were lost is still answerable")
    func aRealSendWithNoStoredIdsIsStillAnswerable() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = emailedContactWithNoStoredIds(ctx)
        r.replyDraftBody = "Thanks for getting back to me."
        let sender = RecordingSender()

        #expect(!r.replyWatchConversationIsAttached)
        let sent = await SendService.sendReplyDraft(r, of: p, now: now, sender: sender)

        #expect(sent)
        #expect(sender.sent.count == 1)
    }

    // MARK: the inquiry reply path

    // #2795 gave `gmailThreadId` a second writer on a second entity, so the same refusal has to reach the
    // send that answers an inquiry. It is a separate function from the prospect one by design
    // (`InquiryReplySender` is not `SendService`), so a guard on one says nothing about the other.
    @Test("answering a linked inquiry conversation is refused when there is nothing to thread off")
    func theInquiryReplyPathRefusesAnUnparentedAnswer() async throws {
        let ctx = ModelContext(try container())
        let i = attachedInquiry(ctx, theirMessageId: nil)
        let sender = RecordingSender()

        let sent = await InquiryReplySender.sendReply(i, subject: "Re: your inquiry",
                                                      body: "Thursday works.", now: now, sender: sender)

        #expect(!sent)
        #expect(sender.sent.isEmpty)
        // Nothing recorded as sent, so the row cannot read as answered on a message that never left.
        #expect(i.sentAt == nil)
        #expect(i.replied)
    }

    @Test("answering a linked inquiry conversation still works when their message is known")
    func theInquiryReplyPathStillAnswersAParentedReply() async throws {
        let ctx = ModelContext(try container())
        let i = attachedInquiry(ctx, theirMessageId: "<second@mail.gmail.com>")
        let sender = RecordingSender()

        let sent = await InquiryReplySender.sendReply(i, subject: "Re: your inquiry",
                                                      body: "Thursday works.", now: now, sender: sender)

        #expect(sent)
        #expect(sender.sent.first?.inReplyTo == "<second@mail.gmail.com>")
        #expect(sender.sent.first?.threadId == "thread-1")
    }

    // MARK: the state is real, not invented

    // L48: a fixture claiming to stand for something the shipping code produces has to be MEASURED from
    // it. Detection records the reply off the Gmail message resource `id`, which every message has, and
    // takes the parent from the `Message-ID` HEADER, which not every message carries. So a thread whose
    // newest inbound message has no such header produces exactly the state the guard refuses, through the
    // shipping attach, with nothing set by hand.
    @Test("a reply with no Message-ID header is what puts a linked conversation in the refused state")
    func detectionOverAHeaderlessReplyProducesTheRefusedState() throws {
        let ctx = ModelContext(try container())
        let i = Inquiry(source: .directEmail, inquirerName: "Priya Raman", inquirerEmail: them,
                        eventName: "Spring gala", performanceDate: nil, venue: "Merkin Hall",
                        notes: nil, createdAt: now.addingTimeInterval(-4 * 86_400))
        ctx.insert(i)

        let outcome = AttachConversation.attach(threadId: "thread-1",
                                                threadJSON: headerlessInboundThread(),
                                                to: i, selfEmail: me, now: now)

        guard case .attached = outcome else { Issue.record("expected an attach, got \(outcome)"); return }
        #expect(i.replied)                       // the row says somebody is waiting on him
        #expect(i.inboundReplyMessageId == nil)  // and there is nothing to thread an answer off
        #expect(AttachedConversation.refusalToContinue(i, displayName: i.replyWatchDisplayName) != nil)
    }

    // MARK: what Dan sees before he presses

    // The refusal reaches the screen from the same value that enforces it, so the Send button cannot be
    // disabled beside a line claiming everything is fine (L109). Asserted as the SPECIFIC case rather
    // than merely non-nil, because every other refusal on this panel would also be non-nil and would
    // answer this test for a reason it is not about.
    @Test("the reply panel says why rather than letting the send fail at the wire")
    func thePanelStatesTheRefusal() throws {
        let ctx = ModelContext(try container())
        let (p, r) = attachedFormPitch(ctx, theirMessageId: nil)
        let composition = ReplyComposition.answering(r, of: p, context: ctx, feedback: ActionFeedback())

        let refusal = composition.refusal(body: "Thanks for getting back to me.", gmailConnected: true)

        #expect(refusal == .cannotContinue(
            AttachedConversationCopy.cannotContinue(groupName: "54 Sings Shuffle Along")))
        #expect(ReplyPanelCopy.refusalLine(refusal) ==
                AttachedConversationCopy.cannotContinue(groupName: "54 Sings Shuffle Along"))
    }

    // The same panel, on the same row, once their message is known: nothing is refused. Without this the
    // test above passes just as well on a panel that refuses everything.
    @Test("the reply panel refuses nothing once their message is known")
    func thePanelPermitsAParentedReply() throws {
        let ctx = ModelContext(try container())
        let (p, r) = attachedFormPitch(ctx, theirMessageId: "<theirs@mail.gmail.com>")
        let composition = ReplyComposition.answering(r, of: p, context: ctx, feedback: ActionFeedback())

        #expect(composition.refusal(body: "Thanks for getting back to me.", gmailConnected: true) == nil)
    }

    // And the inquiry panel, which reaches a different send path and so needs its own answer.
    @Test("the inquiry reply panel states the same refusal")
    func theInquiryPanelStatesTheRefusal() throws {
        let ctx = ModelContext(try container())
        let i = attachedInquiry(ctx, theirMessageId: nil)
        let composition = ReplyComposition.answering(i, context: ctx, feedback: ActionFeedback())

        #expect(composition.refusal(body: "Thursday works.", gmailConnected: true)
                == .cannotContinue(AttachedConversationCopy.cannotContinue(groupName: "Priya Raman")))
        #expect(ReplyComposition.answering(attachedInquiry(ctx, theirMessageId: "<second@mail.gmail.com>"),
                                           context: ctx, feedback: ActionFeedback())
            .refusal(body: "Thursday works.", gmailConnected: true) == nil)
    }

    // MARK: fixtures

    // One inbound message, carrying no `Message-ID` header, which is the whole point of it. Built the way
    // `InquiryConversationAttachTests` builds a thread, because a second shape here would only ever
    // confirm an assumption about an interface nobody read (L52).
    private func headerlessInboundThread() -> Data {
        let at = Int64(now.timeIntervalSince1970) - 3600
        let payload: [String: Any] = [
            "id": "msg-1",
            "internalDate": "\(at * 1000)",
            "payload": ["headers": [["name": "From", "value": "Priya Raman <\(them)>"],
                                    ["name": "Subject", "value": "Photography for our spring gala"]]]
        ]
        return try! JSONSerialization.data(withJSONObject: ["messages": [payload]])
    }
}

// Records every mail handed to it, so a refusal can be told apart from a send that happened to fail.
private final class RecordingSender: MailSender, @unchecked Sendable {
    var sent: [OutgoingMail] = []
    func send(_ mail: OutgoingMail) async throws -> SentReceipt {
        sent.append(mail)
        return SentReceipt(threadId: mail.threadId ?? "t", messageID: "<sent@mail.gmail.com>")
    }
}
