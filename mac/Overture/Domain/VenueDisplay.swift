import Foundation

// #342 Phase 1: a curated map enriching known venue names with their parent building and city/state,
// so a card can show "Stern Auditorium / Perelman Stage, Carnegie Hall" plus "New York, NY" instead
// of just the hall. Venues not in the map fall through to the hall name alone (today's behavior); the
// data-layer path for the long tail is deferred to #381. This is the single home for the knowledge
// (the display layer), deliberately not duplicated into the scout engine.
struct VenueDisplay: Equatable {
    let hall: String        // the venue's own name (or "Venue TBD" when missing), address stripped
    let parent: String?     // the larger building, e.g. "Carnegie Hall"
    let location: String?   // city/state, e.g. "New York, NY"

    // The hall plus its parent building when known: "Weill Recital Hall, Carnegie Hall".
    var nameLine: String { parent.map { "\(hall), \($0)" } ?? hall }

    // #1030: Dan's call is city/state only, always, never a raw street address a source page happened
    // to bake into the venue string ("The Players Theatre, 115 MacDougal Street, New York, NY"). The
    // curated map is still the authority for `location` when it has an entry; `eventLocation` (#970's
    // per-event `location` field) only fills the gap for venues the map has never heard of, so most
    // cards get a consistent city/state line instead of an accident of the ~10-entry table.
    static func resolve(_ venue: String?, location eventLocation: String? = nil) -> VenueDisplay {
        guard let raw = venue,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return VenueDisplay(hall: "Venue TBD", parent: nil, location: nil)
        }
        let hall = strippingEmbeddedAddress(raw)
        let known = map[normalize(hall)]
        let location = known?.location ?? safeCityStateLine(eventLocation)
        return VenueDisplay(hall: hall, parent: known?.parent, location: location)
    }

    // #1030 follow-up: the runbook explicitly allows `location` to be a full street address ("123 E
    // 24th St, New York, NY 10010"), reported verbatim by design. Falling back to that raw string would
    // reintroduce the exact "shows a raw address" problem Dan asked to eliminate, just moved to the
    // second line. Only use it when it is ALREADY a clean city/state shape: no comma-clause may start
    // with a digit. Anything address-shaped is omitted rather than guessed at, the same conservative
    // rule `map` itself follows ("anything uncertain is omitted so it falls through").
    //
    // Measured against the live store's 11 distinct `location` values: rejects every street-address
    // shape found there and passes through every clean one ("Brooklyn", "North Adams, MA").
    private static func safeCityStateLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let looksLikeAnAddress = trimmed.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces).first?.isNumber == true
        }
        return looksLikeAnAddress ? nil : trimmed
    }

    // A source page can bake the street address directly into the venue string. The heuristic: split
    // on commas, always keep the first clause (the venue's own name, however it is spelled, even if it
    // itself starts with a digit like "54 Below"), then keep walking clauses only until one starts with
    // a digit, which every real street-address clause in the live store does ("115 MacDougal Street",
    // "1140 Park Avenue", "7 East 95th Street"...). Everything from that clause onward (the street, and
    // any city/state/zip after it) is dropped. A clause with no leading digit ("Carnegie Hall",
    // "Abrons Arts Center", "Fabbri Mansion") is a real parent-venue name and is kept.
    //
    // Measured against the live store's 66 distinct venue strings: correctly strips every comma-address
    // shape and leaves every parent-venue clause untouched.
    private static func strippingEmbeddedAddress(_ raw: String) -> String {
        let clauses = raw.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard clauses.count > 1 else { return raw }

        var kept = [clauses[0]]
        for clause in clauses.dropFirst() {
            guard let first = clause.first, !first.isNumber else { break }
            kept.append(clause)
        }
        return kept.joined(separator: ", ")
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
