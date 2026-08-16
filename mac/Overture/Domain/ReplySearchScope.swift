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
// #2712: what this pass reads the mailbox FOR, whichever kind of thing it is.
//
// A form pitch and a hire inquiry are in the same position: something Overture cannot watch, because it
// never sent the email that would have given it a thread. They differ only in the two facts below, so
// widening the scope over one seam is what stops a second mailbox pass being built beside this one (L30).
//
// It refines `ReplyWatchableRecipient` rather than restating its three guards, so what counts as a live
// conversation is answered once for the watcher and the search alike.
protocol ReplySearchSubject: ReplyWatchableRecipient {
    // The instant a reply to this could first exist, and therefore the oldest mail worth reading for it:
    // for a form pitch the moment it was sent, for an inquiry the moment Dan logged it.
    //
    // Nil means there is nothing to read for at all, which is deliberately different from reading and
    // finding nothing (L98). A pitch Dan opened and never confirmed sending, and an inquiry carrying no
    // address to match on, are both nil for that reason.
    var replySearchAnchor: Date? { get }
    // Whether there is already a conversation here, which is the whole point: this pass exists for the
    // things the reply watcher has nothing to fetch for.
    var replySearchHasConversation: Bool { get }
    // When this subject was last read for. Its own fact, separate from the shared high-water mark, so a
    // subject that has never been read for widens the window back to its own anchor.
    var replyCandidateSearchedAt: Date? { get set }
}

extension Recipient: ReplySearchSubject {
    var replySearchAnchor: Date? { formOutreachRecordedAt }
    var replySearchHasConversation: Bool { hasWatchableConversation }
}

extension Inquiry: ReplySearchSubject {
    // #2712: when Dan logged it. An inquiry has no send of Overture's to date from, and its conversation
    // can only be one that already existed in his mailbox, so the moment he recorded it is the earliest
    // instant a message could be about it.
    //
    // Nil with no address, because the address IS the match key here: without one there is nothing this
    // pass could ever do for the row, and saying so in the scope keeps "nothing to read for" apart from
    // "read and found nothing" (L98).
    var replySearchAnchor: Date? {
        guard let email = inquirerEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              !email.isEmpty else { return nil }
        return createdAt
    }
    var replySearchHasConversation: Bool { hasWatchableConversation }
}

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
    // #2712: inquiries ride the same read. They default to none so every existing caller is unchanged,
    // and because a container predating Inquiry legitimately has none to give.
    static func targets(in prospects: [Prospect], inquiries: [Inquiry] = [],
                        now: Date) -> [any ReplySearchSubject] {
        let contacts: [any ReplySearchSubject] = prospects.flatMap { p -> [Recipient] in
            // A show Dan hand-resolved or booked is closed; stop reading for all of its contacts, the
            // same two guards `GmailReplyChecker.threadsToCheck` applies at this level.
            guard !p.replyWatchManualOutcome, !p.replyWatchIsBooked else { return [] }
            return p.recipients.filter { inScope($0, now: now) }
        }
        // An inquiry is its own lead as well as its own thread, so the lead-level guards above are the
        // same two `inScope` already applies to it. There is no second level to check.
        return contacts + inquiries.filter { inScope($0, now: now) }
    }

    static func inScope(_ r: any ReplySearchSubject, now: Date) -> Bool {
        // Something that can actually be answered. For a form pitch that is a pitch that went out:
        // `formOutreachStartedAt` alone is Dan having opened the form and not yet said whether he sent
        // it, and reading the mailbox for an answer to something that may never have been asked would
        // propose a stranger's mail against a pitch that never happened. For an inquiry it is one
        // carrying the address the match is made on.
        guard let pitchedAt = r.replySearchAnchor else { return false }
        // The whole point: there is nothing here for the reply watcher to fetch.
        guard !r.replySearchHasConversation else { return false }
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
    static func windowStart(for targets: [any ReplySearchSubject], searchedThrough: Date?,
                            now: Date) -> Date? {
        targets.compactMap { r -> Date? in
            guard let pitchedAt = r.replySearchAnchor else { return nil }
            guard r.replyCandidateSearchedAt != nil, let mark = searchedThrough else { return pitchedAt }
            // Never earlier than the pitch: a contact added after the mark was set would otherwise drag
            // the window back over mail that cannot be an answer to it.
            return max(mark, pitchedAt)
        }.min()
    }
}
