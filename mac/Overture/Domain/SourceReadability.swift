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

    // The line for Dan, or nothing at all when everything was read. Silence has to mean healthy, or the
    // line is noise he learns to skim, and this is the one line he must never skim past.
    static func note(readable: Int, unreadable: Int) -> String? {
        guard unreadable > 0 else { return nil }
        let total = readable + unreadable

        // Inside the tolerance: worth stating, but it has cost the source nothing, and the copy must not
        // imply that it has. A "venue TBA" listing is a normal, permanent feature of a real calendar.
        guard !FeedReconcile.rejectedIsWithinTolerance(readable: readable, unreadable: unreadable) else {
            return "\(unreadable) of \(total) shows couldn't be read."
        }

        // Past it. Saying only "12 shows couldn't be read" would hide the consequence, and the
        // consequence is the part Dan can actually act on: this source can no longer tell him a show has
        // been cancelled, and it will not be able to until it can read its own pages again.
        return "\(unreadable) of \(total) shows couldn't be read, "
            + "so Overture won't mark anything from this source as gone until it can."
    }
}
