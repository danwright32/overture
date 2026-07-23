import Foundation

// #891: what the Sources sheet says about the shows Overture could not read on a source.
//
// The extract run WebFetches each event's own detail page for the venue. An event whose page it never
// reached comes back with no venue and is DROPPED, because a venue-less prospect would name the wrong
// place in Dan's email. The app has always known this was happening. The count went nowhere but the lead
// sheet, so a venue quietly returning half its shows unreadable looked exactly like a healthy one, which
// is the single thing the watchlist design says must never happen.
//
// It matters more since #887, which now reads that count: a source past the tolerance silently forfeits
// the right to mark anything cancelled. That is the safe behaviour, and a capability switching itself off
// with no symptom is #888's "rule that silently never fires". So it is said out loud.
//
// A pure function, never a computation inside the SwiftUI body: a rule computed in a view is a rule no
// test can reach, and two of those have already drifted here under a green suite (#863, #885).
enum SourceReadability {

    // The line for Dan, or nothing at all when the last run read everything and came back its usual size.
    // Silence has to mean healthy, or the line is noise he learns to skim, and this is the one line he must
    // never skim past.
    //
    // Two different things can switch a source's cancelling off, so both are said, and only ever one at a
    // time: whichever is actually doing it. Ordered by cause, not severity. Events thrown away are missing
    // from the feed count as well, so heavy unread pages ALSO shrink the feed; naming the shrink in that
    // case would describe a symptom and hide the thing Dan can act on.
    // #1032: `titleRejected` is how many of the `unreadable` drops were rows with no NAME rather than no
    // venue. It defaults to 0, the near-universal case, which keeps every existing caller and its copy
    // byte-for-byte unchanged. The "no venue on their own detail page" sentence is true only of the venue
    // family (a detail page that was never read), so a titleless drop is never folded into it; a run that
    // dropped both is told both, in whole sentences per case rather than assembled fragments.
    static func note(readable: Int, unreadable: Int, titleRejected: Int = 0, baseline: Int) -> String? {
        let total = readable + unreadable
        let venueRejected = max(0, unreadable - titleRejected)

        // #887: too much of what this run looked at came back unread. It cannot know what else it missed.
        // Saying only a bare count would hide the consequence, and the consequence is the part Dan can
        // actually act on: this source can no longer tell him a show has been cancelled, and it will not be
        // able to until it can read its own pages again.
        if FeedReconcile.unreadPagesForfeitAbsence(readable: readable, unreadable: unreadable) {
            return forfeitLine(total: total, venueRejected: venueRejected, titleRejected: titleRejected)
        }

        // #897: the run read what it found, but found far less than this source normally lists. A half
        // loaded page looks exactly like a calendar that emptied out, so Overture believes neither until the
        // smaller size holds (FeedReconcile.updatedHealth re-baselines after selfHealThreshold reads, and
        // this line clears itself the moment it does).
        //
        // Drawn from the SAME rule the reconcile just used, never a second copy of it, so the sheet can
        // never tell Dan cancellation is working on a source where it is switched off. An empty feed is
        // deliberately not this case: that is a broken fetch or a quiet off-season, which the source's own
        // health and run note already speak for.
        if FeedReconcile.shrunkenFeedForfeitsAbsence(readable: readable, baseline: baseline) {
            return "\(readable) shows listed, down from the usual \(baseline), "
                + "so Overture won't mark anything from this source as gone until the smaller calendar holds."
        }

        // Inside the tolerance: worth stating, but it has cost the source nothing, and the copy must not
        // imply that it has. A "venue TBA" listing is a normal, permanent feature of a real calendar.
        guard unreadable > 0 else { return nil }
        return toleranceLine(total: total, venueRejected: venueRejected, titleRejected: titleRejected)
    }

    // #1428: true when the note above is the SELF-HEALING shrunken-feed hold (the feed came back smaller but
    // every show it found read cleanly), rather than an actionable forfeit. That hold needs no input and
    // clears itself, so the Sources sheet renders its line in plain text, not the amber an actionable
    // problem gets. Mirrors `note`'s precedence exactly (a pages-unreadable forfeit wins over the shrink), so
    // this flag can never disagree with the sentence it colors. It is also why the attention badge no longer
    // counts this state (SourceAttention.needsALook).
    static func noteIsSelfHealingHold(readable: Int, unreadable: Int, baseline: Int) -> Bool {
        !FeedReconcile.unreadPagesForfeitAbsence(readable: readable, unreadable: unreadable)
            && FeedReconcile.shrunkenFeedForfeitsAbsence(readable: readable, baseline: baseline)
    }

    // Past the tolerance, the source has forfeited its right to mark anything gone. Complete sentences per
    // case (#1032, and the standing rule against assembled fragments): the common venue-only case keeps its
    // original wording; the mixed and title-only cases name what was actually dropped.
    private static func forfeitLine(total: Int, venueRejected: Int, titleRejected: Int) -> String {
        switch (venueRejected > 0, titleRejected > 0) {
        case (_, false):
            return "\(venueRejected) of \(total) shows had no venue on their own detail page, so Overture won't mark anything from this source as gone until it can confirm one."
        case (true, true):
            return "\(venueRejected) of \(total) shows had no venue on their own detail page and \(titleRejected) had no title, so Overture won't mark anything from this source as gone until it can read its pages again."
        case (false, true):
            return "\(titleRejected) of \(total) shows had no title, so Overture won't mark anything from this source as gone until it can read its pages again."
        }
    }

    // Inside the tolerance, worth stating but with no cancellation consequence. Same three cases.
    private static func toleranceLine(total: Int, venueRejected: Int, titleRejected: Int) -> String {
        switch (venueRejected > 0, titleRejected > 0) {
        case (_, false):
            return "\(venueRejected) of \(total) shows had no venue on their own detail page."
        case (true, true):
            return "\(venueRejected) of \(total) shows had no venue on their own detail page and \(titleRejected) had no title."
        case (false, true):
            return "\(titleRejected) of \(total) shows had no title."
        }
    }
}
