import Foundation

// Marks a contacted RECIPIENT .bounced (source stays auto) when its Gmail thread carries a
// genuine hard bounce (#398). Mirrors ReplyService's per-recipient loop and guards exactly: a
// hand-resolved contact or lead, a booked show, an already-bounced, already-replied, or
// already-booked-resolution contact are never touched, and a bounce Dan already dismissed
// (dismissedBounceId) never re-flags. Metadata-only: no full-thread fetch needed, since
// BounceDetection classifies purely from the From + Subject headers GmailReplyChecker already
// requests.
//
// #2032: a thread carrying MORE THAN ONE contact is the exception, and it is not an oversight that
// nobody is marked on it. The failed address lives in the delivery-status part of the message body, and
// this classifies from the From and Subject headers alone, so on a shared thread the app knows an email
// bounced and cannot know whose. Marking both would silence a contact whose mail arrived; marking
// neither and saying nothing would hide a real delivery failure. So it reports, once per notice.
//
// Also notices a soft/temporary delay notice on the same already-fetched thread (#656), purely
// informational: it never sets bounced and never affects isSilent or follow-up eligibility. A
// hard bounce takes precedence when a thread somehow carries both.
@MainActor
enum BounceService {
    // Genericized over `ReplyWatchable` (#1434), mirroring ReplyService; behavior for `Prospect` is
    // unchanged (it flows in via the implicit `[Prospect]` → `[any ReplyWatchable]` upcast).
    @discardableResult
    static func detectBounces(in entities: [any ReplyWatchable], selfEmail: String, now: Date,
                             fetchThread: (String) -> Data?,
                             reportProblem: (String) -> Void = { AgentLog.problem($0) }) -> Int {
        var count = 0
        for p in entities {
            if p.replyWatchManualOutcome { continue }
            if p.replyWatchIsBooked { continue }
            // #2032: which threads carry more than one of this entity's contacts. On one of those, a
            // bounce cannot be attributed at all (see the note above detectBounces), so it is reported
            // rather than written to anybody.
            var contactsPerThread: [String: [any ReplyWatchableRecipient]] = [:]
            for r in p.replyWatchRecipients {
                guard let t = r.gmailThreadId, !t.isEmpty else { continue }
                contactsPerThread[t, default: []].append(r)
            }
            var reportedThreads: Set<String> = []
            for r in p.replyWatchRecipients {
                guard let threadId = r.gmailThreadId, !threadId.isEmpty else { continue }
                if r.replyWatchManualOutcome { continue }
                if r.bounced || r.replied || r.replyWatchIsBooked { continue }
                guard let data = fetchThread(threadId) else { continue }
                if let bounceId = BounceDetection.hardBounceMessageId(threadJSON: data, selfEmail: selfEmail),
                   bounceId != r.dismissedBounceId {
                    let onThread = contactsPerThread[threadId] ?? [r]
                    // #2717: a conversation Overture never sent on (#2715) was never in this detector's
                    // calibration. Any bounce notice on an attached thread belongs to a message Dan or the
                    // presenter sent, never to Overture's pitch, so blaming this contact for it would
                    // write off a perfectly good address: `bounced` drops the contact out of the
                    // reached-out queue and closes the show through PerformanceStatus (L66, L42).
                    //
                    // Reported rather than ignored, through the same channel and the same once-only
                    // `lastBounceId` mechanism as the multi-contact case below, so a genuinely dead
                    // address is not made invisible by the refusal to attribute it (L13). Filtering
                    // automated senders at SEARCH time cannot cover this, because the classification
                    // happens here, later, over the whole thread.
                    if onThread.count == 1, r.replyWatchConversationIsAttached {
                        if !reportedThreads.contains(threadId), r.lastBounceId != bounceId {
                            reportedThreads.insert(threadId)
                            reportProblem("A message in the conversation you linked to \(p.replyWatchDisplayName) bounced. Overture didn't send it, so it cannot tell whose address failed. Check it in Gmail")
                        }
                        r.lastBounceId = bounceId
                        continue
                    }
                    if onThread.count > 1 {
                        // Nobody is marked. `bounced` removes a contact from follow-ups and the reached-out
                        // queue and closes the show through PerformanceStatus, so marking everyone on the
                        // thread would write the whole show off on behalf of one address that may well be
                        // fine. Report it once per notice instead, and let Dan look (L13, L42).
                        //
                        // `lastBounceId` is what makes it once: it records the notice that was SEEN, which
                        // is true whether or not anybody could be blamed for it, and a later notice with a
                        // different id reports again.
                        if !reportedThreads.contains(threadId), onThread.contains(where: { $0.lastBounceId != bounceId }) {
                            reportedThreads.insert(threadId)
                            let addresses = onThread.compactMap(\.replyWatchAddress).joined(separator: ", ")
                            reportProblem("An email to \(p.replyWatchDisplayName) bounced, and it went to more than one person (\(addresses)), so Overture cannot tell which address failed. Check the bounce in Gmail and fix or remove the dead address")
                        }
                        for member in onThread { member.lastBounceId = bounceId }
                        continue
                    }
                    r.bounced = true
                    r.lastBounceId = bounceId
                    count += 1
                    continue   // superseded by a hard bounce; no need to also flag a delay
                }
                if let delayId = BounceDetection.delayMessageId(threadJSON: data, selfEmail: selfEmail),
                   delayId != r.lastDelayMessageId {
                    r.lastDelayMessageId = delayId
                    r.delayNoticeAt = now
                }
            }
        }
        return count
    }
}
