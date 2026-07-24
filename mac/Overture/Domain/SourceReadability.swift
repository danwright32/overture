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
    // #1472: `structuralGaps` are rows the SOURCE published with no venue (OPERA America's blank field), as
    // opposed to `unreadable` rows whose own page Overture could not open. They cost the source nothing, so
    // they never reach the two forfeit rules above; they are still disclosed, because a run that quietly
    // imported 58 of 92 listings and said nothing is the thing #891 exists to prevent. They also count toward
    // the `total` those sentences quote, since they are part of what the run looked at.
    static func note(readable: Int, unreadable: Int, titleRejected: Int = 0,
                     structuralGaps: Int = 0, baseline: Int) -> String? {
        let total = readable + unreadable + structuralGaps
        let venueRejected = max(0, unreadable - titleRejected)

        // #887: too much of what this run looked at came back unread. It cannot know what else it missed.
        // Saying only a bare count would hide the consequence, and the consequence is the part Dan can
        // actually act on: this source can no longer tell him a show has been cancelled, and it will not be
        // able to until it can read its own pages again.
        if FeedReconcile.unreadPagesForfeitAbsence(readable: readable, unreadable: unreadable) {
            return sentences(forfeitLine(total: total, venueRejected: venueRejected, titleRejected: titleRejected),
                             structuralGapLine(total: total, structuralGaps: structuralGaps))
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
            return sentences("\(readable) shows listed, down from the usual \(baseline), "
                             + "so Overture won't mark anything from this source as gone until the smaller calendar holds.",
                             structuralGapLine(total: total, structuralGaps: structuralGaps))
        }

        // Inside the tolerance: worth stating, but it has cost the source nothing, and the copy must not
        // imply that it has. A "venue TBA" listing is a normal, permanent feature of a real calendar.
        return sentences(unreadable > 0
                         ? toleranceLine(total: total, venueRejected: venueRejected, titleRejected: titleRejected)
                         : nil,
                         structuralGapLine(total: total, structuralGaps: structuralGaps))
    }

    // #1472: the rows this source published with no venue at all. A whole sentence of its own, appended to
    // whichever line above applies rather than folded into it, because it is a different fact with a different
    // consequence: those shows are not in the queue, and nothing about the source is broken. Silence when
    // there are none, so the line can never become wallpaper.
    //
    // #1469: ONE sentence for both paths, deliberately, and that is why it does not say "in the feed" as it
    // did when only feeds could reach it. A structured feed's blank field and an artist page's "Info coming
    // soon" row are the same fact to Dan (this listing named no venue, so it is not in your queue), and two
    // near-identical sentences are exactly the duplicate copy #843 was filed about.
    // Singular matters here rather than being fussiness: #1469's live case is exactly one row (Smoke Ring's
    // single "Info coming soon" placeholder), so "left those out" would be the sentence Dan actually reads.
    private static func structuralGapLine(total: Int, structuralGaps: Int) -> String? {
        guard structuralGaps > 0 else { return nil }
        let left = structuralGaps == 1 ? "it" : "those"
        return "\(structuralGaps) of \(total) listings named no venue, so Overture left \(left) out of the queue."
    }

    // Whole sentences, joined, never assembled fragments (the standing rule, and #1032's reason for stating
    // each case in full). Nothing to say returns nil, so the row draws no line at all.
    private static func sentences(_ parts: String?...) -> String? {
        let said = parts.compactMap { $0 }
        return said.isEmpty ? nil : said.joined(separator: " ")
    }

    // #1428: true when the note above needs nothing FROM DAN, rather than reporting an actionable forfeit.
    // The Sources sheet renders those lines in plain text, not the gold an actionable problem gets, and the
    // attention badge does not count them (SourceAttention.needsALook). Mirrors `note`'s precedence exactly,
    // so this flag can never disagree with the sentence it colors.
    //
    // Two states qualify. The shrunken-feed hold (#1428) is a pause that clears itself after three stable
    // reads. #1472's structural venue gaps are the other, and they are why this is no longer named for
    // self-healing: OPERA America may never fill in the venue on its Glimmerglass rows, so that line may
    // never clear, and it is still not work Dan owes anyone. What both share is that no action of his would
    // change them.
    //
    // A tolerated unread page (inside the 5%) deliberately does NOT qualify: it is still a page Overture
    // failed to open, which is Dan's to look at, and that is unchanged from before #1472.
    static func noteIsInformationalOnly(readable: Int, unreadable: Int,
                                        structuralGaps: Int = 0, baseline: Int) -> Bool {
        guard !FeedReconcile.unreadPagesForfeitAbsence(readable: readable, unreadable: unreadable) else {
            return false
        }
        if FeedReconcile.shrunkenFeedForfeitsAbsence(readable: readable, baseline: baseline) { return true }
        return structuralGaps > 0 && unreadable == 0
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
