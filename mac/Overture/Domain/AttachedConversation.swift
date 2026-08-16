import Foundation

// #2717: a conversation Overture is WATCHING but never SENT on.
//
// A non-empty `gmailThreadId` used to mean one thing: Overture emailed this contact, so it may add its
// own next message to the conversation. Milestone #58 gives the field a second writer, Dan attaching the
// Gmail conversation a form or DM pitch was answered on (#2715), and on that row Overture has sent
// nothing at all. Anything that would post a NEW message of Overture's own onto such a thread has to
// refuse, because an unparented message dropped into a stranger's conversation is exactly the defect
// #2647, #2649 and #2653 were filed for, arriving by a new route.
//
// The predicate lives beside its sentence so the refusal and the reason come from one function and cannot
// disagree (L109).
enum AttachedConversationCopy {
    // Names the show, because a line in the problem ledger that does not say WHICH show is a fact Dan
    // cannot act on (L80). It points at Gmail rather than at a control in Overture, which is honest: this
    // is a conversation Overture is not a party to, and there is nothing in the app that can continue it.
    static func cannotContinue(groupName: String) -> String {
        "Overture didn't email \(groupName), so it can't add a message to the conversation you linked. Write to them in Gmail instead."
    }
}

enum AttachedConversation {
    // Nil when Overture may continue the conversation, a sentence saying why not when it may not.
    //
    // #2796: BOTH halves, because for a year this asked only the first and had no caller at all. #2717
    // wrote it for three send paths and none of them could use it: the closing note went with #2710, the
    // follow-up cannot reach an attached row (`isAwaitingFollowUp` demands `outreachChannel == .email`
    // and an attached conversation only ever sits on a `.contactForm` one), and both reply paths were
    // exempted on the grounds that an answer threads onto THEIR message, which is the whole point of
    // attaching a conversation and is Dan's stated promise of full parity once one is attached.
    //
    // That exemption is right in the ordinary case and wrong in one, which is the case this now refuses.
    // `ReplyThreading.inReplyTo` prefers their message and falls back to OURS, and an attached
    // conversation never has one of ours, so a row that replied off a message carrying no `Message-ID`
    // header (the Gmail resource `id` that detection keys the reply on is always present; the header is
    // not) leaves the answer with nothing at all to hang off. Overture would then drop an unparented
    // message into a conversation it never sent on, which is #2647, #2649 and #2653's defect arriving by
    // exactly the new route #2717 was filed to close.
    //
    // Asked through `ReplyThreading` rather than by reading the two fields here, so the guard and the
    // send cannot disagree about what the message would have hung off (L16, L70).
    //
    // It heals by itself, twice over: the next detection pass that reads a message of theirs carrying a
    // header lifts it, and so does Overture's own first send on the thread. A refusal keyed on the attach
    // alone would go on refusing long after its reason had gone (L68).
    static func refusalToContinue(_ r: any ReplyWatchableRecipient, displayName: String) -> String? {
        guard r.replyWatchConversationIsAttached else { return nil }
        let parent = ReplyThreading.inReplyTo(for: r)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard parent?.isEmpty ?? true else { return nil }
        return AttachedConversationCopy.cannotContinue(groupName: displayName)
    }
}
