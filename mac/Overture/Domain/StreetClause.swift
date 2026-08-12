import Foundation

// #2378 and #1852: one question, asked by two callers in opposite directions.
//
// `VenueNormalization.strippingEmbeddedAddress` asks "is this comma clause an address, so the card must
// stop here?" `EventLocationFill.cityFromVenue` asks "is this comma clause an address, so it cannot be a
// city?" Both answered it with "does it start with a digit", separately, and both were wrong in the same
// way: an address clause need not open with a house number.
//
// Live on 2026-08-12: `Sakura Park, W 122nd St & Riverside Dr` printed its whole address on the card,
// because "W" is not a digit. And `Peter Jay Sharp Theatre, 2537 Broadway at 95th St. New York, NY
// 10025-6990` read as unplaceable, because the clause holding "New York" was thrown away for starting
// with one.
//
// One vocabulary here, so the two callers cannot drift into two ideas of what an address is (L16).
enum StreetClause {
    // The street words that mark a clause as an address. Deliberately a closed list of SUFFIXES plus
    // "broadway", rather than anything that looks street-shaped: this list can cut a venue's name off its
    // own card, so every term on it was checked against the clauses live venue strings actually keep
    // (Carnegie Hall, The Morgan Library & Museum, Red Hook, Fabbri Mansion, Mainstage Theater).
    //
    // Plurals are here because a cross-street clause names two of them ("Between 32nd and 33rd Streets"),
    // which is exactly the phrasing #1852 was filed on.
    private static let streetWords: Set<String> = [
        "st", "street", "streets", "ave", "avenue", "avenues", "blvd", "boulevard",
        "rd", "road", "dr", "drive", "ln", "lane", "pl", "place", "plaza",
        "pkwy", "parkway", "hwy", "highway", "terrace", "turnpike", "broadway"
    ]

    // Does this clause describe WHERE something is on the street grid, rather than name a place?
    //
    // A house number still counts, because it always did and the store is full of them. The addition is a
    // clause that names a street without one, which is how a cross street is written.
    static func isAddress(_ clause: String) -> Bool {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return false }
        if first.isNumber { return true }
        return words(trimmed).contains { isStreetWord($0) }
    }

    // The town written at the END of an address clause, with no comma before it, or nil.
    //
    // The shape this exists for: `2537 Broadway at 95th St. New York`. A source wrote the street and the
    // town in one clause, and the town is the run of words after the last street word.
    //
    // Conservative on purpose. A confidently wrong place is the one failure in this area that can HIDE a
    // real show, so every doubt answers nil and the row stays unplaced, which is a state the app already
    // shows honestly and lets Dan fix by hand (#1752). Three refusals:
    //
    //   - nothing after the last street word ("458 West 37 Street @ 10th Avenue" names no town at all)
    //   - a tail carrying a digit (a ZIP, or a second street fragment)
    //   - a tail of ONE unknown word. `254 W 54th St. Cellar` is in the store and ends in a floor name,
    //     and "Cellar, NY" would be a town that does not exist. A single word is accepted only when it
    //     names one of the five boroughs, which is a place EventPlace already recognises rather than a
    //     word this rule decided to trust. A real one-word town written this way is therefore MISSED
    //     rather than mis-answered, which is the safe direction.
    static func trailingPlace(_ clause: String) -> String? {
        let w = words(clause.trimmingCharacters(in: .whitespaces))
        guard let lastStreetWord = w.lastIndex(where: { isStreetWord($0) }) else { return nil }
        let tail = Array(w[(lastStreetWord + 1)...])
        guard !tail.isEmpty else { return nil }
        guard !tail.contains(where: { $0.contains(where: \.isNumber) }) else { return nil }
        let place = tail.joined(separator: " ")
        guard tail.count > 1 || EventPlace.namesAKnownBorough(place) else { return nil }
        return place
    }

    private static func words(_ clause: String) -> [String] {
        clause.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    // A street word has to be a WORD. Matched after stripping the punctuation a source attaches to it
    // ("St.", "Dr,", "Ave)"), so the abbreviation a page actually writes is recognised, while
    // "Streetcar", "Placement" and "Driveway" are left alone: a venue named for one of those must keep
    // its name (L104).
    private static func isStreetWord(_ word: String) -> Bool {
        let bare = word.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased()
        return streetWords.contains(bare)
    }
}
