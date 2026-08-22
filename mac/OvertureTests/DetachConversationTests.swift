import Testing
import Foundation
import SwiftData


// #2928: the one Gmail fixture builder, at file scope.
private let detachConversationGmail = GmailFixture(selfEmail: "dan@danwrightphotography.com")
// #2719: unlinking a conversation Dan attached to the wrong pitch.
//
// The plan promised "a detach that restores the prior state exactly". It cannot be built as stated, and
// the reason matters more than the phrasing: by the time Dan presses detach, detection has written a
// dozen fields and three of its effects have left the app entirely. An away alert has been posted, an
// OmniFocus task has been created in a separate application, and a notification has been shown.
//
// So this is a COMPENSATING operation over an enumerated list, which SAYS what it could not take back,
// and which REFUSES outright once Dan has answered on the thread. A partial undo that claims to be
// exact is the L38 defect verbatim; refusing is honest.
//
// Every test injects `now` (L130).
@MainActor
@Suite("Unlinking a conversation, honestly (#2719)")
struct DetachConversationTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        RefusedContactAddress.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let me = "dan@danwrightphotography.com"
    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let route = "https://www.corinhale.example/contact"

    private func show(_ ctx: ModelContext) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "54 Sings Shuffle Along", discipline: "music",
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
        r.formOutreachPriorStatusRaw = ReviewStatus.drafted.rawValue
        r.sentAt = now.addingTimeInterval(-3 * 86_400)
        r.sendState = .sent
        p.addRecipient(r)
        return r
    }

    // #2918 put `labelIds` on these, which Gmail returns on every message and which says whether one was
    // really sent or is still an unsent draft. #2928 moved the shape into `GmailFixture`.
    private func threadJSON(_ messages: [(from: String, at: Int64, subject: String, messageId: String?)])
    -> Data {
        detachConversationGmail.thread(messages.map { m in
            .init(from: m.from, subject: m.subject, messageID: m.messageId,
                  id: "msg-\(m.at)", internalDateMillis: m.at * 1000)
        })
    }

    private func theirReply() -> Data {
        threadJSON([(from: "A Stranger <stranger@elsewhere.com>",
                     at: Int64(now.timeIntervalSince1970) - 3600, subject: "Something else entirely",
                     messageId: "<theirs@mail.gmail.com>")])
    }

    @discardableResult
    private func attached(_ ctx: ModelContext, on p: Prospect, to r: Recipient) -> AttachConversation.Outcome {
        AttachConversation.attach(threadId: "t1", threadJSON: theirReply(), fullThreadJSON: theirReply(),
                                  subject: "Something else entirely",
                                  fromAddress: "stranger@elsewhere.com", to: r, on: p,
                                  ledger: .none, selfEmail: me, now: now)
    }

    // MARK: the compensating list

    @Test("detaching takes the conversation back off the row")
    func detachingUnlinks() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        attached(ctx, on: p, to: r)

        let outcome = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60))

        guard case .detached = outcome else { Issue.record("expected a detach, got \(outcome)"); return }
        #expect(r.gmailThreadId == nil)
        #expect(r.conversationAttachedAt == nil)
        #expect(r.attachedThreadSubject == nil)
        #expect(r.hasWatchableConversation == false)
    }

    // The whole reason this is dangerous: a wrong attach writes a STRANGER's address onto the contact,
    // and the contact is still pitchable. Leaving it there is how Overture ends up emailing somebody it
    // was never meant to reach.
    @Test("detaching takes back the address the attach wrote")
    func detachingTakesBackTheAddress() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        attached(ctx, on: p, to: r)
        #expect(r.email == "stranger@elsewhere.com")

        _ = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60))

        #expect(r.email == nil)
    }

    // An address that was ALREADY on the contact was not the attach's to remove.
    @Test("detaching leaves an address the attach did not write")
    func detachingLeavesAnAddressItDidNotWrite() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        r.email = "known@act.com"
        attached(ctx, on: p, to: r)

        _ = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60))

        #expect(r.email == "known@act.com")
    }

    @Test("detaching reverses everything detection wrote about the reply")
    func detachingReversesDetection() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        attached(ctx, on: p, to: r)
        #expect(r.replied)

        _ = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60))

        #expect(r.replied == false)
        #expect(r.repliedAt == nil)
        #expect(r.lastReplyId == nil)
        #expect(r.lastReplyText == nil)
        #expect(r.replyAudience == nil)
        #expect(r.replyFromAddress == nil)
        #expect(r.replyFromName == nil)
        #expect(r.inboundReplySentAt == nil)
        #expect(r.inboundReplyMessageId == nil)
        #expect(r.replyHandledAt == nil)
    }

    // `reopenOnReply` clears a `.stoodDown` resolution, and nothing else in the app remembers it. Without
    // the snapshot #2715 captures, a detach could only guess at an inverse (L5).
    @Test("detaching puts back the stand-down the attach cleared")
    func detachingRestoresTheStandDown() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        r.resolution = .stoodDown
        attached(ctx, on: p, to: r)
        #expect(r.resolution == nil)

        _ = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60))

        #expect(r.resolution == .stoodDown)
    }

    @Test("detaching puts back the reply-draft baseline the attach nulled")
    func detachingRestoresTheDraftBaseline() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        r.originalReplyDraftBody = "what the model first wrote"
        r.replyDraftWrittenByDan = true
        r.replyDraftEditedByDan = true
        attached(ctx, on: p, to: r)

        _ = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60))

        #expect(r.originalReplyDraftBody == "what the model first wrote")
        #expect(r.replyDraftWrittenByDan)
        #expect(r.replyDraftEditedByDan)
    }

    // The one the draft missed entirely. `detectReplies` ends with `pausePendingForReply()`, which
    // freezes every still-pending contact on the show that has an address, and nothing in a detach
    // clears it: only `resumePausedRecipients()` does, from the reply-triage paths. So a wrong attach
    // silently freezes the show's real, drafted, approved pitch, and a detach that ignored it would
    // leave it frozen with nothing on screen saying why.
    @Test("detaching unfreezes the contacts the attach froze")
    func detachingUnfreezesWhatTheAttachFroze() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let pending = Recipient(id: "a@act.com", email: "a@act.com", provenance: .act)
        p.addRecipient(pending)
        attached(ctx, on: p, to: r)
        #expect(pending.pausedByReply, "the attach froze the show's real pitch")

        _ = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60))

        #expect(pending.pausedByReply == false)
    }

    // And only those. A row frozen for some other reason was never this attach's to thaw.
    @Test("detaching leaves a contact that was already frozen alone")
    func detachingLeavesAnAlreadyFrozenContactAlone() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let already = Recipient(id: "b@act.com", email: "b@act.com", provenance: .act)
        already.pausedByReply = true
        p.addRecipient(already)
        attached(ctx, on: p, to: r)

        _ = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60))

        #expect(already.pausedByReply, "it was frozen before the attach and is not the detach's to thaw")
    }

    // MARK: what it refuses

    // Once Dan has answered on the thread, the message is on a stranger's conversation and unlinking
    // cannot recall it. Refusing is honest; a detach that claimed to restore the prior state after that
    // would be claiming something demonstrably false.
    @Test("detaching is refused once Dan has answered on the conversation")
    func detachingIsRefusedAfterAnAnswer() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        attached(ctx, on: p, to: r)
        r.replyDraftBody = "my answer"
        r.recordAnswerSent(now: now.addingTimeInterval(120))

        let outcome = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(180))

        guard case .refused(let reason) = outcome else {
            Issue.record("an answered conversation must refuse, got \(outcome)"); return
        }
        #expect(reason.count > 20)
        #expect(r.gmailThreadId == "t1", "nothing may be written when the detach is refused")
    }

    // The two halves of that refusal are NOT redundant, and a mutation proved it: deleting the
    // `replyHandledAt` check left the suite green, because the test above answers through a stored draft
    // and so sets `replySentAt` too. The case that separates them is the copy-out path. `recordAnswerSent`
    // calls `freezeSentReply`, which declines when there is no `replyDraftBody`, so answering by pasting
    // into Gmail stamps `replyHandledAt` and never touches `replySentAt`. That is the harder case to
    // notice and the one a single check would have missed (L30).
    @Test("detaching is refused after an answer Dan copied out, which records no sent body")
    func detachingIsRefusedAfterACopiedOutAnswer() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        attached(ctx, on: p, to: r)
        r.replyDraftBody = nil
        r.recordAnswerSent(now: now.addingTimeInterval(120))
        #expect(r.replySentAt == nil, "no draft body, so nothing was frozen as sent")
        #expect(r.replyHandledAt != nil)

        let outcome = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(180))

        guard case .refused = outcome else {
            Issue.record("an answer he copied out still means he answered, got \(outcome)"); return
        }
        #expect(r.gmailThreadId == "t1")
    }

    // And the mirror, so the `replySentAt` half is not vacuous either: a row carrying a frozen sent body
    // from before the attach must not lock the detach out.
    @Test("a sent body frozen before the attach does not lock the detach out")
    func aSentBodyFromBeforeTheAttachDoesNotRefuse() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        r.replySentAt = now.addingTimeInterval(-86_400)
        attached(ctx, on: p, to: r)

        let outcome = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60))

        guard case .detached = outcome else {
            Issue.record("an answer predating the attach is about a different conversation, got \(outcome)")
            return
        }
    }

    // The attach itself stamps `replyHandledAt` when the thread's newest message was already Dan's own
    // (#2715), and that must NOT count as answering since the attach. Otherwise linking a thread he had
    // already dealt with would be instantly and permanently un-undoable, which is exactly the trap this
    // issue exists to avoid.
    @Test("a thread Dan had already answered before attaching can still be detached")
    func aThreadAnsweredBeforeTheAttachCanStillBeDetached() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let base = Int64(now.timeIntervalSince1970)
        let thread = threadJSON([
            (from: "A Stranger <stranger@elsewhere.com>", at: base - 7200, subject: "s",
             messageId: "<theirs@mail.gmail.com>"),
            (from: "Dan Wright <dan@danwrightphotography.com>", at: base - 3600, subject: "Re: s",
             messageId: "<mine@mail.gmail.com>"),
        ])
        _ = AttachConversation.attach(threadId: "t1", threadJSON: thread, fullThreadJSON: thread,
                                      subject: "s", fromAddress: "stranger@elsewhere.com",
                                      to: r, on: p, ledger: .none, selfEmail: me, now: now)
        #expect(r.replyHandledAt == now)

        let outcome = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60))

        guard case .detached = outcome else {
            Issue.record("the attach's own stamp must not lock the detach out, got \(outcome)"); return
        }
    }

    @Test("detaching a row with nothing linked is refused, with a reason")
    func detachingNothingIsRefused() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)

        let outcome = DetachConversation.detach(r, on: p, now: now)

        guard case .refused(let reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)"); return
        }
        #expect(reason.count > 20)
    }

    // MARK: honest about what it could not take back

    // Two effects leave the app entirely: `ReconcileScheduler` fires an away alert on the
    // replied-before/replied-after diff, and `OmniFocusSync` emits a real task in Dan's OmniFocus keyed
    // on `hasUnhandledReply`. Neither can be recalled from here, and a detach that said nothing about
    // them would be claiming an exactness it does not have (L38, L11).
    @Test("a detach says what it could not take back")
    func aDetachSaysWhatItCouldNotTakeBack() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        attached(ctx, on: p, to: r)

        let outcome = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60),
                                                omniFocusEnabled: true)

        guard case .detached(let couldNotUndo) = outcome else {
            Issue.record("expected a detach, got \(outcome)"); return
        }
        #expect(couldNotUndo != nil, "a detach that took nothing back silently is claiming exactness")
        #expect(couldNotUndo?.contains("OmniFocus") == true)
    }

    // And it claims only what it measured. An OmniFocus task exists only when Dan has that sync turned
    // on, so naming one to somebody who does not use it sends him looking for a thing that was never
    // there, which is the same defect as saying nothing, pointed the other way (L11).
    @Test("a detach does not name an OmniFocus task when that sync is off")
    func aDetachDoesNotNameATaskThatCannotExist() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        attached(ctx, on: p, to: r)

        let outcome = DetachConversation.detach(r, on: p, now: now.addingTimeInterval(60),
                                                omniFocusEnabled: false)

        guard case .detached(let couldNotUndo) = outcome else {
            Issue.record("expected a detach, got \(outcome)"); return
        }
        #expect(couldNotUndo?.contains("OmniFocus") == false)
        #expect(couldNotUndo?.contains("alert") == true, "it still says what it could not reach")
    }

    // MARK: a recorded form pitch is final (#3069)

    // These five tests used to drive `Prospect.undoFormOutreach` directly, and they passed while proving
    // nothing a person could reach: no branch of DraftReviewView draws `.recorded`, so the "Didn't send"
    // they were about does not exist, and everything past that function's first guard was dead code with
    // a sentence written for it. Dan's call, 2026-08-22: a recorded form pitch is FINAL, so the undo, its
    // permanent refusal and the sentence are gone (L29).
    //
    // What replaces them asserts the DECISION rather than the deleted code, through the mutation layer a
    // button actually calls, so it holds whether or not anybody re-adds a model-level undo later.
    @Test("the button that exists cannot take back a record that was made")
    func cancellingAFormPitchNeverUndoesARecordedOne() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        let r = formPitch(ctx, on: p)
        let recordedAt = try #require(r.formOutreachRecordedAt)

        ProspectMutations.cancelFormPitch(QueueItem(p), r.id, prospects: [p],
                                          context: ctx, feedback: ActionFeedback())

        #expect(r.formOutreachRecordedAt == recordedAt, "the send record must be left exactly as it was")
        #expect(r.sendState == .sent)
    }

    // And the direction that DOES occur still works: a pitch Dan started and did not record backs out.
    @Test("a started but unrecorded pitch is backed out")
    func cancellingAStartedPitchClearsIt() throws {
        let ctx = ModelContext(try container())
        let p = show(ctx)
        // Built rather than taken from `formPitch`, which makes a RECORDED one: this case is about the
        // state before the record exists, which is the only one the button can be pressed in.
        let r = Recipient(id: "form:\(route)", email: nil, name: "Corin Hale", provenance: .act)
        r.contactFormURL = route
        p.addRecipient(r)
        r.formOutreachStartedAt = now

        ProspectMutations.cancelFormPitch(QueueItem(p), r.id, prospects: [p],
                                          context: ctx, feedback: ActionFeedback())

        #expect(r.formOutreachStartedAt == nil)
        #expect(r.formOutreachRecordedAt == nil)
    }
}
