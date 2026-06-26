import Foundation

// Marks a contacted prospect .replied (source auto) when its Gmail thread has a reply
// (#40). The thread fetch is injected so the marking logic is testable without network;
// the live path pre-fetches threads via the Gmail API and passes a lookup closure.
// Manual outcomes and already-known stronger outcomes (replied/booked) are never touched.
@MainActor
enum ReplyService {
    // `fetchThread` returns the cheap metadata thread (From headers) used to detect a reply;
    // `fetchFullThread` returns the full thread WITH the body, and is consulted only for a thread
    // that actually has a reply (lazy), so the body text is captured for the classify workflow (#112)
    // without pulling full bodies for the whole sent list.
    @discardableResult
    static func detectReplies(in prospects: [Prospect], selfEmail: String, now: Date,
                              fetchThread: (String) -> Data?,
                              fetchFullThread: (String) -> Data? = { _ in nil }) -> Int {
        var count = 0
        for p in prospects {
            guard let threadId = p.gmailThreadId, !threadId.isEmpty, p.sentAt != nil else { continue }
            if p.outcomeSourceRaw == OutcomeSource.manual.rawValue { continue }
            if p.outcome == .replied || p.outcome == .booked { continue }
            guard let data = fetchThread(threadId) else { continue }
            if ReplyDetection.hasReply(fromAddresses: ReplyDetection.fromAddresses(threadJSON: data),
                                       selfEmail: selfEmail) {
                let replyId = ReplyDetection.latestReplyId(threadJSON: data, selfEmail: selfEmail)
                // Dan dismissed this exact reply as not real (#219): skip it, but a newer reply
                // (a different id) still flags.
                if let replyId, replyId == p.dismissedReplyId { continue }
                p.outcome = .replied
                p.outcomeSourceRaw = OutcomeSource.auto.rawValue
                p.outcomeAt = now
                p.lastReplyId = replyId
                if let full = fetchFullThread(threadId),
                   let body = ReplyDetection.latestReplyBody(threadJSON: full, selfEmail: selfEmail) {
                    p.lastReplyText = body
                    p.lastReplyAt = now
                }
                count += 1
            }
        }
        return count
    }
}
