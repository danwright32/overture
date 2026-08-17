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
            // #2147: every address this entity was written at, so a reply from one that is NOT among them
            // can be told apart from one that is.
            var contactAddresses: [String] = []
            for r in p.replyWatchRecipients {
                guard let t = r.gmailThreadId, !t.isEmpty else { continue }
                contactsPerThread[t, default: 0] += 1
                if let a = r.replyWatchAddress, !a.isEmpty { contactAddresses.append(a) }
            }
            for r in p.replyWatchRecipients {
                guard let threadId = r.gmailThreadId, !threadId.isEmpty else { continue }
                if r.replyWatchManualOutcome { continue }
                if r.replyWatchIsBooked { continue }
                // #2196: a contact that has already replied used to be skipped outright, and that skip was
                // the only route to the fields the reopen rule reads. So they wrote, Dan answered, the row
                // went quiet, and everything they sent afterwards was invisible: no badge, no task, no row
                // asking. On the highest-value path Overture has.
                //
                // It is re-read while its conversation is still open, which is both the useful set and the
                // bound on the cost: one thread fetch per live conversation per check.
                //
                // #2815: through `ReplyWatchScope`, which is the same predicate deciding WHICH threads are
                // fetched. Stated only here, this rule reached nothing: the fetch scope asked the narrower
                // "does this row still have a gap to fill", that gap closes on the pass that records the
                // first reply, and so the thread this loop is willing to re-read was never handed to it.
                // The bound quoted above was the one thing it could not get (L16, L70).
                if !ReplyWatchScope.couldReceiveANewMessage(r) { continue }
                let alreadyReplied = r.replied
                guard let data = fetchThread(threadId),
                      ReplyDetection.hasReply(fromAddresses: ReplyDetection.fromAddresses(threadJSON: data),
                                              selfEmail: selfEmail) else { continue }
                let replyId = ReplyDetection.latestReplyId(threadJSON: data, selfEmail: selfEmail)
                // Dan dismissed this exact reply as not real (#219): skip it, but a newer reply
                // (a different id) still flags. Per-recipient dismiss now.
                if let replyId, replyId == r.dismissedReplyId { continue }
                // #2865: did Dan answer this in his mail client? Asked HERE, with `data` already in hand
                // and BEFORE the `alreadyReplied` guard below, because that guard is what these rows take:
                // a contact who replied, was answered outside Overture, and has not written since has no
                // new reply id, so it `continue`s on every pass. The check placed anywhere after it would
                // never execute for the rows it exists for while passing every test that hands the
                // function a thread with a new message on it (L3, the third time in this area: #2196,
                // #2815, and this).
                //
                // It costs no extra Gmail call: the metadata thread it reads is the one already fetched.
                if alreadyReplied, let answered = AnsweredElsewhere.answeredAt(
                        threadJSON: data, selfEmail: selfEmail,
                        theirMessageArrivedAt: r.replyArrivedAt) {
                    // On the contact itself, with NO fan-out to peers, which is the one place this
                    // differs from `AnsweredReply` and is deliberate. Every contact sharing the thread
                    // passes through this loop on its own and records its own answer, which the colleague
                    // test proves. And every peer this loop SKIPS is one that is not asking anyway: the
                    // skips are `replyWatchConversationIsOpen` (resolution set, or bounced), a booked
                    // contact and a hand-resolved one, and `hasUnhandledReply` reads those same facts
                    // first. A fan-out here would be code nothing could reach (L29).
                    r.recordAnsweredElsewhere(at: answered)
                }
                if alreadyReplied {
                    // The id decides it, so the same thread re-read on every check for the life of a
                    // conversation changes nothing. Nothing on it since the last look.
                    guard let replyId, replyId != r.lastReplyId else { continue }
                    // No baseline recorded, so this build cannot say whether the newest message is new.
                    // Adopt it and stop: calling an unknown "new" would re-open every such row at once on
                    // the first check after this ships, which is the alert nobody believes afterwards
                    // (L36). The next genuinely new message is then found normally.
                    guard r.lastReplyId != nil else { r.lastReplyId = replyId; continue }
                }
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
                    let sender = ReplyDetection.latestReplySender(threadJSON: full, selfEmail: selfEmail)
                    let wroteIt = !shared || ReplyDetection.isSameAddress(sender, r.replyWatchAddress)
                    // #2147: a sender who is NONE of the contacts on this thread. Measured on the live
                    // store: Dan pitched nbecker@ and Nicole answered from nicolebecker@, so the words
                    // matched nobody and were filed against nobody, and the panel told him Overture had
                    // not captured a message it had just read.
                    //
                    // They belong to the CONVERSATION, so every contact on the thread keeps them. Nothing
                    // is misattributed by that, because replyFromAddress names who actually wrote and the
                    // surfaces show it; the rule above still holds for a sender who IS one of them.
                    let fromOutside = shared && !contactAddresses.contains { ReplyDetection.isSameAddress(sender, $0) }
                    if wroteIt || fromOutside {
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
    static func backfillResponders(in entities: [any ReplyWatchable], selfEmail: String, now: Date,
                                   fetchThread: (String) -> Data?,
                                   fetchFullThread: (String) -> Data? = { _ in nil }) -> Int {
        var filled = 0
        for p in entities {
            for r in p.replyWatchRecipients {
                // The gap itself is the bound: a row that never replied has nothing to fill, and one that
                // already names its writer AND holds the words is done forever.
                //
                // #2147: the words are part of the gap now. A reply from an address none of the contacts
                // were written at used to be filed against nobody, so rows that replied before that fix
                // carry a writer and no message at all, and the panel tells Dan nothing was captured.
                guard ReplyGap.needsFilling(r) else { continue }
                guard let threadId = r.gmailThreadId, !threadId.isEmpty else { continue }
                guard let data = fetchThread(threadId),
                      ReplyDetection.latestReplySender(threadJSON: data, selfEmail: selfEmail) != nil
                else { continue }
                if r.replyFromAddress == nil { recordWriter(on: r, threadJSON: data, selfEmail: selfEmail) }
                // The body needs the full thread, which the caller fetches only for threads that have one.
                if r.lastReplyText == nil, let full = fetchFullThread(threadId) {
                    r.lastReplyText = ReplyDetection.latestReplyBody(threadJSON: full, selfEmail: selfEmail)
                    // #2149: stamped whether or not a body came back. A reply with no decodable body
                    // (HTML-only, attachment-only) returns nil every time, so recording only success
                    // leaves the row in the gap and refetches this thread on every check forever. The
                    // attempt is the thing that has to be remembered, on the row it failed on (L47).
                    r.replyTextCheckedAt = now
                    if r.replyAudience == nil {
                        r.replyAudience = ReplyDetection.latestReplyAudience(threadJSON: full, selfEmail: selfEmail)
                    }
                }
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
        // #2653: the id of the message being answered, which was read off this very thread and thrown
        // away, so the answer threaded off Overture's own last message instead. Captured HERE with the
        // rest of the writer's facts rather than at a second call site, for the same reason they are.
        r.inboundReplyMessageId = ReplyDetection.latestReplyMessageID(threadJSON: data, selfEmail: selfEmail)
    }

    // #2653: the capture, reachable from a test. `recordWriter` is private because nothing outside this
    // file may write these facts, and that same privacy made the one place they are decided untestable.
    static func recordWriterForTesting(on r: any ReplyWatchableRecipient, threadJSON data: Data,
                                       selfEmail: String) {
        recordWriter(on: r, threadJSON: data, selfEmail: selfEmail)
    }
}
