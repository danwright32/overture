import Foundation

// #342 Phase 1: reads a curated table of known venue names for their parent building and city/state, so
// a card can show "Stern Auditorium / Perelman Stage, Carnegie Hall" plus "New York, NY" instead of just
// the hall. Venues not in the table fall through to the hall name alone.
//
// #1744: the table itself now lives in VenuePlaces, because it stopped being display-only knowledge.
// This file used to own it and say so ("the single home for the knowledge (the display layer),
// deliberately not duplicated into the scout engine"), which was exactly the problem: the geography gate
// never saw a venue, so 342 untriaged shows sat unplaced while the answer for most of them was sitting
// in this file. One table, two consumers, and this one is still the STRICTER about what it will print.
struct VenueDisplay: Equatable {
    let hall: String        // the venue's own name (or "Venue TBD" when missing), address stripped
    let parent: String?     // the larger building, e.g. "Carnegie Hall"
    let location: String?   // city/state, e.g. "New York, NY"

    // #1744: what the card says in place of a city when nothing could establish one. It states only what
    // was actually measured, which is that the city is not known: WHY is not knowable here (the page may
    // have named no place, or the venue may be a room no table has heard of) and a line claiming either
    // would be claiming more than its check can see (L11).
    static let cityUnknown = "City not known"

    // The hall placeholder, named so `locationLine` can recognise it instead of comparing against a
    // literal spelled out in two places.
    static let venueTBD = "Venue TBD"

    // The card's second line, or nothing. Decided here rather than in the SwiftUI body: a rule computed
    // in a view is a rule no test can reach, and two have already drifted in this area under a green
    // suite (#863, #885). `isUnknown` is what the row styles on, so the absence of a city reads as a
    // stated condition rather than as a city rendered in the same faint grey as a real one.
    var locationLine: (text: String, isUnknown: Bool)? {
        if let location { return (location, false) }
        // A show with no venue EITHER already reads "Venue TBD" on the line above, which says everything
        // "City not known" would say underneath it. Saying it twice is the #843 defect, so the second
        // line appears only where it adds the thing the first line did not: a named room whose city
        // could not be established.
        guard hall != VenueDisplay.venueTBD else { return nil }
        return (VenueDisplay.cityUnknown, true)
    }

    // #1850: the building Dan has a relationship with, then the room inside it in brackets:
    // "Carnegie Hall (Zankel Hall)". Dan's call, 2026-07-30, on wanting both at once: the building is what
    // he pitches and the room is what he needs in order to shoot it, and a card could previously show only
    // one. Falls back to the bare name when no building is known, so nothing gains empty brackets.
    var nameLine: String { parent.map { "\($0) (\(hall))" } ?? hall }

    // #1030: Dan's call is city/state only, always, never a raw street address a source page happened
    // to bake into the venue string ("The Players Theatre, 115 MacDougal Street, New York, NY"). The
    // curated map is still the authority for `location` when it has an entry; `eventLocation` (#970's
    // per-event `location` field) only fills the gap for venues the map has never heard of, so most
    // cards get a consistent city/state line instead of an accident of the ~10-entry table.
    static func resolve(_ venue: String?, location eventLocation: String? = nil) -> VenueDisplay {
        guard let raw = venue,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return VenueDisplay(hall: venueTBD, parent: nil, location: nil)
        }
        // The displayed hall preserves Dan's own venue text (case and spacing), address stripped, exactly
        // as before. The map LOOKUP, by contrast, goes through VenueNormalization.fold so a slash-spacing
        // or abbreviation variant still matches a curated key (#1064).
        let hall = VenueNormalization.strippingEmbeddedAddress(raw)
        let fallback = safeCityStateLine(eventLocation)

        if let known = VenuePlaces.exact(hall) {
            return VenueDisplay(hall: hall, parent: known.parent, location: known.location ?? fallback)
        }
        // #1064: a trailing clause that merely names a known parent building ("..., Carnegie Hall") is not
        // a street address, so strippingEmbeddedAddress keeps it and the full string misses the map. Try
        // the lookup again with that parent clause dropped; on a hit the map itself supplies the parent
        // back, so the card still reads "Stern Auditorium / Perelman Stage, Carnegie Hall" AND regains its
        // "New York, NY" line. Done only when it actually produces a hit, so a non-map venue keeps its full
        // display string untouched (the Abrons/Fabbri parent clauses below still survive).
        if let dropped = droppingTrailingKnownParent(hall), let known = VenuePlaces.exact(dropped) {
            return VenueDisplay(hall: VenueNormalization.fold(dropped),
                                parent: known.parent, location: known.location ?? fallback)
        }
        // #1850: the venue string names both out loud, joined by "at": "Playhouse Theater at Abrons Arts
        // Center". Three live Abrons cards carry this shape and name rooms the table has never heard of
        // on their own. The trailing name must be a venue the table ALREADY KNOWS, so a room is never
        // handed a building on the strength of the string alone: "The Attic at Somewhere Nobody Watches"
        // stays exactly as it is. That keeps the table's standing rule (anything uncertain is omitted so
        // it falls through) applying to the parent as well as to the city, which matters more here,
        // because a confident wrong building sends Dan to the wrong address.
        // #1850: the room is followed by its STREET rather than its building ("Jalopy's Classroom at 319
        // Columbia St"), which is the shape the live store actually holds. The building half proves
        // nothing, so try the ROOM half against the table instead: the entry it finds supplies the parent.
        if let r = hall.range(of: " at ", options: [.backwards, .caseInsensitive]) {
            let room = String(hall[hall.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            if let known = VenuePlaces.exact(room), known.parent != nil {
                return VenueDisplay(hall: room, parent: known.parent,
                                    location: known.location ?? fallback)
            }
        }
        if let split = splittingRoomFromKnownBuilding(hall) {
            return VenueDisplay(hall: split.room, parent: split.building,
                                location: VenuePlaces.exact(split.building)?.location ?? fallback)
        }
        return VenueDisplay(hall: hall, parent: nil, location: fallback)
    }

    // "Room at Building" split on the LAST " at ", so a room whose own name contains the word survives.
    // Returns nothing unless the building half is already in the table.
    private static func splittingRoomFromKnownBuilding(_ s: String) -> (room: String, building: String)? {
        guard let r = s.range(of: " at ", options: [.backwards, .caseInsensitive]) else { return nil }
        let room = String(s[s.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        let building = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !room.isEmpty, !building.isEmpty, VenuePlaces.exact(building) != nil else { return nil }
        return (room, building)
    }

    // The set of parent-building names the table knows ("carnegie hall"), pre-normalized. A trailing venue
    // clause matching one of these is dropped before a retry lookup (#1064).
    private static let knownParents: Set<String> = VenuePlaces.knownParents

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
    // #1762: an address-shaped value is no longer thrown away whole. It used to be, and that cost 131
    // cards their city line while the city sat in the stored value: 122 of them The Green Room 42, whose
    // rows all carry `570 10th Ave, New York, NY 10036`. The #1030 promise is that no street address
    // reaches the card, not that a city inside one is unusable.
    //
    // So this asks "what city and state does this name" rather than "is this already clean", and answers
    // nothing when it cannot be sure.
    private static func safeCityStateLine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let clauses = trimmed.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let looksLikeAnAddress = clauses.contains { $0.first?.isNumber == true }
        // Already clean: passed through verbatim, exactly as before. A bare city with no state at all
        // ("Brooklyn") is precisely what this fallback was built for and must keep working.
        guard looksLikeAnAddress else { return trimmed }
        return cityStateFromAddress(clauses)
    }

    // The city and state named inside an address, or nothing.
    //
    // Scanned from the END for the state, so a city that is itself a state name reads as the city ("New
    // York, NY" is New York in NY, not the reverse), matching how EventPlace reads the same shapes.
    //
    // LIVE-STORE-CLAIM verified=2026-07-29 measure="every distinct address-shaped `location` value in the live store"
    // All six yield the right city and none leaks a street number; CityFromAddressTests holds them as a
    // table-driven case with the exact line each must produce.
    private static func cityStateFromAddress(_ clauses: [String]) -> String? {
        guard let stateIndex = clauses.indices.reversed().first(where: {
            EventPlace.stateCodeInClause(clauses[$0]) != nil
        }), let code = EventPlace.stateCodeInClause(clauses[stateIndex]) else { return nil }
        // The nearest preceding clause carrying NO digit at all. Not merely "does not start with one":
        // a clause like "Floor 4" does not start with a digit and would put one on the card, which is the
        // whole thing #1030 forbids. No digit anywhere is the only version of this rule that cannot leak.
        guard let cityIndex = clauses[..<stateIndex].indices.reversed().first(where: {
            let clause = clauses[$0]
            return !clause.isEmpty && !clause.contains(where: \.isNumber)
        }) else { return nil }
        return "\(clauses[cityIndex]), \(code)"
    }

    // The embedded-address stripping (splitting on commas and dropping the first digit-leading clause and
    // everything after it) now lives in VenueNormalization.strippingEmbeddedAddress, shared with the
    // natural-key path (#1064), so display and de-duplication strip an address identically.
    //
    // Venue-specific normalization. Deliberately NOT GroupNameMatch.normalize, which is an org/
    // presenter normalizer that truncates a name at " - " / ": " and would merge distinct rooms.
    // Here we only case-fold and collapse runs of whitespace, preserving "/", commas, etc.
    //
    // #1744: the implementation moved to VenuePlaces with the table it keys, so the card and the
    // geography gate normalize a venue name identically. Kept here as the display layer's own name for
    // it rather than leaving two copies of four lines.
    static func normalize(_ s: String) -> String { VenuePlaces.normalize(s) }
}
