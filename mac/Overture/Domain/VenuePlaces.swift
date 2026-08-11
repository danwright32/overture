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
        guard let raw = sourceCleaned(venue), !raw.isEmpty else { return nil }
        for candidate in candidates(raw) {
            if let hit = table[key(candidate)] { return hit }
        }
        return nil
    }

    // #1896: the venue's IDENTITY, as one lowercased string. Distinct from `entry(for:)`, which
    // answers WHERE a venue is.
    //
    // THE REASON THIS EXISTS AS ITS OWN FUNCTION. `Entry` is Equatable and 41 rows of the table
    // below share the identical `manhattan` value, so anything keying identity on the entry
    // merges The Green Room 42, Merkin Hall, Asylum NYC, SoHo Playhouse, Abrons and Carnegie into
    // ONE venue. In #1887's shoot count that would tell the first recipient at any Manhattan room
    // that Dan shoots there regularly, which is the worst thing that feature can say.
    //
    // Answers, most authoritative first: the parent building when the table knows one (so Weill,
    // Zankel, Stern and Resnick are all Carnegie Hall), else the table's own spelling of whichever
    // candidate matched (so "Merkin Hall at Kaufman Music Center" and "Merkin Hall" agree), else
    // the shared natural-key fold, so a venue the table has never heard of still gets a stable
    // identity rather than none.
    //
    // CAUTION for anyone adding a `parent` to a row: `parent` was built for GEOGRAPHY, and this is
    // now its SECOND consumer. Giving a row a parent so its CARD reads nicely also merges it into
    // that parent here, in a sentence sent to a stranger. `jalopy's classroom` is the standing
    // example of a parent that is deliberately NOT the same room.
    static func canonicalKey(for venue: String?) -> String? {
        guard let raw = sourceCleaned(venue), !raw.isEmpty else { return nil }
        for candidate in candidates(raw) {
            guard let hit = table[key(candidate)] else { continue }
            if let parent = hit.parent { return key(parent) }
            return key(candidate)
        }
        // #1802: a room the table has never heard of still gets ONE identity, folded exactly the way a
        // known room's is. This line used to fold differently from the three above it (no leading article
        // dropped, and `normalizeForKey` rather than the shared `key`), so an unlisted room's identity
        // depended on which spelling a source happened to send: "The Green Room 42" and "Green Room 42"
        // were two rooms, and a shoot-history count and an address Dan typed each landed on one of them.
        return key(VenueNormalization.normalizeForKey(raw))
    }

    // #1896: the formatting a SOURCE wraps a venue in, as opposed to the venue's own name. Both
    // artifacts below are the Shoots calendar's, measured on the real export (2026-07-31), and
    // neither has ever appeared in a stored prospect venue, so cleaning them here rather than in
    // `VenueNormalization.normalizeForKey` keeps every stored natural key exactly where it is (a
    // change there is a migration, not a fix).
    //
    // Shared by `entry(for:)` and `canonicalKey(for:)` rather than done at one call site, so a
    // venue cannot be placed in one city by the card and keyed as a different room by the count.
    static func sourceCleaned(_ venue: String?) -> String? {
        guard var s = venue?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }

        // A matched pair of wrapping double quotes: 40 of 322 events, e.g. "Carnegie Hall,
        // Carnegie Hall". Only a matched pair is stripped, so a name that merely contains a quote
        // is untouched.
        while s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // An address written after a NEWLINE rather than a comma: 42 of 322 events. A newline
        // says exactly what a comma says here (this clause is WHERE the venue is), and every
        // clause-splitting rule downstream, `candidates` and `VenueNormalization.keyName` alike,
        // only knows about commas. Without this, "The Green Room 42\n570 10th Ave" is a different
        // venue from "The Green Room 42" and #1887's motivating room counts 1 shoot instead of 2.
        s = s.replacingOccurrences(of: #"\s*\n\s*"#, with: ", ", options: .regularExpression)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // The spellings to try, most specific first:
    //   1. the whole string, so a venue whose own name contains " at " ("The Space at Irondale", "Jazz
    //      at Lincoln Center Shanghai") matches before anything tries to split it;
    //   2. each comma clause, so "Gilder Lehrman Hall, The Morgan Library & Museum" is found by either
    //      half, and a trailing city or address clause simply misses;
    //   3. each side of an " at " or an " @ ", room before building, so "Merkin Hall at Kaufman Music
    //      Center" is found by the room and "Playhouse Stage at Abrons Arts Center" by the building;
    //   4. LAST, the name standing in front of a street address that no comma ever separated, so
    //      "Merkin Concert Hall 129 W. 67th St." is found by the room.
    //
    // Order is load-bearing. Every arm only ever ADDS a spelling to try, and the first hit wins, so an
    // arm appended later can never take a match away from one above it. Arm 4 is last for that reason:
    // it is the loosest, and it may only speak when nothing more specific matched.
    private static func candidates(_ raw: String) -> [String] {
        var out: [String] = [raw]
        let clauses = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if clauses.count > 1 { out.append(contentsOf: clauses) }
        for piece in out { out.append(contentsOf: roomAndBuilding(in: piece)) }
        for piece in out {
            if let name = nameBeforeAStreetAddress(piece) { out.append(name) }
        }
        return out.filter { !$0.isEmpty }
    }

    // #2451: the separators a source puts between a room and the building it sits in. `@` was the
    // missing one, and its absence split one room three ways: the Shoots calendar writes Merkin Hall as
    // "Merkin Hall at Kaufman Music Center" on two dates and "Merkin Hall @ Kaufman Music Center" on a
    // third, and only the first was ever reduced to the room.
    private static let roomSeparators = [" at ", " @ "]

    private static func roomAndBuilding(in piece: String) -> [String] {
        for separator in roomSeparators {
            guard piece.range(of: separator, options: .caseInsensitive) != nil else { continue }
            let halves = piece.components(separatedBy: separator)
            guard halves.count == 2 else { continue }
            return halves.map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return []
    }

    // #2451: the venue's own name, when a source ran the street address straight on with no comma and no
    // newline to separate it ("Merkin Concert Hall 129 W. 67th St."). Every clause-splitting rule above
    // needs a comma, and `sourceCleaned` only rewrites a NEWLINE into one, so this spelling reached the
    // fallback whole and became a room of its own carrying an address in its name.
    //
    // The tell is deliberately the same narrow one #2450 measured for junk, rather than "a leading
    // digit", which is wrong on real rooms: 54 Below, 48 Lounge and Theatre 71 all carry a number. A
    // street address begins with a token that is ONLY digits and is followed, later in the same string,
    // by a street-type word. The first token is never that token, so a room whose own name opens with a
    // number keeps its name.
    private static let streetWords: Set<String> = [
        "st", "st.", "street", "ave", "ave.", "avenue", "av", "rd", "rd.", "road", "dr", "dr.", "drive",
        "blvd", "blvd.", "boulevard", "pl", "pl.", "place", "lane", "ln", "terrace", "broadway",
        "plaza", "plz", "parkway", "pkwy", "court",
    ]

    private static func nameBeforeAStreetAddress(_ piece: String) -> String? {
        let words = piece.split(separator: " ").map(String.init)
        guard words.count > 1 else { return nil }
        for index in words.indices where index > 0 {
            guard words[index].allSatisfy({ $0.isNumber }) else { continue }
            guard words[(index + 1)...].contains(where: { streetWords.contains($0.lowercased()) })
            else { continue }
            return words[..<index].joined(separator: " ")
        }
        return nil
    }

    // Keys are pre-normalized (lowercased, single-spaced) and looked up through VenueNormalization.fold,
    // so a slash-spacing or street-suffix variant of a known venue still resolves (#1064).
    //
    // #1802: and a LEADING ARTICLE is dropped, because two folds disagreeing about it is exactly the
    // parallel-identity defect this issue exists to end. `ProducerGate.key` has always dropped it ("The
    // Soldiers' and Sailors' Monument" is that monument), and this one did not, so "The Green Room 42" and
    // "Green Room 42" were two rooms here and one room there: a shoot-history count split across both, and
    // an address Dan typed against one spelling never found by the other.
    private static func key(_ s: String) -> String {
        var folded = normalize(VenueNormalization.fold(s))
        if folded.hasPrefix("the ") { folded.removeFirst(4) }
        return folded.trimmingCharacters(in: .whitespaces)
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
    // #1850: Jalopy's own classroom, a separate room at 319 Columbia St run by the theatre at 315.
    // A real pairing, unlike the festival that merely PLAYS several rooms in one night.
    private static let jalopy = Entry(parent: "Jalopy Theatre", location: "Brooklyn, NY")
    // #2451: Merkin Hall is the concert hall inside Kaufman Music Center, and a watched source is
    // literally named "Kaufman Music Center (Merkin Hall)". Naming the building as the parent is what
    // makes the two ONE room here, which is what the CAUTION above is about: this parent is chosen for
    // identity, not for the card, and the merge it performs is the point rather than a side effect.
    private static let kaufman = Entry(parent: "Kaufman Music Center", location: "New York, NY")
    // #2451: the same mechanism used on a plain misspelling. The Shoots calendar carries "David Geffin
    // Hall" twice beside "David Geffen Hall" six times, and only a parent can fold a spelling onto
    // another spelling, since a parentless entry keys as itself. The card reads "David Geffen Hall
    // (David Geffin Hall)", which is the correction on its face.
    private static let geffen = Entry(parent: "David Geffen Hall", location: "New York, NY")

    // LIVE-STORE-CLAIM verified=2026-07-29 measure="the 78 distinct venue strings on untriaged prospects with a blank `location`"
    // Seeded from the venues those 342 rows actually name, plus the ten this table already held. Every
    // entry is a room a real row is playing in, not a guess at what Overture might meet later: a venue
    // nobody has a show at cannot be verified and would rot.
    // #1802: the hand-written keys below are read through the SAME fold every lookup uses, rather than
    // trusted as already-folded literals. They were written by hand as "pre-normalized" strings, so the
    // moment the fold learned anything new (here: that a leading article is not part of a room's
    // identity) every literal carrying one stopped matching, silently, while the table still looked
    // correct on the page. A table of keys nobody folds is a second fold.
    private static let table: [String: Entry] = Dictionary(
        rawTable.map { (key($0.key), $0.value) }, uniquingKeysWith: { first, _ in first })

    private static let rawTable: [String: Entry] = [
        // Carnegie Hall's own rooms.
        "weill recital hall": carnegie,
        "zankel hall": carnegie,
        "stern auditorium / perelman stage": carnegie,
        // #2451: the bare clause, which is how the calendar spells it seven times out of eight
        // ("Stern Auditorium, 161 West 56th Street"). The full name above never matched it, so seven
        // Carnegie shoots sat under a room of their own with no parent at all.
        "stern auditorium": carnegie,
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
        // #2451: Merkin split three ways in the shoot history, with its own building sitting beside it as
        // a fourth key. All four fold onto Kaufman Music Center now.
        "merkin hall": kaufman,
        "merkin concert hall": kaufman,
        "kaufman music center": manhattan,
        "asylum nyc": manhattan,
        "the players theatre": manhattan,
        "soho playhouse": manhattan,
        "abrons arts center": manhattan,
        "church of the ascension": manhattan,
        "wu tsai theater": geffen,
        // #2451: the building itself, which was only ever a parent NAME and never a key, plus the
        // spelling the calendar actually carries twice.
        "david geffen hall": manhattan,
        "david geffin hall": geffen,
        // #2451: Milbank Chapel at Teachers College, Columbia. Two keys before this, both unseeded: the
        // " at " split already worked and neither half was a table key, so the whole string fell to the
        // fallback. A split that works and still fails.
        "milbank chapel": manhattan,
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
        // #1762: the same church, spelled with the city appended by whichever source published it. Its
        // own key, deliberately, rather than teaching the lookup to drop trailing words: a trailing word
        // is often a DISAMBIGUATOR ("Holy Trinity Lutheran Church Brooklyn" is not the Manhattan one), so
        // dropping it blind would send a show to the wrong city, which is the hazard the Epiphany note
        // above is about. The general problem is its own issue.
        "trinity church nyc": manhattan,

        // #1762: rows whose `location` is blank, so nothing can be parsed out of the row itself and only
        // this table can give the card a city.
        //
        // LIVE-STORE-CLAIM verified=2026-07-30 measure="distinct ZVENUE on status-new prospects with a null or empty ZLOCATION"
        // Keyed on the string the store ACTUALLY holds, not the venue's tidy name. "House of the
        // Redeemer" alone looked right and matched nothing: the row reads "House of the Redeemer, Fabbri
        // Mansion", and the card looks a venue up exactly. A test written against the tidy name passed
        // while the entry did nothing (L48).
        "st. luke in the fields": manhattan,
        "park avenue christian church": manhattan,
        "brick presbyterian church": manhattan,
        "holy trinity lutheran church": manhattan,
        "house of the redeemer, fabbri mansion": manhattan,
        "the kosciuszko foundation": manhattan,
        // Dan's call (2026-07-30) on these two: the names are shared by churches nationwide, which is the
        // hazard the Epiphany note above describes. He accepts them as New York because the scout only
        // watches New York area sources, so a show reaching his queue is his local one. Both place IN
        // range, where a wrong entry costs a wrong city line and cannot hide a show.
        "st. paul's episcopal church": manhattan,
        "st. michael's parish hall": manhattan,
        // The 122-row venue. #1762's address parsing already gives its cards a city, since every one of
        // its rows carries an address. It is here so a row that arrives with NO location still places:
        // this table is read by the geography gate too now, not only by the card.
        "the green room 42": manhattan,

        // Brooklyn.
        "jalopy theatre": brooklyn,
        "jalopy's classroom": jalopy,
        "roulette intermedium": brooklyn,
        // #1762: the same room, and the single biggest group of cards with no city (9 rows on
        // 2026-07-30). The table held only the full name, so the bare one every source writes missed it.
        "roulette": brooklyn,
        // #1762: the same room, and the single biggest group of cards with no city (9 rows on
        // 2026-07-30). The table held only the full name, so the bare one every source writes missed it.
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
