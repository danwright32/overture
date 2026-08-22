import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let attachConversationGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")
// #2715: the write that links a Gmail conversation to a pitch Overture cannot watch.
//
// It stamps `gmailThreadId` AND runs `ReplyService` detection over the thread already in hand, in the
// SAME write. That is the design, not an optimisation. Everything the row can answer with is written
// by detection rather than by the attach (`replyAudience`, `inboundReplyMessageId`, `replyFromAddress`,
// `lastReplyText`, `lastReplyId`), so between attaching and the next tick, up to thirty minutes later,
// the row would otherwise hold a conversation, no reply, an empty audience and no parent message, and
// answering in that window would send an unthreaded message straight past #2653's fix (L3, L12, L14).
//
// Every test injects `now`. None reads the clock (L130).
@MainActor
@Suite("Attaching a conversation in one write (#2715)")
struct AttachConversationTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let me = "dan@danwrightphotography.com"
    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let route = "https://www.corinhale.example/contact"

    private func show(_ ctx: ModelContext, key: String = "show-key") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "54 Sings Shuffle Along", discipline: "music",
                         venue: "54 Below", performanceDate: "2026-09-01", sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self",
                         profile: "strong", coverage: "likely_uncovered", fitScore: 7, tier: "high",
                         fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                         possibleMatchName: nil)
        ctx.insert(p)
        return p
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

    // A Gmail thread as `threads.get?format=metadata` returns it. `internalDate` orders the messages,
    // not their position in the array, which is what every reader in ReplyDetection relies on.
    //
    // #2918 put `labelIds` on these, because Gmail returns it on every message and it is what says whether
    // one was really sent or is still an unsent draft. #2928 moved the whole shape into `GmailFixture`,
    // which works the labels out from the sender rather than each fixture restating the rule.
    private func threadJSON(_ messages: [(from: String, at: Int64, subject: String, messageId: String?)])
    -> Data {
        attachConversationGmail.thread(messages.map { m in
            .init(from: m.from, subject: m.subject, messageID: m.messageId,
                  id: "msg-\(m.at)", internalDateMillis: m.at * 1000)
        })
    }

    private func theirReply(subject: String = "Re: Photography for the anniversary celebration") -> Data {
        threadJSON([(from: "Corin Hale <corin.hale@example.com>",
                     at: Int64(now.timeIntervalSince1970) - 3600, subject: subject,
                     messageId: "<theirs@mail.gmail.com>")])
    }

    // MARK: the write itself

    @Test("attaching stamps the thread and leaves the row able to answer, in one write")
    func attachingStampsAndDetectsTogether() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        let outcome = AttachConversation.attach(
            threadId: "t1", threadJSON: theirReply(), fullThreadJSON: theirReply(),
            subject: "Re: Photography for the anniversary celebration",
            fromAddress: "corin.hale@example.com", to: r, on: p,
            ledger: .none, selfEmail: me, now: now)

        guard case .attached = outcome else { Issue.record("expected an attach, got \(outcome)"); return }
        #expect(r.gmailThreadId == "t1")
        #expect(r.replied)
        // The four fields the answer path reads, all written by detection rather than by the attach.
        #expect(r.replyFromAddress == "corin.hale@example.com")
        #expect(r.inboundReplyMessageId == "<theirs@mail.gmail.com>")
        #expect(r.lastReplyId != nil)
        #expect(r.replyAudience?.isEmpty == false)
    }

    // Overture has sent nothing on this conversation, so there is no message of its own to thread a
    // new one off. Storing one would flip the row into "Overture emailed them" and put the follow-up
    // and closing-note paths back in front of Dan on the one row they must never reach (#2717).
    @Test("attaching never stores a message id of Overture's own")
    func attachingNeverStoresAMessageId() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        _ = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(),
                                      subject: "Re: hello", fromAddress: "corin.hale@example.com",
                                      to: r, on: p, ledger: .none, selfEmail: me, now: now)

        #expect(r.gmailMessageId == nil)
        #expect(r.replyWatchConversationIsAttached)
    }

    @Test("the address they wrote from is kept on the contact")
    func theAddressIsKept() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        _ = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(),
                                      subject: "Re: hello", fromAddress: "corin.hale@example.com",
                                      to: r, on: p, ledger: .none, selfEmail: me, now: now)

        #expect(r.email == "corin.hale@example.com")
    }

    // #2438's key: `Recipient.id` is the canonical address when there is one, else `form:<url>`. Giving
    // this contact an address CHANGES what `ContactRefusal.key` computes for it, so a strike recorded
    // under the form handle would stop matching. The id is deliberately left alone (the form is still
    // how Dan reached them and how a re-run matches them), and the refusal check below asks under BOTH
    // handles so nothing can slip through the change.
    @Test("attaching does not re-key the contact")
    func attachingDoesNotRekeyTheContact() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        _ = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(),
                                      subject: "Re: hello", fromAddress: "corin.hale@example.com",
                                      to: r, on: p, ledger: .none, selfEmail: me, now: now)

        #expect(r.id == "form:\(route)")
    }

    @Test("attaching twice is one attach")
    func attachingIsIdempotent() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        _ = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(), subject: "Re: hello",
                                      fromAddress: "corin.hale@example.com", to: r, on: p,
                                      ledger: .none, selfEmail: me, now: now)
        let second = AttachConversation.attach(threadId: "t2", threadJSON: theirReply(),
                                               subject: "Re: other", fromAddress: "someone@else.com",
                                               to: r, on: p, ledger: .none, selfEmail: me,
                                               now: now.addingTimeInterval(60))

        guard case .refused = second else {
            Issue.record("a second attach must be refused, got \(second)"); return
        }
        #expect(r.gmailThreadId == "t1")
        #expect(r.email == "corin.hale@example.com")
    }

    // MARK: the subject Gmail will accept

    // `SendService.replySubject` fell back to "Re: " plus `prospect.draftSubject`, which on an attached
    // pitch is the subject of an email that was never sent and that this thread has never carried. Gmail
    // requires the Subject to match the thread's when a message is sent with its threadId, so that is
    // either an opaque 400 or a message Gmail groups server side while every standards-based client
    // files it separately. The confirmation sheet reads the same value, so Dan would approve the wrong
    // subject (L64).
    @Test("the answer takes its subject from the thread, not from a draft that was never sent")
    func theSubjectComesFromTheThread() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        p.draftSubject = "Photographing 54 Sings Shuffle Along"
        let r = formPitch(ctx, on: p)

        _ = AttachConversation.attach(
            threadId: "t1", threadJSON: theirReply(subject: "Our anniversary show"),
            subject: "Our anniversary show", fromAddress: "corin.hale@example.com",
            to: r, on: p, ledger: .none, selfEmail: me, now: now)

        #expect(r.attachedThreadSubject == "Our anniversary show")
        #expect(SendService.replySubject(for: r, of: p) == "Re: Our anniversary show")
    }

    @Test("a thread subject that already says Re is not given a second one")
    func theSubjectIsNotDoublePrefixed() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        _ = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(),
                                      subject: "Re: Our anniversary show",
                                      fromAddress: "corin.hale@example.com", to: r, on: p,
                                      ledger: .none, selfEmail: me, now: now)

        #expect(SendService.replySubject(for: r, of: p) == "Re: Our anniversary show")
    }

    // MARK: Dan has already answered on this thread

    // The premise of the manual route is that Dan found the reply in Gmail, and the ordinary thing to do
    // there is answer it. `latestReplyMessage` skips his own messages, so detection still resolves to
    // theirs and sets `replied`, and `hasUnhandledReply` stays true for ever because only Overture's own
    // send paths set `replyHandledAt`. The row would assert somebody is waiting on him, permanently, on
    // a conversation he closed days ago, and OmniFocus would grow a task for it: #2170's defect
    // re-entering by a new route.
    @Test("a thread whose newest message is Dan's own is attached already answered")
    func aThreadDanAlreadyAnsweredIsNotLeftWaiting() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let base = Int64(now.timeIntervalSince1970)
        let thread = threadJSON([
            (from: "Corin Hale <corin.hale@example.com>", at: base - 7200,
             subject: "Our show", messageId: "<theirs@mail.gmail.com>"),
            (from: "Dan Wright <dan@danwrightphotography.com>", at: base - 3600,
             subject: "Re: Our show", messageId: "<mine@mail.gmail.com>"),
        ])

        _ = AttachConversation.attach(threadId: "t1", threadJSON: thread, fullThreadJSON: thread,
                                      subject: "Our show", fromAddress: "corin.hale@example.com",
                                      to: r, on: p, ledger: .none, selfEmail: me, now: now)

        #expect(r.replied, "their message is still a reply that happened")
        #expect(r.replyHandledAt == now, "Dan answered on this thread, so nothing is waiting on him")
        #expect(r.hasUnhandledReply == false)
    }

    @Test("a thread whose newest message is theirs is left waiting on Dan")
    func aThreadHeHasNotAnsweredStaysWaiting() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        _ = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(),
                                      fullThreadJSON: theirReply(), subject: "Our show",
                                      fromAddress: "corin.hale@example.com", to: r, on: p,
                                      ledger: .none, selfEmail: me, now: now)

        #expect(r.replyHandledAt == nil)
        #expect(r.hasUnhandledReply)
    }

    // MARK: what the detach will need, captured before detection destroys it

    // `reopenOnReply` clears a `.stoodDown` resolution and nulls three draft fields, and nothing else
    // remembers any of them. Without capturing them here the compensating detach (#2719) cannot exist,
    // which is L5: never destroy good state before its replacement is verified to exist.
    @Test("the stand-down detection is about to clear is recorded first")
    func thePriorResolutionIsRecorded() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        r.resolution = .stoodDown

        _ = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(), subject: "s",
                                      fromAddress: "corin.hale@example.com", to: r, on: p,
                                      ledger: .none, selfEmail: me, now: now)

        #expect(r.resolution == nil, "detection cleared it, which is the behaviour being recorded")
        #expect(r.attachPriorResolutionRaw == RecipientResolution.stoodDown.rawValue)
    }

    @Test("the reply-draft baseline detection is about to null is recorded first")
    func thePriorDraftBaselineIsRecorded() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        r.originalReplyDraftBody = "what the model first wrote"
        r.replyDraftWrittenByDan = true
        r.replyDraftEditedByDan = true

        _ = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(), subject: "s",
                                      fromAddress: "corin.hale@example.com", to: r, on: p,
                                      ledger: .none, selfEmail: me, now: now)

        #expect(r.originalReplyDraftBody == nil)
        #expect(r.attachPriorOriginalReplyDraftBody == "what the model first wrote")
        #expect(r.attachPriorReplyDraftWrittenByDan)
        #expect(r.attachPriorReplyDraftEditedByDan)
    }

    // `detectReplies` ends with `pausePendingForReply()`, which freezes every still-pending contact on
    // the show that has an address. A wrong attach therefore silently freezes the show's real, drafted,
    // approved pitch, and the detach has to know which rows IT froze rather than clearing every pause
    // it finds.
    @Test("the contacts this attach paused are recorded, and ones already paused are not claimed")
    func theContactsThisAttachPausedAreRecorded() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let pendingA = Recipient(id: "a@act.com", email: "a@act.com", provenance: .act)
        let pendingB = Recipient(id: "b@act.com", email: "b@act.com", provenance: .act)
        pendingB.pausedByReply = true      // already frozen for some other reason
        p.addRecipient(pendingA)
        p.addRecipient(pendingB)

        _ = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(), subject: "s",
                                      fromAddress: "corin.hale@example.com", to: r, on: p,
                                      ledger: .none, selfEmail: me, now: now)

        #expect(pendingA.pausedByReply)
        #expect(r.attachPausedRecipientIds == ["a@act.com"],
                "only the rows this attach froze, so a detach cannot unfreeze one it did not touch")
    }

    // MARK: refusals

    // `ContactRefusal.ledger` is the declared home for "Dan does not want to contact this address", and
    // it exists because a struck contact otherwise comes straight back (#2392, #2421). An attach that
    // writes an address without reading it resurrects a struck one, and a protective control that does
    // not fail closed is L42.
    @Test("an attach that would write a struck address back onto the contact is refused")
    func aStruckAddressIsRefused() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        ContactRefusal.refuse(email: "corin.hale@example.com", scope: .show(p.naturalKey),
                              in: ctx, now: now)
        let ledger = ContactRefusal.ledger(in: ctx)

        let outcome = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(), subject: "s",
                                                fromAddress: "corin.hale@example.com", to: r, on: p,
                                                ledger: ledger, selfEmail: me, now: now)

        guard case .refused(let reason) = outcome else {
            Issue.record("a struck address must refuse, got \(outcome)"); return
        }
        #expect(reason.contains("corin.hale@example.com"), "the refusal must name the strike")
        #expect(r.gmailThreadId == nil, "nothing may be written when the attach is refused")
        #expect(r.email == nil)
    }

    // The handle a strike is recorded under changes the moment this contact gains an address, so both
    // spellings have to be asked. A strike made against the FORM contact, before any address existed,
    // must still refuse.
    @Test("a strike recorded against the form contact still refuses once an address is offered")
    func aStrikeAgainstTheFormHandleStillRefuses() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        ContactRefusal.refuse(email: nil, formURL: route, scope: .show(p.naturalKey), in: ctx, now: now)
        let ledger = ContactRefusal.ledger(in: ctx)

        let outcome = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(), subject: "s",
                                                fromAddress: "corin.hale@example.com", to: r, on: p,
                                                ledger: ledger, selfEmail: me, now: now)

        guard case .refused = outcome else {
            Issue.record("a strike on the form handle must refuse, got \(outcome)"); return
        }
        #expect(r.gmailThreadId == nil)
    }

    @Test("a pitch Overture emailed itself cannot have a conversation attached")
    func anEmailedPitchIsRefused() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: "them@act.com", email: "them@act.com", provenance: .act)
        r.sendState = .sent
        r.sentAt = now
        p.addRecipient(r)

        let outcome = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(), subject: "s",
                                                fromAddress: "x@y.com", to: r, on: p, ledger: .none,
                                                selfEmail: me, now: now)

        guard case .refused = outcome else {
            Issue.record("only a hand-sent pitch may be linked, got \(outcome)"); return
        }
    }

    // Every refusal comes from the function that DECIDES it, so a greyed control and the reason beside
    // it cannot disagree (L109).
    @Test("every refusal carries a sentence")
    func everyRefusalCarriesASentence() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        ContactRefusal.refuse(email: "corin.hale@example.com", scope: .show(p.naturalKey),
                              in: ctx, now: now)

        let struck = AttachConversation.attach(
            threadId: "t1", threadJSON: theirReply(), subject: "s",
            fromAddress: "corin.hale@example.com", to: r, on: p,
            ledger: ContactRefusal.ledger(in: ctx), selfEmail: me, now: now)
        _ = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(), subject: "s",
                                      fromAddress: "other@else.com", to: r, on: p, ledger: .none,
                                      selfEmail: me, now: now)
        let again = AttachConversation.attach(threadId: "t2", threadJSON: theirReply(), subject: "s",
                                              fromAddress: "other@else.com", to: r, on: p,
                                              ledger: .none, selfEmail: me, now: now)

        for outcome in [struck, again] {
            guard case .refused(let reason) = outcome else {
                Issue.record("expected a refusal, got \(outcome)"); continue
            }
            #expect(reason.count > 20, "a refusal with no sentence is a greyed control with no reason")
            #expect(reason.hasSuffix("."), "a refusal is a sentence, not a fragment: \(reason)")
        }
    }

    // MARK: the row says who linked it

    @Test("the row records that the link was made by hand, and when")
    func theRowRecordsWhoLinkedIt() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        _ = AttachConversation.attach(threadId: "t1", threadJSON: theirReply(), subject: "s",
                                      fromAddress: "corin.hale@example.com", to: r, on: p,
                                      ledger: .none, selfEmail: me, now: now)

        #expect(r.conversationAttachedAt == now)
        // Read by the reply panel, so the row does not read as though Overture emailed them (L46).
        #expect(ReplyPanel.linkedByHandLine(for: r) != nil)
    }

    @Test("a row Overture emailed itself says nothing about a hand link")
    func anEmailedRowSaysNothingAboutALink() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = Recipient(id: "them@act.com", email: "them@act.com", provenance: .act)
        r.gmailThreadId = "t1"
        r.gmailMessageId = "<ours@mail.gmail.com>"
        p.addRecipient(r)

        #expect(ReplyPanel.linkedByHandLine(for: r) == nil)
    }
}
