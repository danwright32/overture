import Testing
import Foundation
import SwiftData

private let anotherThreadGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")

// #3709 and #3710 (milestone 82, Phases 3 and 4): attaching a conversation onto a contact that ALREADY
// holds one, and taking that back.
//
// #3706's case: the pitch went out by email to a producer, the producer forwarded it, and a performer
// wrote back on a thread of their own. Dan's call, 2026-09-08: ONE contact on the show, the conversation
// and every future email move onto it, and the address the pitch actually went to is KEPT as history so
// the org ledger and the funnel can still learn which contacts get answers.
//
// THE TWO PHASES ARE ONE PR, and that is deliberate rather than a shortcut. An undo that restores fewer
// fields than the action changed is not the inverse of that action (L574), and phase 3 alone gives the
// attach two new things to have changed (a populated address and the pitch's own thread) that the detach
// would leave behind: the pitched thread would be gone, the writer's address would stay, and both losses
// are silent. Shipping the pair together is the only version where the undo is true on the day the
// action exists.
//
// Every test injects `now` (L130).
@MainActor
@Suite("Linking a reply that arrived on another thread (#3709, #3710)")
struct LinkingAReplyOnAnotherThreadTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let me = "dan@danwrightphotography.com"
    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let pitched = "producer@presenter.example"
    private let writer = "performer@theirown.example"
    private let route = "https://www.corinhale.example/contact"

    private func show(_ ctx: ModelContext, key: String = "show-key") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "54 Sings Shuffle Along", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-09-01", sourceListingURL: nil,
                         priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    // The live shape #3706 measured: sent, holding the thread the pitch went out on, no reply recorded.
    @discardableResult
    private func emailedPitch(_ ctx: ModelContext, on p: Prospect) -> Recipient {
        let r = Recipient(id: pitched, email: pitched, name: "Corin Hale", provenance: .presenter)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-9 * 86_400)
        r.gmailMessageId = "<ours@mail.gmail.com>"
        r.gmailThreadId = "thread-we-sent-on"
        p.addRecipient(r)
        return r
    }

    @discardableResult
    private func formPitch(_ ctx: ModelContext, on p: Prospect) -> Recipient {
        let r = Recipient(id: "form:\(route)", email: nil, name: "Corin Hale", provenance: .act)
        r.contactFormURL = route
        r.formOutreachURL = route
        r.outreachChannel = .contactForm
        r.formOutreachRecordedAt = now.addingTimeInterval(-3 * 86_400)
        r.sentAt = now.addingTimeInterval(-3 * 86_400)
        r.sendState = .sent
        p.addRecipient(r)
        return r
    }

    private func theirReply(from: String) -> Data {
        anotherThreadGmail.thread([
            .init(from: "Casey Nunn <\(from)>", subject: "Photos for the run?",
                  messageID: "<theirs@mail.gmail.com>", id: "msg-1",
                  internalDateMillis: Int64(now.timeIntervalSince1970 - 3600) * 1000)
        ])
    }

    @discardableResult
    private func attach(_ r: Recipient, on p: Prospect, in ctx: ModelContext,
                        thread: String = "thread-they-started",
                        from: String? = nil) -> AttachConversation.Outcome {
        AttachConversation.attach(threadId: thread, threadJSON: theirReply(from: from ?? writer),
                                  subject: "Photos for the run?", fromAddress: from ?? writer,
                                  to: r, on: p, ledger: ContactRefusal.ledger(in: ctx),
                                  selfEmail: me, now: now)
    }

    // MARK: attaching onto a contact that already holds a conversation

    // The case that had no route at all. Before this the attach refused twice over: once because the
    // contact holds a thread, once because it was not a hand-sent pitch.
    @Test("it attaches onto an emailed pitch and records the thread it displaced")
    func itAttachesOntoAnEmailedPitch() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)

        let outcome = attach(r, on: p, in: ctx)

        guard case .attached = outcome else {
            Issue.record("expected an attach, got \(outcome)"); return
        }
        #expect(r.gmailThreadId == "thread-they-started")
        #expect(r.attachDisplacedThreadId == "thread-we-sent-on",
                "the thread the pitch went out on is gone with nothing remembering it")
        #expect(r.conversationAttachedAt == now)
    }

    // Dan's call: the row talks to the writer, and underneath it still records where the pitch went, so
    // the org ledger and the funnel can still learn which contacts get answers.
    @Test("it moves the address onto the writer and keeps the pitched one as history")
    func itKeepsThePitchedAddress() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)

        attach(r, on: p, in: ctx)

        #expect(r.email == writer)
        #expect(r.attachDisplacedEmail == pitched)
        #expect(r.attachWroteAddress == false,
                "that flag means the attach FILLED an empty address, which is a different act")
    }

    // #2717's rule, unchanged and load-bearing: `gmailMessageId` is what proves Overture emailed this
    // contact, and the pitch really did go out. Clearing it would make the show read as never pitched.
    @Test("it leaves the proof that Overture emailed this contact alone")
    func itLeavesTheOutgoingMessageAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)

        attach(r, on: p, in: ctx)

        #expect(r.gmailMessageId == "<ours@mail.gmail.com>")
        #expect(r.hasProvenOutreach)
    }

    // The refusal that stays. Replacing a thread a PREVIOUS ATTACH put there would strand everything
    // detection wrote about it and overwrite the snapshot the detach restores from, so that one is still
    // "detach first". The widening is precisely to the thread the PITCH went out on, which Overture
    // wrote itself and can put back.
    @Test("it still refuses a contact whose conversation another attach put there")
    func itStillRefusesASecondAttach() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        attach(r, on: p, in: ctx)

        let second = attach(r, on: p, in: ctx, thread: "a-third-thread", from: "someone@else.example")

        #expect(second == .refused(reason: AttachConversationWriteCopy.alreadyLinked))
        #expect(r.gmailThreadId == "thread-they-started", "the first link was overwritten")
        #expect(r.attachDisplacedThreadId == "thread-we-sent-on",
                "the snapshot the detach restores from was overwritten")
    }

    // The guard that replaced "not a hand-sent pitch". A contact nothing was ever sent to has no reply to
    // link, and the sentence that used to be said here ("Overture only links a conversation to a pitch
    // you sent through a form or a DM") became false the moment an emailed pitch was allowed (L11).
    @Test("it refuses a contact the pitch never went out to")
    func itRefusesAContactNothingWasSentTo() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: pitched, email: pitched, provenance: .presenter)
        p.addRecipient(r)

        let outcome = attach(r, on: p, in: ctx)

        #expect(outcome == .refused(reason: AttachConversationWriteCopy.notAPitchThatWentOut))
        #expect(r.gmailThreadId == nil)
    }

    // Nothing was displaced, so nothing is recorded. Without this the detach would "restore" an address
    // onto a contact that already had it, and `attachDisplacedEmail` would read as a replacement that
    // never happened.
    @Test("a writer who is the contact displaces nothing")
    func aWriterWhoIsTheContactDisplacesNothing() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)

        attach(r, on: p, in: ctx, from: pitched)

        #expect(r.email == pitched)
        #expect(r.attachDisplacedEmail == nil)
    }

    // The form-pitch behaviour #2719 built, unchanged by the widening. An attach onto a contact with NO
    // address FILLS it, and that is the flag the detach reads to null it again.
    @Test("filling an empty address is still recorded as the attach having written it")
    func fillingAnEmptyAddressIsUnchanged() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        attach(r, on: p, in: ctx)

        #expect(r.email == writer)
        #expect(r.attachWroteAddress)
        #expect(r.attachDisplacedEmail == nil)
    }

    // The ledger check is unchanged and still fails closed: the address about to be written is the one
    // asked about, because that is the address this attach would put in front of Dan.
    @Test("a struck writer address is still refused")
    func aStruckWriterAddressIsStillRefused() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        ContactRefusal.refuse(email: writer, scope: .show(p.naturalKey), in: ctx, now: now)

        let outcome = attach(r, on: p, in: ctx)

        #expect(outcome == .refused(reason: AttachConversationWriteCopy.struckAddress(writer)))
        #expect(r.email == pitched, "a refused attach wrote the address anyway")
    }

    // MARK: taking it back

    // The half that makes the widening safe. Nulling the thread would leave an emailed pitch with no
    // conversation at all, so Overture would stop watching the thread it sent on and the follow-up path
    // would have nothing to thread onto.
    @Test("detaching puts the pitch's own thread back rather than nulling it")
    func detachingRestoresTheDisplacedThread() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        attach(r, on: p, in: ctx)

        let outcome = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60),
                                                omniFocusEnabled: false)

        guard case .detached = outcome else {
            Issue.record("expected a detach, got \(outcome)"); return
        }
        #expect(r.gmailThreadId == "thread-we-sent-on")
        #expect(r.attachDisplacedThreadId == nil)
        #expect(r.hasWatchableConversation, "Overture stopped watching the thread it sent on")
    }

    @Test("detaching puts the pitched address back")
    func detachingRestoresTheDisplacedAddress() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        attach(r, on: p, in: ctx)

        DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60), omniFocusEnabled: false)

        #expect(r.email == pitched)
        #expect(r.attachDisplacedEmail == nil)
    }

    // The other arm, unchanged: an attach that FILLED an empty address still nulls it, and must not be
    // handed the restore branch instead.
    @Test("detaching a form pitch still nulls the address the attach wrote")
    func detachingAFormPitchIsUnchanged() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        attach(r, on: p, in: ctx)

        DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60), omniFocusEnabled: false)

        #expect(r.email == nil)
        #expect(r.attachWroteAddress == false)
        #expect(r.gmailThreadId == nil, "a form pitch had no thread of its own to put back")
    }

    // The enumerated list, asked as one question rather than field by field, because the claim the pair
    // makes is that NOTHING the replacing attach changed is left behind (L574). Read off the row itself:
    // every field named here is one this attach writes.
    @Test("a replacing attach leaves nothing of its own behind after a detach")
    func theReplacingAttachIsFullyUndone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        attach(r, on: p, in: ctx)
        #expect(r.replied, "the premise: detection found their message")

        DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60), omniFocusEnabled: false)

        #expect(r.email == pitched)
        #expect(r.gmailThreadId == "thread-we-sent-on")
        #expect(r.attachDisplacedEmail == nil)
        #expect(r.attachDisplacedThreadId == nil)
        #expect(r.attachedThreadSubject == nil)
        #expect(r.conversationAttachedAt == nil)
        #expect(r.replied == false)
        #expect(r.replyFromAddress == nil)
        #expect(r.gmailMessageId == "<ours@mail.gmail.com>", "the outgoing proof was never the attach's")
        #expect(r.conversationEverAttachedAt != nil, "the record that an exchange happened must survive")
    }

    // MARK: nothing else may put the pitched address back

    // The sibling that would have undone the whole feature silently. `PrepImporter.apply` writes
    // `r.email` from whatever a contact re-check found, and a re-check on this show finds the PITCHED
    // address, because that is what is published. Without the guard the next run moves the row back onto
    // the producer, the link's whole point is gone, and nothing anywhere reports it.
    @Test("a later contact re-check does not put the pitched address back over a linked one")
    func aLaterCheckDoesNotOverwriteTheLinkedAddress() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = emailedPitch(ctx, on: p)
        attach(r, on: p, in: ctx)
        #expect(r.email == writer, "the premise of this test")

        _ = PrepImporter.ingest(PrepResults(version: 2, generatedAt: "now", results: [
            PrepResult(naturalKey: p.naturalKey,
                       contacts: [PrepContact(name: "Corin Hale", role: "Producer", email: pitched,
                                              method: "direct_email", confidence: "high",
                                              formUrl: nil, provenance: "presenter",
                                              sourceUrl: "https://presenter.example/staff")],
                       draft: PrepDraft(subject: "s", body: "b", variant: "A")),
        ]), into: ctx)

        #expect(r.email == writer)
        #expect(r.attachDisplacedEmail == pitched)
    }
}
