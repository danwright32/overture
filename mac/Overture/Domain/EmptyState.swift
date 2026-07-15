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
    static func archive(hasAnyItems: Bool) -> Message {
        hasAnyItems
            ? Message(title: "Nothing matches this filter",
                      detail: "Try a different status filter, or clear the search.")
            : Message(title: "Nothing tracked yet",
                      detail: "Shows land here once Overture has tracked at least one.")
    }
}
