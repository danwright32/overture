import Foundation

// #2815: WHICH watched conversations this pass has to read, in one place.
//
// There are two questions here and they are not the same question. Conflating them is what produced the
// defect: #2196 taught the DETECTOR to re-read an already-replied contact while its conversation is still
// open, and the FETCHER went on collecting a replied row only while `ReplyGap.needsFilling` was true. That
// gap closes on the very pass that records the first reply, so the detector was willing and the thread was
// never supplied to it. Everything that arrived on a conversation after its first reply was recorded was
// therefore invisible: no badge, no task, no row asking, on the highest-value path the product has.
//
//   * "does this row still have something MISSING that a refetch could fill?"   ReplyGap.needsFilling
//   * "could a NEW message still arrive on this row's conversation?"            couldReceiveANewMessage
//
// The fetch scope is the UNION, because it feeds three readers that ask different halves of it:
// `ReplyService.detectReplies` (new messages), `ReplyService.backfillResponders` (the gap), and
// `BounceService.detectBounces` (never-replied rows). A thread nobody asked for costs a Gmail call for
// nothing; a thread one of them needed and did not get is this issue (L16, L70).
enum ReplyWatchScope {
    // Could a new message still arrive here, and therefore does the watcher have to keep reading it?
    //
    // A row that has never replied is always watched, which is the ordinary case and unchanged: a first
    // reply, a bounce or a delay notice can all still land on it. A row that HAS replied is watched while
    // its conversation is open, which is the same bound `detectReplies` applies and the same one
    // `ReplySearchScope.inScope` applies to the pitches that have no conversation to watch.
    //
    // It is also the bound on the cost. The set of open conversations is small and shrinks as Dan closes
    // them out, where "every contact that ever replied" would grow with every show he ever pitched.
    static func couldReceiveANewMessage(_ r: any ReplyWatchableRecipient) -> Bool {
        guard r.replied else { return true }
        return r.replyWatchConversationIsOpen
    }

    // Every reason this pass has to pull a thread. Read by `GmailReplyChecker.threadsToCheck`, which is
    // the only place threads are collected, so no reader can be starved of one by asking a narrower
    // question than the one that decided the fetch.
    static func isWatched(_ r: any ReplyWatchableRecipient) -> Bool {
        couldReceiveANewMessage(r) || ReplyGap.needsFilling(r)
    }

    // #3937 (phase 1 of #2920): should the FAST lane read this thread too? Dan's scope, 2026-09-16: a
    // conversation with a live reply, or a pitch whose run has not passed.
    //
    // It takes the ENTITY as well as the recipient because a recipient carries no date, and the date is
    // half the question (L83). It starts from `isWatched`, so the fast set is the watched set narrowed and
    // can never reach a thread the half-hourly check would not (L16). Rows watched only for a gap
    // (`ReplyGap`) ride the fast lane only while their run is current; the fast lane's reader is reply
    // detection, and `backfillResponders` skips a thread it was not given rather than stamping it checked.
    static func isFastChecked(_ entity: any ReplyWatchable, _ r: any ReplyWatchableRecipient,
                              today: String) -> Bool {
        guard isWatched(r) else { return false }
        return hasLiveReply(r) || entity.replyWatchIsCurrent(today: today)
    }

    // They wrote, and nothing has closed the conversation since. Deliberately the same bound
    // `couldReceiveANewMessage` applies to a replied row, so a reply the watcher still reads on a live
    // conversation is exactly the one the fast lane reads, whatever the show's date.
    static func hasLiveReply(_ r: any ReplyWatchableRecipient) -> Bool {
        r.replied && r.replyWatchConversationIsOpen
    }
}
