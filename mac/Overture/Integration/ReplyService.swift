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
                // #2113: who wrote, and when they sent it. Read from the METADATA thread already in hand,
                // so naming the writer costs no extra Gmail call. Recorded on every contact sharing this
                // thread (each one passes through this loop on its own), because whichever of them the
                // list happens to stand on has to be able to name the person who replied.
                //
                // Safe to spread across the group precisely because Gmail NAMES the sender: it is a fact
                // about the conversation, not a claim about each mailbox. A bounce is the opposite and
                // must never be spread this way (L66).
                recordWriter(on: r, threadJSON: data, selfEmail: selfEmail)
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
                        // #2063: captured from the SAME message as the text, so Dan's answer can be
                        // addressed the way this reply was. Assigned unconditionally, including to nil: a
                        // newer reply must never inherit an older one's audience, and nil is the safe
                        // reading (SendGroup.replyAudience falls back to the writer alone).
                        r.replyAudience = ReplyDetection.latestReplyAudience(threadJSON: full,
                                                                            selfEmail: selfEmail)
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

    // #2113: fill in who wrote on rows that replied before any of this was recorded. Separate from
    // detectReplies rather than folded into it, because detection's own loop deliberately skips a row
    // that has already replied, and reopening that path would re-run everything a first detection does
    // (recapture the text, re-pause the show's unsent contacts, count the reply again) on a conversation
    // Dan may already have worked. This only fills the gaps.
    //
    // Bounded by the gap itself: a row is fetched only when it replied and has no writer recorded, so the
    // pass costs nothing at all once it has run, and nothing on a store that never had the gap.
    @discardableResult
    static func backfillResponders(in entities: [any ReplyWatchable], selfEmail: String,
                                   fetchThread: (String) -> Data?) -> Int {
        var filled = 0
        for p in entities {
            for r in p.replyWatchRecipients {
                // The gap itself is the bound: a row that never replied has nothing to name, and one that
                // already names its writer is done forever.
                guard r.replied, r.replyFromAddress == nil else { continue }
                guard let threadId = r.gmailThreadId, !threadId.isEmpty else { continue }
                guard let data = fetchThread(threadId),
                      ReplyDetection.latestReplySender(threadJSON: data, selfEmail: selfEmail) != nil
                else { continue }
                recordWriter(on: r, threadJSON: data, selfEmail: selfEmail)
                filled += 1
            }
        }
        return filled
    }

    // The one place the writer is read off a thread, shared by first detection and the backfill, so the
    // two can never disagree about who wrote or when they sent it.
    private static func recordWriter(on r: any ReplyWatchableRecipient, threadJSON data: Data,
                                     selfEmail: String) {
        guard let address = ReplyDetection.latestReplySender(threadJSON: data, selfEmail: selfEmail) else { return }
        r.replyFromAddress = address
        r.replyFromName = ReplyDetection.latestReplySenderHeader(threadJSON: data, selfEmail: selfEmail)
            .flatMap { ReplyDetection.displayName(from: $0) }
        r.inboundReplySentAt = ReplyDetection.latestReplySentAt(threadJSON: data, selfEmail: selfEmail)
    }
}
