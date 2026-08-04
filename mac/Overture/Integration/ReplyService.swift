import Foundation

// Marks a contacted RECIPIENT .replied (source auto) when its Gmail thread has a reply (#40, #418
// A2). Per-recipient now: each contact on a performance has its OWN thread, so a reply to any one of
// them is detected on that contact's thread and never lost behind the first contact's state. The
// thread fetch is injected so the marking logic is testable without network. Manual marks
// (per-recipient and lead-level) and a booked show are never overwritten.
@MainActor
enum ReplyService {
    // `fetchThread` returns the cheap metadata thread (From headers) used to detect a reply;
    // `fetchFullThread` returns the full thread WITH the body, and is consulted only for a thread
    // that actually has a reply (lazy), so the body text is captured for the classify workflow (#112)
    // without pulling full bodies for the whole sent list. Threads are keyed by recipient.gmailThreadId.
    // Genericized over `ReplyWatchable` (#1434) so an Inquiry rides the same pipeline; behavior for
    // `Prospect` is unchanged (it flows in via the implicit `[Prospect]` → `[any ReplyWatchable]` upcast).
    @discardableResult
    static func detectReplies(in entities: [any ReplyWatchable], selfEmail: String, now: Date,
                              fetchThread: (String) -> Data?,
                              fetchFullThread: (String) -> Data? = { _ in nil }) -> Int {
        var count = 0
        for p in entities {
            // A hand-resolved or booked show is closed; stop watching ALL its recipients. This is a
            // lead-level guard on the MANUAL source only, so one contact's reply can't blind another.
            if p.replyWatchManualOutcome { continue }
            if p.replyWatchIsBooked { continue }
            var newReply = false
            // #2032: how many of this entity's contacts sit on each thread. A thread carrying more than
            // one is a JOINT send: the reply belongs to all of them (they are reading one conversation),
            // but the WORDS belong to whoever wrote them.
            var contactsPerThread: [String: Int] = [:]
            for r in p.replyWatchRecipients {
                guard let t = r.gmailThreadId, !t.isEmpty else { continue }
                contactsPerThread[t, default: 0] += 1
            }
            for r in p.replyWatchRecipients {
                guard let threadId = r.gmailThreadId, !threadId.isEmpty else { continue }
                if r.replyWatchManualOutcome { continue }
                if r.replied || r.replyWatchIsBooked { continue }
                guard let data = fetchThread(threadId),
                      ReplyDetection.hasReply(fromAddresses: ReplyDetection.fromAddresses(threadJSON: data),
                                              selfEmail: selfEmail) else { continue }
                let replyId = ReplyDetection.latestReplyId(threadJSON: data, selfEmail: selfEmail)
                // Dan dismissed this exact reply as not real (#219): skip it, but a newer reply
                // (a different id) still flags. Per-recipient dismiss now.
                if let replyId, replyId == r.dismissedReplyId { continue }
                // #1840: through the one reopen, so a contact Dan stood down and who then wrote back is
                // not left recorded as a closed lead. Written as a call rather than two assignments
                // because the rule ("a reply clears the stand-down, and only the stand-down") has to hold
                // wherever a reply is recorded, not just here.
                r.reopenOnReply(at: now)
                r.lastReplyId = replyId
                if let full = fetchFullThread(threadId) {
                    // On a thread only this contact is on, the sender can only be them, so this is the
                    // path every existing thread in the store takes, unchanged.
                    //
                    // On a SHARED thread the text is evidence of who said it: it goes to the contact whose
                    // address it came from and to nobody else. A reply from an address nobody was written
                    // at (a colleague brought in, somebody answering from their own account) still counts
                    // as a reply above; it simply leaves no words filed under a name that did not write
                    // them, rather than crediting one of them at random (L11).
                    let shared = contactsPerThread[threadId, default: 0] > 1
                    let wroteIt = !shared || ReplyDetection.isSameAddress(
                        ReplyDetection.latestReplySender(threadJSON: full, selfEmail: selfEmail),
                        r.replyWatchAddress)
                    if wroteIt {
                        r.lastReplyText = ReplyDetection.latestReplyBody(threadJSON: full, selfEmail: selfEmail)
                    }
                }
                count += 1
                newReply = true
            }
            // #430: a reply on this show auto-pauses its still-unsent contacts pending Dan's triage,
            // so the drip/queue won't email them while he reads and responds to the reply.
            if newReply { p.pausePendingForReply() }
        }
        return count
    }
}
