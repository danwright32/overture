import Foundation

// #1744: WHERE a known venue is, as one table with two consumers.
//
// This table used to be `VenueDisplay.map`, private to the display layer, and its comment said it was
// "the single home for the knowledge (the display layer), deliberately not duplicated into the scout
// engine". That was true and it was also the defect: the geography gate (EventPlace) never sees a venue
// at all, so knowing that Weill Recital Hall is in New York helped the CARD and did nothing for the
// GATE. On 2026-07-29, 342 of 498 untriaged shows sat in the queue with no location, every single one of
// them naming a venue, so the gate was a no-op on two thirds of the queue while this table sat next to
// it holding exactly the answer (#1744).
//
// So the knowledge moved here, to be read by both: VenueDisplay for the card's city line, and
// EventLocationFill for the location a prospect is stored with. One table, so a venue can never be in
// one city for the card and another for the gate.
//
// WHAT MAY GO IN, and it is not symmetric. An entry that places a venue INSIDE Dan's range can only
// ever surface a show (an unplaced show is kept and flagged anyway, #970), so a wrong one costs a wrong
// city on a card. An entry that places a venue OUTSIDE his range HIDES shows. So:
//
//   - an out-of-range entry must be a globally unambiguous name (Royal Concertgebouw Amsterdam, Usher
//     Hall, Teatro Nacional Eduardo Brito). A common name that happens to be out of town does NOT go in.
//
// That rule is why "Church of the Epiphany" is deliberately ABSENT. The live store's row is a Young
// Concert Artists Washington debut, but there is also a Church of the Epiphany on Second Avenue in
// Manhattan, and an entry sending that name to Washington would hide a real New York show the day one
// appears. It stays unplaced, which keeps it in the queue, which is the safe failure.
enum VenuePlaces {
    struct Entry: Equatable {
        let parent: String?     // the larger building, e.g. "Carnegie Hall"
        let location: String?   // city/state, e.g. "New York, NY"
    }

    // The place a venue string names, or nil for a venue this table has never heard of. Nil is the
    // common answer and it is a safe one: nothing downstream may invent a location from a room name.
    static func location(for venue: String?) -> String? {
        entry(for: venue)?.location
    }

    // The entry for exactly this venue string, one key, no reduction beyond the shared fold. This is
    // what the CARD uses (VenueDisplay), which pairs the entry with a hall name it displays, so a
    // broader match would hand it a parent it then prints twice ("Weill Recital Hall at Carnegie Hall,
    // Carnegie Hall"). The card keeps its own #1064 retry on top of this.
    static func exact(_ venue: String) -> Entry? {
        table[key(venue)]
    }

    // The table entry for a venue string, tried against every spelling of it worth trying.
    //
    // A source writes one room several ways ("Weill Recital Hall", "Weill Recital Hall at Carnegie
    // Hall", "Stern Auditorium/Perelman Stage, Carnegie Hall"), and #1064 already proved that variance
    // real on the live store. Rather than one key per spelling, the candidates below reduce a string to
    // the parts that could name a venue and ask the table about each.
    static func entry(for venue: String?) -> Entry? {
        guard let raw = venue?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        for candidate in candidates(raw) {
            if let hit = table[key(candidate)] { return hit }
        }
        return nil
    }

    // The spellings to try, most specific first:
    //   1. the whole string, so a venue whose own name contains " at " ("The Space at Irondale", "Jazz
    //      at Lincoln Center Shanghai") matches before anything tries to split it;
    //   2. each comma clause, so "Gilder Lehrman Hall, The Morgan Library & Museum" is found by either
    //      half, and a trailing city or address clause simply misses;
    //   3. each side of an " at ", room before building, so "Merkin Hall at Kaufman Music Center" is
    //      found by the room and "Playhouse Stage at Abrons Arts Center" by the building.
    private static func candidates(_ raw: String) -> [String] {
        var out: [String] = [raw]
        let clauses = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if clauses.count > 1 { out.append(contentsOf: clauses) }
        for piece in out where piece.range(of: " at ", options: .caseInsensitive) != nil {
            let halves = piece.components(separatedBy: " at ")
            guard halves.count == 2 else { continue }
            out.append(halves[0].trimmingCharacters(in: .whitespaces))
            out.append(halves[1].trimmingCharacters(in: .whitespaces))
        }
        return out.filter { !$0.isEmpty }
    }

    // Keys are pre-normalized (lowercased, single-spaced) and looked up through VenueNormalization.fold,
    // so a slash-spacing or street-suffix variant of a known venue still resolves (#1064).
    private static func key(_ s: String) -> String {
        normalize(VenueNormalization.fold(s))
    }

    // Venue-specific normalization. Deliberately NOT GroupNameMatch.normalize, which is an org/
    // presenter normalizer that truncates a name at " - " / ": " and would merge distinct rooms.
    // Here we only case-fold and collapse runs of whitespace, preserving "/", commas, etc.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .joined(separator: " ")
    }

    // The set of parent-building names the table knows ("carnegie hall"), pre-normalized. A trailing
    // venue clause matching one of these is dropped before a retry lookup (#1064).
    static let knownParents: Set<String> = Set(
        table.values.compactMap { $0.parent }.map { normalize($0) }
    )

    // copy-inventory:ignore-start  Venue and place names this table MATCHES and stores, not the app's voice: 79 city strings would bury the inventory a person reads cold (#1744)

    private static let carnegie = Entry(parent: "Carnegie Hall", location: "New York, NY")
    private static let manhattan = Entry(parent: nil, location: "New York, NY")
    private static let brooklyn = Entry(parent: nil, location: "Brooklyn, NY")

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="the 78 distinct venue strings on untriaged prospects with a blank `location`"
    // Seeded from the venues those 342 rows actually name, plus the ten this table already held. Every
    // entry is a room a real row is playing in, not a guess at what Overture might meet later: a venue
    // nobody has a show at cannot be verified and would rot.
    private static let table: [String: Entry] = [
        // Carnegie Hall's own rooms.
        "weill recital hall": carnegie,
        "zankel hall": carnegie,
        "stern auditorium / perelman stage": carnegie,
        "resnick education wing": carnegie,
        "carnegie hall": manhattan,

        // Manhattan.
        "the metropolitan museum of art": manhattan,
        "the joyce theater": manhattan,
        "bryant park": manhattan,
        "madison square park": manhattan,
        "museum of chinese in america": manhattan,
        "the cutting room": manhattan,
        "under st marks": manhattan,
        "merkin hall": manhattan,
        "asylum nyc": manhattan,
        "the players theatre": manhattan,
        "soho playhouse": manhattan,
        "abrons arts center": manhattan,
        "church of the ascension": manhattan,
        "wu tsai theater": Entry(parent: "David Geffen Hall", location: "New York, NY"),
        "linda gross theater": manhattan,
        "atlantic stage 2": manhattan,
        "five angels theater": manhattan,
        "baruch performing arts center": manhattan,
        "judson memorial church": manhattan,
        "gilder lehrman hall": Entry(parent: "The Morgan Library & Museum", location: "New York, NY"),
        "hudson yards": manhattan,
        "greeley square": manhattan,
        "greely square": manhattan,          // the spelling Jalopy's own page uses
        "sakura park": manhattan,
        "the tank": manhattan,
        "new york city bar association": manhattan,
        "christ & saint stephen's church": manhattan,
        "st. paul & st. andrew church": manhattan,
        "mother ame zion church": manhattan,
        "chain theatre": manhattan,
        "spit&vigor tiny baby blackbox theater": manhattan,
        // Read as Trinity Wall Street: the row is a VOCES8 date and Trinity runs a concert series. The
        // name is not globally unique, so this is here only because it places IN range, where a wrong
        // entry costs a wrong city line and cannot hide a show.
        "trinity church": manhattan,

        // Brooklyn.
        "jalopy theatre": brooklyn,
        "jalopy's classroom": brooklyn,
        "roulette intermedium": brooklyn,
        "national sawdust": brooklyn,
        "the space at irondale": brooklyn,
        "church of st. luke and st. matthew": brooklyn,
        "st. ann & the holy trinity church": brooklyn,
        "polonsky shakespeare center": brooklyn,
        "brooklyn college": brooklyn,
        "brooklyn society for ethical culture": brooklyn,
        "wave hill": Entry(parent: nil, location: "Bronx, NY"),

        // In range, outside the city.
        "tarrytown music hall": Entry(parent: nil, location: "Tarrytown, NY"),
        "presbyterian church of mt. kisco": Entry(parent: nil, location: "Mount Kisco, NY"),
        "columbanus catholic church": Entry(parent: nil, location: "Cortlandt Manor, NY"),
        "croton free library performance space": Entry(parent: nil, location: "Croton-on-Hudson, NY"),
        "cv rich mansion": Entry(parent: nil, location: "White Plains, NY"),
        "sarah neuman": Entry(parent: nil, location: "Mamaroneck, NY"),
        "chatham united methodist church": Entry(parent: nil, location: "Chatham, NJ"),
        "barrymore film center": Entry(parent: nil, location: "Fort Lee, NJ"),

        // Out of range, and every one of these names one building on earth.
        "teatro nacional eduardo brito": Entry(parent: nil, location: "Santo Domingo, Dominican Republic"),
        "royal concertgebouw amsterdam": Entry(parent: nil, location: "Amsterdam, Netherlands"),
        "usher hall": Entry(parent: nil, location: "Edinburgh, Scotland"),
        "snape maltings concert hall": Entry(parent: nil, location: "Aldeburgh, England"),
        "national taichung theater": Entry(parent: nil, location: "Taichung, Taiwan"),
        "beijing performing arts center": Entry(parent: nil, location: "Beijing, China"),
        "jazz at lincoln center shanghai": Entry(parent: nil, location: "Shanghai, China"),
        "the phillips collection": Entry(parent: nil, location: "Washington, DC"),
        "synagogue at sixth & i": Entry(parent: nil, location: "Washington, DC"),
        "jimmy h. baker center for the arts": Entry(parent: nil, location: "Enterprise, AL"),
        "rosewood hotel georgia": Entry(parent: nil, location: "Vancouver, BC, Canada"),
        "stage west theatre": Entry(parent: nil, location: "Fort Worth, TX"),
    ]

    // copy-inventory:ignore-end
}
