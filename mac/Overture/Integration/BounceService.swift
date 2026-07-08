import Foundation

// Marks a contacted RECIPIENT .bounced (source stays auto) when its Gmail thread carries a
// genuine hard bounce (#398). Mirrors ReplyService's per-recipient loop and guards exactly: a
// hand-resolved contact or lead, a booked show, an already-bounced, already-replied, or
// already-booked-resolution contact are never touched, and a bounce Dan already dismissed
// (dismissedBounceId) never re-flags. Metadata-only: no full-thread fetch needed, since
// BounceDetection classifies purely from the From + Subject headers GmailReplyChecker already
// requests.
@MainActor
enum BounceService {
    @discardableResult
    static func detectBounces(in prospects: [Prospect], selfEmail: String, now: Date,
                             fetchThread: (String) -> Data?) -> Int {
        var count = 0
        for p in prospects {
            if p.outcomeSourceRaw == OutcomeSource.manual.rawValue { continue }
            if p.outcome == .booked { continue }
            for r in p.recipients {
                guard let threadId = r.gmailThreadId, !threadId.isEmpty else { continue }
                if r.outcomeSourceRaw == OutcomeSource.manual.rawValue { continue }
                if r.bounced || r.replied || r.resolution == .booked { continue }
                guard let data = fetchThread(threadId),
                      let bounceId = BounceDetection.hardBounceMessageId(threadJSON: data, selfEmail: selfEmail)
                else { continue }
                if bounceId == r.dismissedBounceId { continue }
                r.bounced = true
                r.lastBounceId = bounceId
                count += 1
            }
        }
        return count
    }
}
