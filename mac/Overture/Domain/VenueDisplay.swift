import Foundation

// #342 Phase 1: a curated map enriching known venue names with their parent building and city/state,
// so a card can show "Stern Auditorium / Perelman Stage, Carnegie Hall" plus "New York, NY" instead
// of just the hall. Venues not in the map fall through to the hall name alone (today's behavior); the
// data-layer path for the long tail is deferred to #381. This is the single home for the knowledge
// (the display layer), deliberately not duplicated into the scout engine.
struct VenueDisplay: Equatable {
    let hall: String        // the venue string as given (or "Venue TBD" when missing)
    let parent: String?     // the larger building, e.g. "Carnegie Hall"
    let location: String?   // city/state, e.g. "New York, NY"

    // The hall plus its parent building when known: "Weill Recital Hall, Carnegie Hall".
    var nameLine: String { parent.map { "\(hall), \($0)" } ?? hall }

    static func resolve(_ venue: String?) -> VenueDisplay {
        guard let raw = venue,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return VenueDisplay(hall: "Venue TBD", parent: nil, location: nil)
        }
        let known = map[normalize(raw)]
        return VenueDisplay(hall: raw, parent: known?.parent, location: known?.location)
    }

    // Venue-specific normalization. Deliberately NOT GroupNameMatch.normalize, which is an org/
    // presenter normalizer that truncates a name at " - " / ": " and would merge distinct rooms.
    // Here we only case-fold and collapse runs of whitespace, preserving "/", commas, etc.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
    }

    private struct Entry { let parent: String?; let location: String? }
    private static let carnegie = Entry(parent: "Carnegie Hall", location: "New York, NY")
    private static let manhattan = Entry(parent: nil, location: "New York, NY")

    // Keys are pre-normalized (lowercased, single-spaced). Seeded conservatively with venues whose
    // location is unambiguous; anything uncertain is omitted so it falls through rather than showing
    // a wrong city. Easy to extend.
    private static let map: [String: Entry] = [
        "weill recital hall": carnegie,
        "zankel hall": carnegie,
        "stern auditorium / perelman stage": carnegie,
        "the metropolitan museum of art": manhattan,
        "the joyce theater": manhattan,
        "bryant park": manhattan,
        "madison square park": manhattan,
        "museum of chinese in america": manhattan,
        "wave hill": Entry(parent: nil, location: "Bronx, NY"),
        "brooklyn society for ethical culture": Entry(parent: nil, location: "Brooklyn, NY"),
    ]
}
