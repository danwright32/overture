import Testing
import Foundation
import SwiftData

// #2717: a non-empty `gmailThreadId` has until now meant exactly one thing, that Overture sent an email
// on this conversation. Milestone #58 gives that field a SECOND writer (#2715, Dan attaching the Gmail
// conversation a form or DM pitch was answered on), and every reader carrying the old assumption is
// wrong the moment it does (L55).
//
// The readers were derived from the code rather than remembered (L96): `rg -n "gmailThreadId" mac/Overture`.
// These tests pin the verdict reached for each one that needed a change, AND for the ones that did not,
// because "we looked and it was already right" is worth nothing unless something notices when it stops
// being right.
//
// Every refusal here is checked against what it must still PERMIT (L104). A guard that refused everything
// would read exactly like one that refused the right thing.
@MainActor
@Suite("Attached conversation readers")
struct AttachedConversationReadersTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let me = "dan@danwrightphotography.com"

    private func container() throws -> ModelContainer {
        // Inquiry included because the threading repair fetches it, the same allowance
        // GmailThreadingRepairTests makes for the same reason.
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // A form pitch with a conversation attached: a thread Dan linked, the address they wrote from, their
    // reply on it, and, by design, no `gmailMessageId` ever, because Overture sent nothing here.
    private func attachedFormPitch(_ ctx: ModelContext, replied: Bool = true) -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "54 Sings|2026-08-17", groupName: "54 Sings Shuffle Along",
                         discipline: "theater", venue: "The Green Room 42",
                         performanceDate: "2026-08-17", sourceListingURL: nil, websiteURL: nil,
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
        // What #2715 writes: the conversation, and the address they wrote from.
        r.gmailThreadId = "thread-abc"
        r.email = "caseen.gaines@gmail.example"
        if replied {
            r.replied = true
            r.repliedAt = now.addingTimeInterval(-86_400)
            r.inboundReplyMessageId = "<theirs@mail.gmail.com>"
            r.replyFromAddress = "caseen.gaines@gmail.example"
            r.replyAudience = ["caseen.gaines@gmail.example"]
        }
        return (p, r)
    }

    // An ordinary emailed contact: a real send, a real thread, a real message id.
    private func emailedContact(_ ctx: ModelContext, storedMessageId: String? = "<ours@mail.gmail.com>")
    -> (Prospect, Recipient) {
        let p = Prospect(naturalKey: "Aurora|2026-08-17", groupName: "Aurora Strings", discipline: "music",
                         venue: "Jalopy", performanceDate: "2026-08-17", sourceListingURL: nil,
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
        r.gmailMessageId = storedMessageId
        p.setRecipients([r])
        p.sentAt = r.sentAt
        return (p, r)
    }

    // MARK: the rule itself

    // One predicate and one sentence, from one function, so a refusal and its reason cannot disagree
    // (L109). Nil means Overture may continue the conversation.
    //
    // #2796 narrowed WHICH attached conversations are refused, and the reason belongs here rather than
    // only at the call sites. Refusing every attached row was what left this function with no caller for
    // its whole life: the send that would post onto one is the reply, and an ordinary attached reply is
    // exactly what a person attached the conversation in order to answer. What must be refused is the
    // one state where the answer would carry NO parent, since `ReplyThreading` falls back to Overture's
    // own last message and an attached conversation never has one.
    @Test func onlyAConversationOvertureCannotThreadOntoIsRefused() throws {
        let ctx = ModelContext(try container())
        let (_, nothingToThreadOff) = attachedFormPitch(ctx, replied: false)
        let (_, theirMessageKnown) = attachedFormPitch(ctx)
        let (_, emailed) = emailedContact(ctx)

        #expect(nothingToThreadOff.replyWatchConversationIsAttached)
        #expect(AttachedConversation.refusalToContinue(nothingToThreadOff,
                                                       displayName: "54 Sings Shuffle Along")
                == AttachedConversationCopy.cannotContinue(groupName: "54 Sings Shuffle Along"))
        // Attached just the same, and answerable, which is the promise the milestone is built on.
        #expect(theirMessageKnown.replyWatchConversationIsAttached)
        #expect(AttachedConversation.refusalToContinue(theirMessageKnown,
                                                       displayName: "54 Sings Shuffle Along") == nil)
        #expect(!emailed.replyWatchConversationIsAttached)
        #expect(AttachedConversation.refusalToContinue(emailed, displayName: "Aurora Strings") == nil)
    }

    // The predicate is self-healing rather than a permanent brand. The moment Overture's own reply lands
    // on the attached thread it stores its own message id, and from then on there IS a message of
    // Overture's to thread off, so the conversation stops being one it never sent on. A rule that keyed on
    // the channel alone would refuse forever, long after the reason had gone (L68).
    @Test func answeringOnAnAttachedThreadEndsTheRefusal() throws {
        let ctx = ModelContext(try container())
        let (_, r) = attachedFormPitch(ctx)

        #expect(r.replyWatchConversationIsAttached)
        r.gmailMessageId = "<our-answer@mail.gmail.com>"   // what sendReplyDraft stores on success
        #expect(!r.replyWatchConversationIsAttached)
    }

    // A contact with no conversation at all is not this rule's business: it has nothing to post into, and
    // every send path already guards the address and the thread separately. A refusal firing here would be
    // answering a question nobody asked, while reading as this rule working.
    @Test func aPitchWithNoConversationIsNotThisRulesBusiness() throws {
        let ctx = ModelContext(try container())
        let (_, r) = attachedFormPitch(ctx, replied: false)
        r.gmailThreadId = nil

        #expect(!r.replyWatchConversationIsAttached)
        #expect(AttachedConversation.refusalToContinue(r, displayName: "54 Sings Shuffle Along") == nil)
    }

    // MARK: the three send paths

    // The follow-up, which must never post an unparented message into a stranger's conversation: precisely
    // what #2647, #2649 and #2653 were filed for, arriving by a new route.
    //
    // It is refused UPSTREAM rather than by a rule of this milestone's own, and that is worth stating
    // because it is what a reader of the send path will want to know. `isAwaitingNudge` reads
    // `Recipient.isAwaitingFollowUp`, which demands `outreachChannel == .email`, and an attached
    // conversation only ever sits on a `.contactForm` row. A refusal written into `sendFollowUp` was
    // therefore unreachable, and was removed rather than shipped as a guard nothing could ever prove
    // (L1, L29). This test pins the OUTCOME, which is what actually matters, and it is not vacuous:
    // restoring the pre-#2716 reading of `isAwaitingFollowUp` makes it fail.
    @Test func aFollowUpNeverGoesOntoAConversationOvertureNeverSentOn() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = attachedFormPitch(ctx, replied: false)
        let sender = RecordingSender()

        #expect(!r.isAwaitingFollowUp)
        let sent = await SendService.sendFollowUp(r, of: p, now: now, sender: sender)

        #expect(!sent)
        #expect(sender.sent.isEmpty)
        // Nothing claimed either, so a refusal cannot leave the send held on a nudge that never went.
        #expect(r.nudgeSendClaimedAt == nil)
    }

    // #2710: a test stood here proving the refusal covered the CLOSING NOTE, which was the sharp case
    // and the reason #2717's rule existed: the note guarded only on the address and on `sentAt`, both of
    // which an attached form pitch has, so without a rule of its own it would have composed a real email
    // onto a conversation Overture never started.
    //
    // There is no closing note now, so that path cannot be reached from any direction. The refusal is
    // still asserted above, on the follow-up, which is the send that remains.

    // The refusal must not reach an ordinary email contact whose stored id was merely LOST (a send whose
    // read back failed, #2647). That conversation is Overture's own and the nudge is legitimate; blocking
    // it would take a working control away from Dan to fix a defect on a different row entirely.
    @Test func aRealSendWithALostMessageIdIsStillNudgeable() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = emailedContact(ctx, storedMessageId: nil)
        r.threadingDegraded = true
        let sender = RecordingSender()

        #expect(!r.replyWatchConversationIsAttached)
        let sent = await SendService.sendFollowUp(r, of: p, now: now, sender: sender)

        #expect(sent)
        #expect(sender.sent.count == 1)
    }

    // And the third send path is deliberately NOT refused, which is the half that keeps this from being an
    // over-refusal reading like the feature working (L104). Answering threads on THEIR message (#2653),
    // which an attached conversation has and which is the whole point of attaching one: refusing here
    // would make the milestone's central promise, full parity once attached, false.
    @Test func answeringAnAttachedConversationStillWorks() async throws {
        let ctx = ModelContext(try container())
        let (p, r) = attachedFormPitch(ctx)
        r.replyDraftBody = "Thanks for getting back to me."
        let sender = RecordingSender()

        let sent = await SendService.sendReplyDraft(r, of: p, now: now, sender: sender)

        #expect(sent)
        #expect(sender.sent.first?.inReplyTo == "<theirs@mail.gmail.com>")
        #expect(sender.sent.first?.threadId == "thread-abc")
    }

    // MARK: the threading repair

    // `GmailThreadingRepair` selects any row whose stored id Gmail cannot have assigned, and a row with NO
    // id is selected too (`isLocallyMintedMessageID` returns true for nil, deliberately, because a send
    // whose read back failed needs the same repair). An attached conversation also has no id, and it must
    // never be repaired: the premise of the manual route is that Dan found the reply IN GMAIL, and the
    // ordinary thing to do there is answer it, so his own hand sent message is sitting on that thread.
    // Storing it as `gmailMessageId` would flip the contact into "Overture emailed them" and put the
    // follow-up and closing note paths back in front of him on the one row they must never reach.
    @Test func theThreadingRepairLeavesAnAttachedConversationAlone() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = attachedFormPitch(ctx)
        try ctx.save()
        let repair = GmailThreadingRepair(fromEmail: me)

        let outcome = await repair.repairMessageIds(in: ctx, token: "t", fetch: responder { _ in
            (self.threadJSON([(from: "Caseen <caseen.gaines@gmail.example>",
                               messageId: "<theirs@mail.gmail.com>", at: 1),
                              (from: "Dan Wright <\(self.me)>",
                               messageId: "<dans-own@mail.gmail.com>", at: 2)]), 200)
        })

        #expect(r.gmailMessageId == nil)
        #expect(outcome.repaired == 0)
        // Not counted as a REFUSAL either. A refusal sets `threadingDegraded`, which surfaces a "this
        // conversation cannot be threaded" warning through the `.sendThreadingDegraded` focus, and this
        // conversation threads perfectly well: Dan's answer goes onto their message. A message may claim
        // only what its check measured (L11).
        #expect(outcome.refused == 0)
        #expect(!r.threadingDegraded)
    }

    // The other half, so the skip above cannot quietly become a skip of everything: a genuine Overture
    // send whose minted id Gmail discarded is still repaired.
    @Test func theThreadingRepairStillRepairsARealSend() async throws {
        let ctx = ModelContext(try container())
        let (_, r) = emailedContact(ctx, storedMessageId: "<minted@danwrightphotography.com>")
        try ctx.save()
        let repair = GmailThreadingRepair(fromEmail: me)

        let outcome = await repair.repairMessageIds(in: ctx, token: "t", fetch: responder { _ in
            (self.threadJSON([(from: "Dan Wright <\(self.me)>",
                               messageId: "<dans-own@mail.gmail.com>", at: 2)]), 200)
        })

        #expect(outcome.repaired == 1)
        #expect(r.gmailMessageId == "<dans-own@mail.gmail.com>")
    }

    // MARK: bounce detection

    // `detectBounces` runs over the same fetched thread as reply detection, and an attached thread was
    // never in that detector's calibration: any bounce notice on it belongs to a message Dan or the
    // presenter sent, never to Overture's pitch. Writing `r.bounced` removes the contact from the
    // reached-out queue and closes the show through PerformanceStatus, on the strength of an address that
    // may be perfectly fine (L66, L42). Reported instead, through the same channel and the same once-only
    // `lastBounceId` mechanism the existing multi-contact branch already uses, so a genuinely dead address
    // is not invisible either (L13).
    @Test func aBounceOnAnAttachedThreadIsReportedRatherThanBlamedOnTheContact() throws {
        let ctx = ModelContext(try container())
        let (p, r) = attachedFormPitch(ctx, replied: false)
        var reported: [String] = []

        _ = BounceService.detectBounces(in: [p], selfEmail: me, now: now,
                                        fetchThread: { _ in self.hardBounceJSON() },
                                        reportProblem: { reported.append($0) })

        #expect(!r.bounced)
        #expect(reported.count == 1)
        // Once only: a second tick over the same notice must not report again.
        var reportedAgain: [String] = []
        _ = BounceService.detectBounces(in: [p], selfEmail: me, now: now,
                                        fetchThread: { _ in self.hardBounceJSON() },
                                        reportProblem: { reportedAgain.append($0) })
        #expect(reportedAgain.isEmpty)
    }

    // And a bounce on a conversation Overture really did send on is still attributed, so the refusal above
    // is not a refusal to detect bounces at all.
    @Test func aBounceOnARealSendIsStillAttributed() throws {
        let ctx = ModelContext(try container())
        let (p, r) = emailedContact(ctx)

        _ = BounceService.detectBounces(in: [p], selfEmail: me, now: now,
                                        fetchThread: { _ in self.hardBounceJSON() })

        #expect(r.bounced)
    }

    // MARK: the recipient backfill

    // `RecipientBackfill` copies a legacy LEAD thread down onto act recipients that have none. A form or
    // DM contact must never receive one: it would hand the contact a conversation Dan never linked, and
    // the card would then tell him Overture is watching a conversation nobody attached.
    @Test func theBackfillNeverHandsAFormContactALeadThread() throws {
        let ctx = ModelContext(try container())
        let (p, r) = attachedFormPitch(ctx, replied: false)
        r.gmailThreadId = nil                     // not attached yet: the state the backfill could reach
        p.gmailThreadId = "lead-thread"           // a legacy lead-level send on the same show
        p.gmailMessageId = "<lead@mail.gmail.com>"
        try ctx.save()

        #expect(RecipientBackfill.repairThreadDown(in: ctx) == 0)
        #expect(r.gmailThreadId == nil)
    }

    // MARK: the readers that needed no change, asserted so a later change is noticed

    // The watch list is the FEATURE. An attached thread must be fetched and read exactly like any other,
    // which is what full parity means.
    @Test func anAttachedConversationJoinsTheWatchList() throws {
        let ctx = ModelContext(try container())
        let (p, _) = attachedFormPitch(ctx, replied: false)

        #expect(GmailReplyChecker.threadsToCheck(in: [p]).contains("thread-abc"))
    }

    // The thread lives on the RECIPIENT, and the Prospect rollup is deliberately never written by an
    // attach. That is what keeps `NaturalKeyVenueMigration` and the backfill's own outer guard, both of
    // which read the rollup, out of this entirely. Declaring the level, per L83.
    @Test func anAttachIsRecordedAtTheContactLevelOnly() throws {
        let ctx = ModelContext(try container())
        let (p, r) = attachedFormPitch(ctx)

        #expect(r.gmailThreadId == "thread-abc")
        #expect(p.gmailThreadId == nil)
    }

    // MARK: fixtures

    // One Gmail thread as the API returns it for `format=metadata`, built the way
    // `GmailThreadingRepairTests` builds it, because a second shape here would only ever confirm an
    // assumption about an interface nobody read (L52). `internalDate` is what orders the messages.
    // #2918: `labelIds` too, for the same reason and in the same shape, because a message of Dan's that
    // claims nothing about having been sent is no longer read as something he sent.
    private func threadJSON(_ messages: [(from: String, messageId: String?, at: Int64)]) -> Data {
        let payloads: [[String: Any]] = messages.map { m in
            var headers: [[String: Any]] = [["name": "From", "value": m.from]]
            if let id = m.messageId { headers.append(["name": "Message-ID", "value": id]) }
            let mine = ReplyDetection.email(from: m.from) == ReplyDetection.email(from: me)
            return ["internalDate": "\(m.at)", "labelIds": mine ? ["SENT"] : ["INBOX"],
                    "payload": ["headers": headers]]
        }
        return try! JSONSerialization.data(withJSONObject: ["messages": payloads])
    }

    // The shape `BounceServiceHardBounceTests` drives the real detector with.
    private func hardBounceJSON(id: String = "bounce-1") -> Data {
        Data("""
        {"messages":[{"id":"\(id)","payload":{"headers":[
          {"name":"From","value":"mailer-daemon@googlemail.com"},
          {"name":"Subject","value":"Delivery Status Notification (Failure)"}
        ]}}]}
        """.utf8)
    }

    private func responder(_ body: @escaping (URLRequest) -> (Data, Int))
    -> (URLRequest) async throws -> (Data, URLResponse) {
        { req in
            let (data, code) = body(req)
            return (data, HTTPURLResponse(url: req.url!, statusCode: code,
                                          httpVersion: nil, headerFields: nil)!)
        }
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
