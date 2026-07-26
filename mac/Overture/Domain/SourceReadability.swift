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
    // #1471: `droppedShowLabels` are the first few dropped rows, already labelled (`showLabel`), so the line
    // can say WHICH shows rather than only how many. Capped by the caller at `namedShowCap`; the rest are
    // counted from the drop totals here, so the remainder can never disagree with the count in the sentence
    // it follows. Empty (an older row that recorded no labels, or rows with nothing to name them by) simply
    // adds no sentence.
    static func note(readable: Int, unreadable: Int, titleRejected: Int = 0,
                     structuralGaps: Int = 0, droppedShowLabels: [String] = [],
                     baseline: Int) -> String? {
        let total = readable + unreadable + structuralGaps
        let venueRejected = max(0, unreadable - titleRejected)
        let named = namedShowsLine(labels: droppedShowLabels, droppedTotal: unreadable + structuralGaps)

        let leadingLine: String?
        switch leading(readable: readable, unreadable: unreadable, baseline: baseline) {
        case .unreadPagesForfeit:
            leadingLine = forfeitLine(total: total, venueRejected: venueRejected, titleRejected: titleRejected)
        case .shrunkenFeedHold:
            leadingLine = "\(readable) shows listed, down from the usual \(baseline), "
                        + "so Overture won't mark anything from this source as gone until the smaller calendar holds."
        case .withinTolerance:
            leadingLine = toleranceLine(total: total, venueRejected: venueRejected, titleRejected: titleRejected)
        case .nothingToSay:
            leadingLine = nil
        }

        return sentences(leadingLine, structuralGapLine(total: total, structuralGaps: structuralGaps), named)
    }

    // #1498: WHICH leading line this run earns, decided once. Both the sentence Dan reads and whether it is
    // drawn in gold are read off this value, so the colour is a property of the kind rather than a second
    // rule kept mirroring the first by hand. Every comment in this file used to say the two "mirror `note`'s
    // precedence exactly", which is a promise a person has to keep on every future edit; now a new kind
    // cannot be added to the sentence and forgotten in the colour, because there is only one place to add it.
    //
    // Ordered by cause, not severity, and only ever one at a time: whichever is actually doing it. Events
    // thrown away are missing from the feed count as well, so heavy unread pages ALSO shrink the feed; naming
    // the shrink in that case would describe a symptom and hide the thing Dan can act on.
    enum Leading {
        // #887: too much of what this run looked at came back unread. It cannot know what else it missed.
        // Saying only a bare count would hide the consequence, and the consequence is the part Dan can
        // actually act on: this source can no longer tell him a show has been cancelled, and it will not be
        // able to until it can read its own pages again. The ONE kind that is his to do something about.
        case unreadPagesForfeit

        // #897: the run read what it found, but found far less than this source normally lists. A half
        // loaded page looks exactly like a calendar that emptied out, so Overture believes neither until the
        // smaller size holds (FeedReconcile.updatedHealth re-baselines after selfHealThreshold reads, and
        // this line clears itself the moment it does). An empty feed is deliberately not this case: that is a
        // broken fetch or a quiet off-season, which the source's own health and run note already speak for.
        case shrunkenFeedHold

        // Inside the tolerance: worth stating, but it has cost the source nothing, and the copy must not
        // imply that it has. A "venue TBA" listing is a normal, permanent feature of a real calendar.
        case withinTolerance

        // Nothing about readability itself. A structural-gap line or a named-shows line may still speak.
        case nothingToSay

        // #1498: gold, or plain. Dan reported a source painted gold over a festival that had not announced a
        // venue yet: nothing was forfeited, nothing was broken, and there was no action of his that would
        // change it. Gold on a line he cannot act on is what teaches him to skim, and this is the one line in
        // the sheet he must never skim past. So only the forfeit is his.
        //
        // This reverses a decision #1472 wrote down deliberately, that a tolerated unread page is "still a
        // page Overture failed to open, which is Dan's to look at". Two things about that reasoning did not
        // survive contact: the page in question had been read (the venue simply was not published), and even
        // where it truly was not, the source stays inside its tolerance and keeps cancelling, so there is no
        // consequence to act on. The count is still disclosed in words; it is the alarm that was wrong.
        var isDansToAct: Bool { self == .unreadPagesForfeit }
    }

    static func leading(readable: Int, unreadable: Int, baseline: Int) -> Leading {
        // Drawn from the SAME rules the reconcile just used, never a second copy of them, so the sheet can
        // never tell Dan cancellation is working on a source where it is switched off.
        if FeedReconcile.unreadPagesForfeitAbsence(readable: readable, unreadable: unreadable) {
            return .unreadPagesForfeit
        }
        if FeedReconcile.shrunkenFeedForfeitsAbsence(readable: readable, baseline: baseline) {
            return .shrunkenFeedHold
        }
        return unreadable > 0 ? .withinTolerance : .nothingToSay
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

    // #1471: how many dropped shows the line will NAME before it starts counting them instead. Two, so the
    // common case (one placeholder, or a pair) is answered outright and a badly broken source cannot unroll a
    // list into the sheet. It is also what the recorder stores per source, so nothing keeps a longer list
    // around than the sentence can use.
    static let namedShowCap = 2

    // #1471: one dropped show, as Dan reads it. The single authority on how a show is named in this sheet, so
    // the sentence below and anything that stores a label agree by construction.
    //
    // Degrades rather than guesses. An unparseable date is dropped entirely (`EasternDate.dayLabel` returns
    // nil rather than a plausible-looking wrong day), a row with no name is called by its night, and a row
    // with neither is not named at all: the count sentence still reports it, so nothing is hidden, and there
    // is no empty quote or dangling "on" anywhere in the copy.
    static func showLabel(name: String?, date: String?) -> String? {
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let day = date.flatMap(EasternDate.dayLabel)
        switch (trimmed.isEmpty, day) {
        case (false, let day?):  return "\(trimmed) on \(day)"
        case (false, nil):       return trimmed
        case (true, let day?):   return "the \(day) listing"
        case (true, nil):        return nil
        }
    }

    // #1471: which shows those were. A sentence of its own after the count, never folded into it: the count
    // and its consequence are the thing Dan must not skim, and a clause spliced into that sentence would make
    // the part he acts on longer and harder to read.
    //
    // The remainder is DERIVED from the drop total rather than stored alongside the labels, so "and 10 others"
    // can never disagree with the "12 of 80" in the sentence it follows.
    private static func namedShowsLine(labels: [String], droppedTotal: Int) -> String? {
        let named = Array(labels.prefix(namedShowCap))
        guard !named.isEmpty else { return nil }
        let others = max(0, droppedTotal - named.count)
        guard others > 0 else {
            return named.count == 1 ? "That was \(named[0])." : "Those were \(named[0]) and \(named[1])."
        }
        let plural = others == 1 ? "other" : "others"
        return "They include \(named.joined(separator: " and ")), and \(others) \(plural)."
    }

    // Whole sentences, joined, never assembled fragments (the standing rule, and #1032's reason for stating
    // each case in full). Nothing to say returns nil, so the row draws no line at all.
    private static func sentences(_ parts: String?...) -> String? {
        let said = parts.compactMap { $0 }
        return said.isEmpty ? nil : said.joined(separator: " ")
    }

    // #1428/#1498: true when the note above needs nothing FROM DAN. The Sources sheet renders those lines in
    // plain text, not the gold an actionable problem gets. Read straight off the kind, so this can never
    // disagree with the sentence it colours.
    //
    // #1498 took `structuralGaps` out of the signature rather than leaving it unread: the answer no longer
    // depends on it, and a parameter a function ignores is a lie about what decides the outcome.
    //
    // The attention badge is a SEPARATE question and deliberately not this one. SourceAttention.needsALook
    // asks FeedReconcile directly for the unread-pages forfeit, so a tolerated note has never counted toward
    // it; measured on the live store the day #1498 was filed, the three sources in the badge were all real
    // forfeits and the tolerated one (Jalopy, 1 of 28) was not among them.
    static func noteIsInformationalOnly(readable: Int, unreadable: Int, baseline: Int) -> Bool {
        !leading(readable: readable, unreadable: unreadable, baseline: baseline).isDansToAct
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
