import Foundation

// #2118: the ONE rule for "when does this next need Dan", shared by both kinds of row in the reached-out
// queue: a scouted show's contact (ReachedOutQueue.nextReachOut) and a direct hire inquiry
// (Inquiry.nextReachOutDate).
//
// The two used to answer that question separately, and they had already drifted: a reply on a show was
// dated when the person WROTE it (#2111, #2113), while the same reply on an inquiry was dated when
// Overture happened to notice it, and a reply stamped ahead of the clock left the inquiry's card sitting
// under a heading in the future. Both halves land under the SAME date headings in one list (#1513), so a
// rule that reaches only one of them produces two cards that look alike and sort differently, and nothing
// flags the divergence.
//
// This shares the RULE, not the entities. An inquiry stays a fully separate entity from a prospect, never
// linked or merged, and it still bypasses the queue's lead-time date window; each side supplies its own
// pacing (a follow-up nudge, a form decision clock, a conversation reminder track) as an input.
enum NextReachOut {
    // One thing that can put this record in front of Dan. Each side says which KIND each of its inputs
    // is, because the two are dated by different evidence and getting that wrong is the whole defect
    // above.
    enum Track: Equatable, Sendable {
        // Work ALREADY sitting on Dan (a reply nobody has dealt with). Dated by the instant it arrived,
        // never by the clock, so a missed one reads as overdue instead of re-filing itself under today
        // (L74). `since` is nil only for a row written before its arrival timestamp was captured.
        case waiting(since: Date?)
        // Work that comes due at a moment already decided (a nudge gap, the night of the show, a
        // conversation interval). Taken exactly as the track gives it.
        case scheduled(Date?)
    }

    // The soonest moment this record next needs Dan, or nil when it needs him no longer.
    //
    // `tracks` is a closure rather than an array so a record that is out of play never pays for building
    // dates nobody will read: an argument list is evaluated in full before the call, so a guard on the
    // first line of the function cannot make the call cheap (L62).
    static func date(isInPlay: Bool, now: Date, tracks: () -> [Track]) -> Date? {
        guard isInPlay else { return nil }
        return tracks().compactMap { track -> Date? in
            switch track {
            case .waiting(let since): return arrived(since, now: now)
            case .scheduled(let at): return at
            }
        }.min()
    }

    // The date work that has already arrived belongs to (#2111/#2116).
    //
    // Clamped to `now` because an arrival is evidence, not a schedule: a reply stamped in the future
    // (clock skew) must not push a due item OUT of the due list until the clock catches up. Nothing here
    // decides whether an item is due, only which day it belongs to, and every anchor is at or before now,
    // so everything due before is still due.
    //
    // A record with no recorded instant keeps the old reading rather than dropping out of the list.
    static func arrived(_ arrivedAt: Date?, now: Date) -> Date {
        min(arrivedAt ?? now, now)
    }
}
