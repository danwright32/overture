import Foundation

// Did Dan answer this conversation OUTSIDE Overture, and when? (#2865)
//
// `replyHandledAt` had three writers and every one of them was an act performed inside the app: the
// in-app send, the Copy button, and the attach. So Dan reading a reply in his mail client and answering
// it there left `hasUnhandledReply` true for the life of the row: the Reached out row went on reading
// "waiting since <the day they wrote>", the Answer control went on offering itself, and nothing could
// clear either. A completion flag whose only writers are acts performed inside the product is
// permanently wrong for anyone who does the work in the tool that work actually lives in (L162).
//
// The material was already there. `ReplyService.detectReplies` re-reads a watched thread on every pass
// (it has to, since #2815), holds the very JSON that answers the question, and never asked it.
//
// The attach path's check (`AttachConversation`, #2715) is a ONE-SHOT: it can only speak for the thread
// at the moment of linking. Measured on the live store, a form pitch whose conversation was linked, and
// correctly stamped, then had the contact write again two hours later and Dan answer that from Gmail,
// and the row went back to asking for good. So this is the repeating check, and the attach's branch is a
// special case of it rather than a second rule (L30).
enum AnsweredElsewhere {

    // The instant Dan's answer went, or nil for no evidence of one.
    //
    // The predicate is deliberately narrower than "the newest message is his", which the attach can get
    // away with because a person is standing there looking at the thread they just linked. A pass running
    // unattended cannot, and a row wrongly CLEARED hides a real reply, where a row wrongly left asking
    // costs a glance. So it also requires the message to have gone AFTER theirs, and refuses an automated
    // send from his own address, which is what an out of office reply is: the one thing his mailbox emits
    // by itself, on exactly the threads this runs over.
    //
    // Dated from the message's own `internalDate`, never from the clock. Stamping the moment Overture
    // NOTICED would date the answer days after it went, which is a record about the past taking its value
    // from the present (L37), and it is the same reasoning already written into `latestSentMessageSentAt`.
    static func answeredAt(threadJSON: Data, selfEmail: String, theirMessageArrivedAt: Date?) -> Date? {
        guard let newest = ReplyDetection.newestMessageFromSelf(threadJSON: threadJSON,
                                                                selfEmail: selfEmail) else { return nil }
        guard !newest.isAutomated else { return nil }
        // No record of when theirs arrived is no evidence that his came after it, so it is refused. That
        // is the safe direction: the row keeps asking rather than being cleared on a comparison nobody
        // can make.
        guard let theirs = theirMessageArrivedAt, newest.sentAt > theirs else { return nil }
        return newest.sentAt
    }

    // There is deliberately no "is this new" test here. `Recipient.markReplyAnswered` already refuses to
    // move the stamp backwards, and it is tested, so a second rule stating the same thing would be a
    // branch nothing could observe: written and then mutated away, the suite stayed green (L29, L1).
    // A later pass simply re-derives the same instant and assigns nothing.
}
