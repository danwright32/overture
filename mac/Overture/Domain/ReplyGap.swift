import Foundation

// #2149: which replied rows still have something missing that a refetch could fill, in ONE place.
//
// Two passes ask this and they must ask it identically. GmailReplyChecker decides which THREADS to pull
// from Gmail; ReplyService.backfillResponders decides which ROWS to fill from what came back. When the two
// disagreed, the checker went on fetching a thread the fill had already given up on, which is a permanent
// no-progress loop against Gmail that nothing in the app shows.
enum ReplyGap {
    // The gap is bounded by ATTEMPTS, not by success. A writer is recoverable whenever the thread names a
    // sender, so its absence is a fair thing to keep retrying. The message TEXT is not: a reply with no
    // decodable body (HTML-only, attachment-only) yields nil every single time, so "still missing" can
    // never end. `replyTextCheckedAt` records that the fill ran on this row whether or not it produced
    // anything, which is what L47 requires of a pass that fails on an item.
    static func needsFilling(_ r: any ReplyWatchableRecipient) -> Bool {
        guard r.replied else { return false }
        if r.replyFromAddress == nil { return true }
        return r.lastReplyText == nil && r.replyTextCheckedAt == nil
    }
}
