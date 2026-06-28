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
    @discardableResult
    static func detectReplies(in prospects: [Prospect], selfEmail: String, now: Date,
                              fetchThread: (String) -> Data?,
                              fetchFullThread: (String) -> Data? = { _ in nil }) -> Int {
        var count = 0
        for p in prospects {
            // A hand-resolved or booked show is closed; stop watching ALL its recipients. (This is a
            // lead-level guard on the MANUAL source only — the A3 auto rollup below never trips it, so
            // one contact's auto reply can't blind another contact, the bug this phase fixes.)
            if p.outcomeSourceRaw == OutcomeSource.manual.rawValue { continue }
            if p.outcome == .booked { continue }
            for r in p.recipients {
                guard let threadId = r.gmailThreadId, !threadId.isEmpty else { continue }
                if r.outcomeSourceRaw == OutcomeSource.manual.rawValue { continue }
                if r.replied || r.resolution == .booked { continue }
                guard let data = fetchThread(threadId),
                      ReplyDetection.hasReply(fromAddresses: ReplyDetection.fromAddresses(threadJSON: data),
                                              selfEmail: selfEmail) else { continue }
                let replyId = ReplyDetection.latestReplyId(threadJSON: data, selfEmail: selfEmail)
                // Dan dismissed this exact reply as not real (#219): skip it, but a newer reply
                // (a different id) still flags. Per-recipient dismiss now.
                if let replyId, replyId == r.dismissedReplyId { continue }
                r.replied = true
                r.repliedAt = now
                r.lastReplyId = replyId
                var body: String?
                if let full = fetchFullThread(threadId) {
                    body = ReplyDetection.latestReplyBody(threadJSON: full, selfEmail: selfEmail)
                    r.lastReplyText = body
                }
                rollUpToLead(p, replyId: replyId, body: body, now: now)
                count += 1
            }
        }
        return count
    }

    // A3 — lead-level rollup bridge: keep the ~10 Prospect-level readers (reminders, the follow-up
    // guard, OmniFocus, classify needsClassify) working unchanged during Phases A-E by rolling any
    // recipient reply up to the lead. Never clobbers Dan's manual call or a booking. Writes lastReplyAt
    // explicitly so ReplyClassifyService.needsClassify's "fresh reply after a hand-set state" re-queue
    // keeps firing. Phase F's pure derivation replaces this temporary writer.
    private static func rollUpToLead(_ p: Prospect, replyId: String?, body: String?, now: Date) {
        if p.outcomeSourceRaw == OutcomeSource.manual.rawValue || p.outcome == .booked { return }
        p.outcome = .replied
        p.outcomeSourceRaw = OutcomeSource.auto.rawValue
        p.outcomeAt = now
        p.lastReplyId = replyId
        if let body {
            p.lastReplyText = body
            p.lastReplyAt = now
        }
    }
}
