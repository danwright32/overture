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
        // The displayed hall preserves Dan's own venue text (case and spacing), address stripped, exactly
        // as before. The map LOOKUP, by contrast, goes through VenueNormalization.fold so a slash-spacing
        // or abbreviation variant still matches a curated key (#1064).
        let hall = VenueNormalization.strippingEmbeddedAddress(raw)
        let fallback = safeCityStateLine(eventLocation)

        if let known = map[lookupKey(hall)] {
            return VenueDisplay(hall: hall, parent: known.parent, location: known.location ?? fallback)
        }
        // #1064: a trailing clause that merely names a known parent building ("..., Carnegie Hall") is not
        // a street address, so strippingEmbeddedAddress keeps it and the full string misses the map. Try
        // the lookup again with that parent clause dropped; on a hit the map itself supplies the parent
        // back, so the card still reads "Stern Auditorium / Perelman Stage, Carnegie Hall" AND regains its
        // "New York, NY" line. Done only when it actually produces a hit, so a non-map venue keeps its full
        // display string untouched (the Abrons/Fabbri parent clauses below still survive).
        if let dropped = droppingTrailingKnownParent(hall), let known = map[lookupKey(dropped)] {
            return VenueDisplay(hall: VenueNormalization.fold(dropped),
                                parent: known.parent, location: known.location ?? fallback)
        }
        return VenueDisplay(hall: hall, parent: nil, location: fallback)
    }

    // The curated map is keyed on the folded, normalized form so a slash-spacing or street-suffix variant
    // of a known venue still resolves.
    private static func lookupKey(_ s: String) -> String {
        normalize(VenueNormalization.fold(s))
    }

    // The set of parent-building names the map knows ("carnegie hall"), pre-normalized. A trailing venue
    // clause matching one of these is dropped before a retry lookup (#1064).
    private static let knownParents: Set<String> = Set(
        map.values.compactMap { $0.parent }.map { normalize($0) }
    )

    private static func droppingTrailingKnownParent(_ s: String) -> String? {
        let clauses = s.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard clauses.count > 1, let last = clauses.last,
              knownParents.contains(normalize(last)) else { return nil }
        return clauses.dropLast().joined(separator: ", ")
    }

    // #1030 follow-up: the runbook explicitly allows `location` to be a full street address ("123 E
    // 24th St, New York, NY 10010"), reported verbatim by design. Falling back to that raw string would
    // reintroduce the exact "shows a raw address" problem Dan asked to eliminate, just moved to the
    // second line. Only use it when it is ALREADY a clean city/state shape: no comma-clause may start
    // with a digit. Anything address-shaped is omitted rather than guessed at, the same conservative
    // rule `map` itself follows ("anything uncertain is omitted so it falls through").
    //
    // LIVE-STORE-CLAIM verified=2026-07-18 measure="distinct non-null `location` field values in the live store, checked against this address-shape heuristic"
    // Measured against the live store's 11 distinct `location` values: rejects every street-address
    // shape found there and passes through every clean one ("Brooklyn", "North Adams, MA"). Re-checked
    // 2026-07-18: the store has grown to 313 prospects since this was written but still holds exactly
    // 11 distinct location values, and the heuristic still rejects every address-shaped one among them.
    //
    // #1065: this is the STRICTER of `location`'s two independent consumers. The other is the geography
    // gate (EventPlace.resolve), which reads the messier shapes this one rejects (a full address, a
    // region name). If you loosen or tighten the shape accepted here, check that consumer too;
    // LocationTwoConsumersGuardTests pins both tolerances against shared inputs and goes red when the
    // two silently diverge.
    private static func safeCityStateLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let looksLikeAnAddress = trimmed.split(separator: ",").contains {
            $0.trimmingCharacters(in: .whitespaces).first?.isNumber == true
        }
        return looksLikeAnAddress ? nil : trimmed
    }

    // The embedded-address stripping (splitting on commas and dropping the first digit-leading clause and
    // everything after it) now lives in VenueNormalization.strippingEmbeddedAddress, shared with the
    // natural-key path (#1064), so display and de-duplication strip an address identically.
    //
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
