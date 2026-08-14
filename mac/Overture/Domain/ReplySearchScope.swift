import Foundation

// #2713: WHICH pitches the mailbox search reads for, and HOW FAR BACK this tick has to read.
//
// Both are decisions rather than network, so they live here and are driven with no Gmail at all
// (L2). `GmailReplySearch` asks these two questions and then does nothing but fetch.
//
// The shape of the search follows from the cost. There is no usable `from:` filter, because the
// domain a form lives on is not a match key for the address the presenter answers from (measured
// live 2026-08-14: a form on caseengaines.com, a reply from a gmail.com address). So the query
// degenerates to everything inbound since the pitch, `users.messages.list` returns only ids, and
// every candidate needs its own `users.messages.get` to see who sent it. One search per CONTACT
// would be roughly 1,200 gets per contact per tick against a normal inbox, every thirty minutes.
//
// One search per TICK instead: take the oldest window any contact in scope needs, read it once, and
// score every contact against the same message set.
enum ReplySearchScope {

    // How long after a pitch Overture keeps reading for an answer to it.
    //
    // The explicit stop the plan asks for, and it is load-bearing rather than tidy. Every other Gmail
    // path on this tick is self-limiting already (`threadsToCheck` is bounded by the open
    // conversations, the threading repair empties itself after one effective pass), and this one must
    // be too, because a sent pitch never ages off until Dan closes it out by hand. Without a horizon
    // the window would widen by a day every day, for ever, and the tick would pay for the whole of it.
    //
    // Thirty days rather than a guess dressed up as a rule: it is the same order as the follow-up
    // cadence, and a presenter who has not written within a month of a cold pitch is not going to be
    // found by reading more mail. A contact past it is not closed and nothing about it changes; it is
    // only no longer read for, and the manual route (#2718) still reaches it.
    static let horizonDays = 30

    static var horizon: TimeInterval { Double(horizonDays) * 86_400 }

    // Every contact whose reply this tick is reading for.
    //
    // Dan's scope, stated in the plan: contacts with NO stored conversation. A show that WAS emailed
    // is deliberately out, because that contact already holds a conversation and the field holds one.
    static func targets(in prospects: [Prospect], now: Date) -> [Recipient] {
        prospects.flatMap { p -> [Recipient] in
            // A show Dan hand-resolved or booked is closed; stop reading for all of its contacts, the
            // same two guards `GmailReplyChecker.threadsToCheck` applies at this level.
            guard !p.replyWatchManualOutcome, !p.replyWatchIsBooked else { return [] }
            return p.recipients.filter { inScope($0, now: now) }
        }
    }

    static func inScope(_ r: Recipient, now: Date) -> Bool {
        // A pitch that actually went out. `formOutreachStartedAt` alone is Dan having opened the form
        // and not yet said whether he sent it, and reading the mailbox for an answer to something that
        // may never have been asked would propose a stranger's mail against a pitch that never happened.
        guard let pitchedAt = r.formOutreachRecordedAt else { return false }
        // The whole point: there is nothing here for the reply watcher to fetch.
        guard !r.hasWatchableConversation else { return false }
        // Deliberately the same bound the reply watcher uses (`replyWatchConversationIsOpen`), so a
        // conversation that could still put itself in front of Dan is exactly the one still being read
        // for, and the two cannot disagree about which those are.
        guard r.replyWatchConversationIsOpen, !r.replyWatchManualOutcome, !r.replyWatchIsBooked else {
            return false
        }
        return now.timeIntervalSince(pitchedAt) < horizon
    }

    // The oldest instant this tick has to read from, or nil when there is nothing to read for.
    //
    // The high-water mark says how far the MAILBOX has been read, which is only an answer for a
    // contact that was in scope when it was read. A pitch recorded since then has never been read for
    // at all, so it needs its own window back to the pitch: giving it only the new mail would
    // permanently skip the reply that arrived before it joined the scope. That is the whole reason
    // `Recipient.replyCandidateSearchedAt` exists as a separate fact from the shared mark, and reading
    // it is what this function does with it.
    static func windowStart(for targets: [Recipient], searchedThrough: Date?, now: Date) -> Date? {
        targets.compactMap { r -> Date? in
            guard let pitchedAt = r.formOutreachRecordedAt else { return nil }
            guard r.replyCandidateSearchedAt != nil, let mark = searchedThrough else { return pitchedAt }
            // Never earlier than the pitch: a contact added after the mark was set would otherwise drag
            // the window back over mail that cannot be an answer to it.
            return max(mark, pitchedAt)
        }.min()
    }
}
