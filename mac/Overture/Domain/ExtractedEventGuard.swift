import Foundation

// #799: what an extracted event must carry before it is allowed to become a prospect.
//
// This exists because of what the first real run of the extract path found. Bargemusic's listings page
// names no venue at all: every concert carries a NUMERIC venue id. The run returned the right answer
// ("Brooklyn Bridge Park Boathouse at Pier 5") only because it followed each event's own detail page,
// exactly as the runbook asks. But a runbook is a request, not a guarantee. If a future run skips that
// step, or a site's detail links break, the events still come back looking perfectly well-formed, with
// a venue of "3" or of nothing at all.
//
// That is not cosmetic. The venue drives the classifier AND the pitch itself: Dan's email says "your
// March 10 concert at Carnegie Hall". A prospect with no venue, or with a venue of "3", produces an
// email that names the wrong place, and NOTHING downstream can catch it, because nothing downstream
// knows what the venue was supposed to be. (It is also half the natural key, so a venue-less event
// keys badly and re-keys unpredictably.)
//
// So a venue-less event never becomes a prospect silently. It is rejected WITH A REASON, and the
// reasons are reportable against the source that produced them, which is the actionable fact: "this
// source returned 6 shows and not one of them has a venue" says its detail pages are not being read.
// Six quietly venue-less prospects would just poison the queue.
enum ExtractedEventGuard {
    enum Rejection: String, Equatable, Sendable {
        case noTitle
        case noVenue            // absent or blank
        case placeholderVenue   // present, but not a venue: a numeric id, "unknown", "TBD"
        case locationAsVenue    // present, but only restates the location: a city is not a room

        var label: String {
            switch self {
            case .noTitle:          return "no title"
            case .noVenue:          return "no venue"
            case .placeholderVenue: return "no real venue (the listing carries a placeholder)"
            case .locationAsVenue:  return "no venue (the listing gave only a place)"
            }
        }
    }

    // Things a model says when it could not find the venue. Accepting any of them as a venue would put
    // it in an email.
    private static let nonAnswers: Set<String> = [
        "unknown", "n/a", "na", "null", "nil", "none", "tbd", "tba", "tbc", "-", "--", "?"
    ]

    static func rejection(for event: ExtractedEvent) -> Rejection? {
        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return .noTitle }

        let venue = (event.venue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !venue.isEmpty else { return .noVenue }

        // The Bargemusic shape: the listings page's venue field is a numeric id ("3"), which is not a
        // venue and reads as one.
        if venue.allSatisfy({ $0.isNumber }) { return .placeholderVenue }
        if nonAnswers.contains(venue.lowercased()) { return .placeholderVenue }
        if restatesLocation(venue: venue, location: event.location) { return .locationAsVenue }
        return nil
    }

    // #995: a venue that only says what the location already said is not a venue, it is the location
    // wearing a venue's clothes. This is the one shape of "no venue published" the guard can actually
    // SEE, because it never gets to look at the page.
    //
    // The comparison is deliberately narrow: equality, or the venue matching one whole comma-separated
    // piece of the location ("Baltimore" against "Baltimore, Maryland"). It is NOT a substring test in
    // the other direction, and that asymmetry is the whole point. A real venue routinely contains its
    // own city ("Brooklyn Bridge Park Boathouse at Pier 5, Brooklyn, NY" against "Brooklyn, NY"), so a
    // loose "one contains the other" rule would reject the exact answer the runbook holds up as correct.
    //
    // Measured against the live store before it was written: fires on 4 of 4 fabricated rows, and cannot
    // fire on the other 128, which carry no location at all. A tempting alternative ("the venue has a
    // comma") was rejected on the same data: it would eat Bargemusic's real answer.
    private static func restatesLocation(venue: String, location: String?) -> Bool {
        let venueKey = normalized(venue)
        guard !venueKey.isEmpty,
              let location, case let locationKey = normalized(location), !locationKey.isEmpty
        else { return false }

        if venueKey == locationKey { return true }
        return locationKey.split(separator: ",")
            .map { normalized(String($0)) }
            .contains(venueKey)
    }

    private static func normalized(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isUsable(_ event: ExtractedEvent) -> Bool { rejection(for: event) == nil }
}

// One rejected event, kept so it can be reported against its source rather than vanishing.
struct RejectedEvent: Equatable, Sendable {
    var title: String
    var reason: ExtractedEventGuard.Rejection
}
