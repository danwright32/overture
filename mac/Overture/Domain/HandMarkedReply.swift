import Foundation

// #2711: Dan tells Overture that a reply arrived on a channel it cannot watch.
//
// A pitch sent as a social DM (#2612) can be answered inside Instagram, and that answer will never exist
// in Gmail. Linking a Gmail conversation (#2715) cannot help there, because there is no email to link. So
// the show stayed recorded as silent until its decide date arrived, and the funnel filed a show that
// really got an answer as "no response", which is a zero indistinguishable from a real measurement (L90).
//
// The mark writes the same fields a DETECTED reply writes, through the same functions rather than a
// second set, so every downstream reader behaves identically: `pausePendingForReply` (which is what stops
// Overture pitching the rest of the show's contacts underneath a live conversation), the unhandled-reply
// badge, the decide clock, and #16's outcome reporting.
//
// What it deliberately does NOT write is anything that would claim a message exists. There are no words,
// no message id and no thread, and a surface that would show the reply's text says what actually happened
// instead of rendering an empty message box (L10, L11).
enum HandMarkedReplyCopy {
    // The control. In Dan's own voice, the same shape as the form pitch's "I sent it", because this is
    // the same kind of act: him telling Overture something only he can know.
    //
    // Deliberately NOT "They replied", which was the first wording and which `InquiryCopy.rowState`
    // already uses as a STATE LABEL on an inquiry row. One wording standing for a fact on one row and an
    // action on another is the collision that only shows up when the two are read together (L118), and
    // the copy inventory's duplicate list is what caught it.
    static let mark = "They got back to me"
    // Its undo. Named as an UNDO rather than as the opposite fact, because "They didn't reply" sits one
    // control away from the close-out menu, where "No response" is a real ending Dan can record: two
    // controls a row apart, each reading as a statement that nobody answered, would be one wording
    // standing for two different acts (L118). What it undoes is on the card beside it, which says in
    // words that he told Overture they replied.
    static let undo = "Undo that"
    // Why the undo is refused. From the same function that refuses, so a greyed control can never sit
    // beside no reason (L109).
    static let cannotUndoAfterAnswering =
        "You've already answered this one, so Overture can't take the reply back."
}

enum HandMarkedReply {
    // Whether this contact can be marked at all: pitched, on a channel Overture cannot watch, and not
    // already carrying a reply. A contact with a conversation is detection's business, and two writers
    // racing over one fact is what this must not become (L55).
    static func isOffered(_ r: Recipient) -> Bool {
        guard r.hasProvenOutreach else { return false }
        guard !r.hasWatchableConversation else { return false }
        return !r.replied
    }

    // Record it. Returns false when it did not apply, including on a second press: the recorded date is
    // what the decide clock counts from and what #16 attributes an outcome to, so a second click must not
    // move it (assume it runs twice).
    @discardableResult
    static func mark(_ r: Recipient, in p: Prospect, now: Date) -> Bool {
        guard isOffered(r) else { return false }
        // Recorded BEFORE the reopen, because that is the only thing `reopenOnReply` destroys which
        // nothing else remembers, and without it the undo below cannot exist (L5). The three reply-draft
        // fields it also nulls are nil by construction here: they are written by the reply-draft flow,
        // which needs a reply, and this contact has never had one.
        r.replyMarkClearedStandDown = r.resolution == .stoodDown
        // #1840: through the one reopen, so a contact Dan stood down who then wrote back is not left
        // recorded as closed. The same call detection makes, for the same reason.
        r.reopenOnReply(at: now)
        r.replyMarkedByHandAt = now
        // #430: the same pause a detected reply raises, so the rest of the show's contacts are held back
        // while Dan works the conversation.
        p.pausePendingForReply()
        return true
    }

    // Why the undo is refused, or nil when it may run.
    static func undoRefusal(_ r: Recipient) -> String? {
        guard r.replyMarkedByHandAt != nil else { return nil }
        guard r.replyHandledAt != nil || r.replySentAt != nil else { return nil }
        return HandMarkedReplyCopy.cannotUndoAfterAnswering
    }

    // Take it back. A compensating operation over the exact list `mark` wrote, not a guess at an inverse
    // (L38). Refused once Dan has answered, because the answer is the one thing it cannot take back, and
    // refusing is honest where a partial undo claiming to be exact is not.
    //
    // Only ever undoes a HAND mark. A reply Overture detected is not this control's to reverse; that is
    // `dismissAutoReply` (#219), which also remembers which message was wrong so detection does not
    // immediately re-flag it.
    @discardableResult
    static func undo(_ r: Recipient, in p: Prospect) -> Bool {
        guard r.replyMarkedByHandAt != nil else { return false }
        guard undoRefusal(r) == nil else { return false }

        r.replied = false
        r.repliedAt = nil
        r.replyMarkedByHandAt = nil
        if r.replyMarkClearedStandDown {
            r.resolution = .stoodDown
            r.replyMarkClearedStandDown = false
        }
        // The pause is the one effect that reaches OTHER rows, so it is lifted only when nothing else on
        // the show is still owed it. Resuming unconditionally would put Overture back to cold-pitching a
        // colleague underneath a conversation somebody else on the show is having, which is the exact
        // thing the pause exists to prevent (L38: a state exit enumerates every derived resource, and
        // this one is shared).
        if !p.recipients.contains(where: \.hasUnhandledReply) {
            p.resumePausedRecipients()
        }
        return true
    }
}
