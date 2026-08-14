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
    static func refusalToContinue(_ r: any ReplyWatchableRecipient, displayName: String) -> String? {
        guard r.replyWatchConversationIsAttached else { return nil }
        return AttachedConversationCopy.cannotContinue(groupName: displayName)
    }
}
