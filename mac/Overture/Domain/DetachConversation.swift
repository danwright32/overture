import Foundation

// #2719: unlink a conversation Dan attached to the wrong pitch.
//
// The plan promised "a detach that restores the prior state exactly". It cannot be built as stated, and
// the reason matters more than the phrasing: by the time Dan presses detach, detection has written a
// dozen fields and three of its effects have LEFT THE APP. `ReconcileScheduler` fires an away alert on
// the replied-before/replied-after diff, `OmniFocusSync` emits a real task in Dan's OmniFocus keyed on
// `hasUnhandledReply`, and a notification has been shown. None of those can be recalled from here.
//
// So this is a COMPENSATING operation over an enumerated list, which says what it could not take back,
// and which refuses outright once Dan has answered on the thread. A partial undo that claims to be
// exact is the L38 defect verbatim; refusing is honest.
enum DetachConversationCopy {
    // Each refusal is spoken by the function that decides it, so a greyed control and the reason beside
    // it cannot disagree (L109).
    // #2797: the control itself. One label for both surfaces, because it is one act.
    static let control = "Unlink this conversation"
    // Phrased as IF. The control is offered on EVERY linked conversation, and most of them are the right
    // one, so a tooltip asserting this one is wrong tells Dan something the app does not know.
    static let controlHelp = "If Overture linked the wrong conversation, unlinking takes back what it recorded from it."

    static let nothingLinked =
        "There's no linked conversation on this pitch to unlink."

    static let alreadyAnswered =
        "You've already answered on this conversation, so Overture can't unlink it. Your message is on "
            + "their thread and unlinking wouldn't take it back."

    // What a successful detach could NOT take back. Named out loud rather than left implied, because a
    // detach that silently restored the row would be claiming an exactness it does not have (L11, L38).
    //
    // Phrased as IF, and split on whether the OmniFocus sync is even on, because neither effect is
    // certain and a line may claim only what its check measured (L11). The away alert fires only on an
    // AUTOMATIC tick, so an attach and detach in the same sitting produces none; the OmniFocus task
    // exists only when Dan has that sync turned on. Saying "clear the task and the alert" to somebody
    // who has neither sends him looking for things that were never there, which is the same defect as
    // saying nothing, pointed the other way.
    static func couldNotUndo(omniFocusEnabled: Bool) -> String {
        let base = "Overture put this show back the way it was, but it can't reach outside the app: "
        guard omniFocusEnabled else { return base + "if an alert went out for this reply, clear it yourself." }
        return base + "if an alert or an OmniFocus task went out for this reply, clear those yourself."
    }
}

@MainActor
enum DetachConversation {

    enum Outcome: Equatable {
        case refused(reason: String)
        // Carries what could not be taken back, so the caller cannot report a clean undo (L12).
        case detached(couldNotUndo: String?)
    }

    @discardableResult
    // `omniFocusEnabled` is injected, defaulting to the real setting, so what the sentence claims can be
    // driven from a test in both states rather than being asserted only by reading it.
    static func detach(_ r: Recipient, on p: Prospect, now: Date,
                       omniFocusEnabled: Bool = OmniFocusSyncConfig.loaded().enabled) -> Outcome {
        guard let attachedAt = r.conversationAttachedAt, r.hasWatchableConversation else {
            return .refused(reason: DetachConversationCopy.nothingLinked)
        }
        // Answered SINCE the attach, not answered at all.
        //
        // The attach itself stamps `replyHandledAt` when the thread's newest message was already Dan's
        // own (#2715), and counting that would make a thread he had already dealt with instantly and
        // permanently un-undoable, which is the exact trap this issue exists to avoid. What makes a
        // detach dishonest is a message that has GONE OUT onto a stranger's conversation since the link
        // was made.
        if let handled = r.replyHandledAt, handled > attachedAt {
            return .refused(reason: DetachConversationCopy.alreadyAnswered)
        }
        if let sent = r.replySentAt, sent > attachedAt {
            return .refused(reason: DetachConversationCopy.alreadyAnswered)
        }

        // The enumerated list. Written out field by field rather than delegating to a general "clear the
        // reply" helper, because the point is that every one of them was checked: a compensating
        // operation that touches N minus 1 of N linked things is L38.
        r.gmailThreadId = nil
        r.attachedThreadSubject = nil
        r.conversationAttachedAt = nil
        // `conversationEverAttachedAt` is deliberately NOT cleared. #3069 removed the undo it was built
        // to refuse, and `wasWrittenTo` reads it now: it is proof a real exchange happened here, and that
        // has to survive the detach or the launch merge can delete the row as untouched.

        // Only the address this attach put there. One that was already on the contact was never the
        // detach's to remove, which is why the attach records which it was rather than leaving the two
        // indistinguishable.
        if r.attachWroteAddress {
            r.email = nil
            r.attachWroteAddress = false
        }

        // Everything `ReplyService.detectReplies` wrote.
        r.replied = false
        r.repliedAt = nil
        r.lastReplyId = nil
        r.lastReplyText = nil
        r.replyAudience = nil
        r.replyFromAddress = nil
        r.replyFromName = nil
        r.inboundReplySentAt = nil
        r.inboundReplyMessageId = nil
        r.replyHandledAt = nil
        r.replyTextCheckedAt = nil

        // Everything `reopenOnReply` destroyed, from the snapshot the attach took (L5).
        r.resolutionRaw = r.attachPriorResolutionRaw
        r.originalReplyDraftBody = r.attachPriorOriginalReplyDraftBody
        r.replyDraftWrittenByDan = r.attachPriorReplyDraftWrittenByDan
        r.replyDraftEditedByDan = r.attachPriorReplyDraftEditedByDan

        // The one the draft missed entirely. Nothing in a detach cleared `pausedByReply`; only
        // `resumePausedRecipients()` does, from the reply-triage paths. So a wrong attach silently froze
        // the show's real, drafted, approved pitch and detaching left it frozen, with nothing on screen
        // saying why. Exactly the rows this attach froze, and no others.
        let frozen = Set(r.attachPausedRecipientIds ?? [])
        for other in p.recipients where frozen.contains(other.id) { other.pausedByReply = false }

        r.attachPriorResolutionRaw = nil
        r.attachPriorOriginalReplyDraftBody = nil
        r.attachPriorReplyDraftWrittenByDan = false
        r.attachPriorReplyDraftEditedByDan = false
        r.attachPausedRecipientIds = nil

        return .detached(couldNotUndo: DetachConversationCopy.couldNotUndo(
            omniFocusEnabled: omniFocusEnabled))
    }

    // #2797: the same compensating operation for a hire INQUIRY, whose conversation #2712 attaches
    // automatically and without asking.
    //
    // The field list is derived from what `AttachConversation.attach(to: Inquiry)` writes, not copied
    // from the pitch version above, and the two genuinely differ. An inquiry has no
    // `attachedThreadSubject`, no recipients frozen by the attach, and no address of the attach's
    // making, because it already carries the address it came from: that is why its match is identity
    // rather than a guess and why it needs no confirming. It has one the pitch does not, `sentAt`,
    // filled from Dan's own message on the thread when the inquiry had none.
    //
    // Written out field by field for the reason the pitch version is: the point is that every one of
    // them was checked, and a compensating operation that touches N minus 1 of N is L38.
    static func detach(_ i: Inquiry, now: Date,
                       omniFocusEnabled: Bool = OmniFocusSyncConfig.loaded().enabled) -> Outcome {
        guard let attachedAt = i.conversationAttachedAt, i.hasWatchableConversation else {
            return .refused(reason: DetachConversationCopy.nothingLinked)
        }
        // Answered SINCE the attach, not answered at all. The attach itself stamps `replyHandledAt` when
        // the thread's newest message was already Dan's own (#2712), and counting that would make a
        // conversation he had already dealt with instantly and permanently un-undoable.
        if let handled = i.replyHandledAt, handled > attachedAt {
            return .refused(reason: DetachConversationCopy.alreadyAnswered)
        }

        i.gmailThreadId = nil
        i.conversationAttachedAt = nil

        // Only the date this attach supplied. One that was already there was never the detach's to
        // remove, which is the same rule `attachWroteAddress` holds above.
        if i.attachWroteSentAt {
            i.sentAt = nil
            i.attachWroteSentAt = false
        }

        // Everything `ReplyService.detectReplies` wrote.
        i.replied = false
        i.repliedAt = nil
        i.lastReplyId = nil
        i.lastReplyText = nil
        i.replyAudience = nil
        i.replyFromAddress = nil
        i.replyFromName = nil
        i.inboundReplySentAt = nil
        i.inboundReplyMessageId = nil
        i.replyHandledAt = nil
        i.replyTextCheckedAt = nil

        return .detached(couldNotUndo: DetachConversationCopy.couldNotUndo(
            omniFocusEnabled: omniFocusEnabled))
    }
}
