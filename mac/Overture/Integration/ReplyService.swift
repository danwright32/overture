import Foundation

// Marks a contacted prospect .replied (source auto) when its Gmail thread has a reply
// (#40). The thread fetch is injected so the marking logic is testable without network;
// the live path pre-fetches threads via the Gmail API and passes a lookup closure.
// Manual outcomes and already-known stronger outcomes (replied/booked) are never touched.
@MainActor
enum ReplyService {
    @discardableResult
    static func detectReplies(in prospects: [Prospect], selfEmail: String, now: Date,
                              fetchThread: (String) -> Data?) -> Int {
        var count = 0
        for p in prospects {
            guard let threadId = p.gmailThreadId, !threadId.isEmpty, p.sentAt != nil else { continue }
            if p.outcomeSourceRaw == OutcomeSource.manual.rawValue { continue }
            if p.outcome == .replied || p.outcome == .booked { continue }
            guard let data = fetchThread(threadId) else { continue }
            if ReplyDetection.hasReply(fromAddresses: ReplyDetection.fromAddresses(threadJSON: data),
                                       selfEmail: selfEmail) {
                p.outcome = .replied
                p.outcomeSourceRaw = OutcomeSource.auto.rawValue
                p.outcomeAt = now
                count += 1
            }
        }
        return count
    }
}
