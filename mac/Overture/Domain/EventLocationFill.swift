import Foundation

// #1744: the one place that decides WHERE a show is, before it is stored.
//
// Dan, 2026-07-29: "every show should have a location, no exceptions. there's no reason we shouldn't
// know the location." He said it looking at a card reading "NYO2 in Santo Domingo, Dominican Republic"
// while hunting for a "never show me shows in Santo Domingo" action that Overture was withholding,
// because the row's `location` was NULL and the town refusal is gated on a readable town.
//
// LIVE-STORE-CLAIM verified=2026-07-29 measure="untriaged prospects with a blank `location`"
// 342 of 498 untriaged shows had no location, so #970's geography gate never ran on two thirds of the
// queue and a Dominican Republic show, a Poughkeepsie show and a Carnegie show all sat there looking
// identical. Every one of those 342 rows DID name a venue, and 27 of them carried the answer in text
// Overture already had in hand.
//
// THE ORDER MATTERS, and it is not arbitrary:
//
//   1. the page's own words. `location` verbatim is the only first-hand report of where a show is.
//   2. an address baked into the venue string, which is the page's own words too, just in the wrong
//      field. Free, general, no curated data.
//   3. the tour title convention ("NYO2 in Santo Domingo, Dominican Republic"), which docs/contracts.md
//      has described all along as readable and which nothing read.
//   4. the curated venue table (VenuePlaces), shared with the card's city line.
//
// Rule 3 must sit ABOVE rule 4 and BELOW rule 1. Above 4, because a Carnegie tour date plays a hall no
// table knows, and reading its title is the only free way to place it. Below 1, because a page that
// says where it is outranks the show's name.
//
// WHAT IS DELIBERATELY NOT HERE: a per-source address. #1744's first shape proposed one, and it is
// wrong for the very row that opened the issue. Carnegie Hall's address is 881 7th Ave, so a
// source-level fallback would stamp "New York, NY" onto the Santo Domingo show, and a confident wrong
// place is the ONLY failure in this area that can hide a real show from Dan (EventPlace's whole design
// note). Every rule below either reads text about THIS show or says nothing.
enum EventLocationFill {

    // The location to store for this event, or nil when nothing readable says where it is. Nil is a
    // legitimate answer and stays legitimate: the gate keeps and flags an unplaced show (#970), and
    // #1744's screen work makes that state say so rather than look like a Manhattan show.
    static func location(for event: ExtractedEvent) -> String? {
        location(title: event.title, venue: event.venue, published: event.location)
    }

    // The same decision from the three fields it actually needs, so the backfill over rows ALREADY in
    // the store (LocationBackfill) runs the identical rule rather than a second copy of it. A stored row
    // is not an ExtractedEvent and never will be again: the extract that produced it is long gone.
    static func location(title: String, venue: String?, published: String?,
                         singleVenueSourceAddress: String? = nil,
                         roomAnswer: String? = nil) -> String? {
        if let own = published?.trimmingCharacters(in: .whitespacesAndNewlines), !own.isEmpty {
            return own
        }
        if let fromVenue = cityFromVenue(venue) { return fromVenue }
        if let fromTitle = cityFromTitle(title) { return fromTitle }
        // #1752, rule 3.5: what Dan himself said about this ROOM, above the curated table and below
        // everything that reads text about THIS show. Above the table because the table is our guess and
        // this is his answer, and a room he has answered for is by definition one the table got wrong or
        // never knew. Below rules 1 to 3 because those are first-hand about the show in front of him,
        // while his answer is a standing fact about the room, and a touring date in that room's building
        // is exactly the case where the show's own words matter more.
        let answered = roomAnswer?.trimmingCharacters(in: .whitespacesAndNewlines)
        if answered?.isEmpty == false { return answered }
        if let fromTable = VenuePlaces.location(for: venue) { return fromTable }
        // #1751, rule 5 and deliberately LAST: the address Dan typed on the source row, and only where
        // that source is a SINGLE-VENUE feed. See the note above about what is not here: a per-source
        // address is wrong for a multi-room source, because Carnegie's own address would place its Santo
        // Domingo tour date in New York. A single-venue feed cannot have that date; every show it
        // publishes is in the one room whose address he typed. Last because every rule above reads text
        // about THIS show, while this one is a standing fact about the room, and first-hand beats
        // standing. The caller decides which sources qualify, so this function still never has to know
        // what a source is.
        let typed = singleVenueSourceAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (typed?.isEmpty == false) ? typed : nil
    }

    // MARK: - Rule 2: the address a page baked into the venue field

    // The city and state out of a venue string that carries its own address, or nil.
    //
    // A single clause never answers: a bare room name ("Weill Recital Hall") names no place, and a bare
    // street ("312 W 36th St") names no city. So this reads only what sits AROUND a state.
    static func cityFromVenue(_ venue: String?) -> String? {
        guard let raw = venue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let clauses = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard clauses.count > 1 else { return nil }

        // From the END, so a leading city that shares a state's name ("New York, ... , NY") is read as
        // the city and the trailing code as the state, the same direction EventPlace scans.
        for i in clauses.indices.reversed() {
            // "Brooklyn, NY 11217": the state stands alone in its own clause, and the city is the one
            // before it. An address clause ("262 Ashland Place") is not a city and ends the read.
            if let state = EventPlace.stateInClause(clauses[i]) {
                guard i > 0 else { return nil }
                let city = clauses[i - 1]
                guard !city.isEmpty, city.first?.isNumber != true else { return nil }
                return "\(city), \(state)"
            }
            // "Chatham NJ": city and state in one clause with no comma between them, a variance
            // VenueNormalization already folds for the natural key (#1064).
            if let both = cityAndStateInOneClause(clauses[i]) { return both }
        }
        return nil
    }

    // "Chatham NJ" -> "Chatham, NJ". Requires at least one word before the state, so a lone state code
    // is not read as a city, and refuses a leading digit so a street never becomes a town.
    private static func cityAndStateInOneClause(_ clause: String) -> String? {
        let words = clause.split(separator: " ").map(String.init)
        guard words.count > 1, let last = words.last,
              let state = EventPlace.stateInClause(last) else { return nil }
        let city = words.dropLast().joined(separator: " ")
        guard !city.isEmpty, city.first?.isNumber != true else { return nil }
        return "\(city), \(state)"
    }

    // MARK: - Rule 3: the tour title convention

    // "NYO2 in Santo Domingo, Dominican Republic" -> "Santo Domingo, Dominican Republic".
    //
    // docs/contracts.md: the title cannot answer the location "except on Carnegie's NYO tour convention
    // (`NYO Jazz in Beijing, China`), which no other source shares". All seven of the live store's
    // Carnegie tour rows have exactly this shape and nothing was reading it.
    //
    // The rule is deliberately narrow, because a title is prose and "in" is an ordinary English word:
    // "Queeney Todd: The Demon Bottom of Fleet Street in Concert" must not place a show in a town called
    // Concert. So the tail after the last " in " counts only when it is exactly "<somewhere>, <place>"
    // and that trailing place is a country or US state THIS CODEBASE ALREADY RECOGNISES. One vocabulary,
    // EventPlace's, so a place this rule can write is a place the gate can read.
    static func cityFromTitle(_ title: String) -> String? {
        guard let marker = title.range(of: " in ", options: [.backwards, .caseInsensitive]) else {
            return nil
        }
        let tail = title[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = tail.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              EventPlace.namesAKnownPlace(parts[1]) else { return nil }
        return "\(parts[0]), \(parts[1])"
    }
}
