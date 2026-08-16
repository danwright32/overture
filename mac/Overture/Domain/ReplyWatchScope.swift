import Foundation

// #2815: WHICH watched conversations this pass has to read, in one place.
//
// There are two questions here and they are not the same question. Conflating them is what produced the
// defect: #2196 taught the DETECTOR to re-read an already-replied contact while its conversation is still
// open, and the FETCHER went on collecting a replied row only while `ReplyGap.needsFilling` was true. That
// gap closes on the very pass that records the first reply, so the detector was willing and the thread was
// never supplied to it. A presenter wrote about the fee, Dan answered, they wrote again two days later,
// and Overture held no record that either message existed (measured live 2026-08-16).
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
}
