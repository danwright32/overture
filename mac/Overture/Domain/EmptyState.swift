import Foundation

// #885: the empty states, out of two view bodies.
//
// "There is no data at all" and "your filter is hiding it" are different problems with different fixes,
// and telling them apart is the ENTIRE job of this copy. Get it wrong and Dan runs the scout again on a
// queue that is merely filtered, or hunts for a filter on a queue that is genuinely empty. It was decided
// by a pair of ternaries in each of two views, with no test able to see either.
enum EmptyState {
    struct Message: Equatable, Sendable {
        var title: String
        var detail: String
    }

    static func queue(hasAnyItems: Bool) -> Message {
        hasAnyItems
            ? Message(title: "Nothing matches this filter",
                      detail: "Try a different discipline, or clear the high-fit filter.")
            : Message(title: "Nothing scouted yet",
                      detail: "Run the scout to comb the venue calendars. Ranked candidates land here for review.")
    }

    // #843: the Archive's "empty" title used to be word for word the Queue's ("Nothing scouted yet"),
    // which is wrong here: nothing is ever scouted INTO an archive, so "not scouted yet" is not why it is
    // empty. Its own title now says what is actually true, and the detail below carries the rest.
    // #2878: the Follow-ups sheet's one empty sentence. It names EVERY subject that sheet holds, not two
    // of the three: it said only what happens to a show Dan emailed, so the one state that sent him here
    // with nothing to see (a reply draft that stalled) was answered by a sentence about something else
    // entirely (L11). Composed HERE rather than in the view body, where no test could read it (#885), and
    // composed FROM the stalled section's own copy so the sheet's empty state and the section it stands in
    // for cannot drift into describing different things.
    // Joined from whole-sentence literals rather than `+`-concatenated fragments, because the copy
    // inventory lists each string literal as its own entry and a sentence chopped mid-clause cannot be
    // cold read (#843's whole point).
    static let followUpsSheet = [
        "Nothing to act on. Shows you've emailed appear here for a gentle follow-up, and again once the date has passed so you can close them out; they drop off the moment you record how one ended.",
        StalledReplyDraftCopy.nothingStalled,
    ].joined(separator: " ")

    static func archive(hasAnyItems: Bool) -> Message {
        hasAnyItems
            ? Message(title: "Nothing matches this filter",
                      detail: "Try a different status filter, or clear the search.")
            : Message(title: "Nothing tracked yet",
                      detail: "Shows land here once Overture has tracked at least one.")
    }
}
