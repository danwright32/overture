import Foundation

// #970 Phase 2. Reads the location string the scout reported (#985) and answers one question: is this
// show somewhere Dan would shoot?
//
// Pure and network-free on purpose. No geocoder, no transit API, no lookup that costs money or can
// fail: the gate has to be deterministic, testable against real strings, and free, because the daily
// scout never spends.
//
// #1065: this is ONE of TWO independent consumers of the raw `location` string. The other is the card's
// display fallback (VenueDisplay.resolve's safeCityStateLine, #1030), which is STRICTER: it rejects any
// address-shaped location where this gate reads straight through the street noise. The two tolerances
// differ on purpose. If you change how `location` is normalized here, check that consumer too;
// LocationTwoConsumersGuardTests pins both against shared inputs and goes red when they diverge.
//
// THE RULE (Dan's, 2026-07-16, see #979):
//
//   music, band   -> the five boroughs only. He will not travel for a band or a choir.
//   everything else -> anywhere in NY, NJ or CT, minus the exclude list below.
//   anywhere else -> out of range.
//   cannot tell   -> UNKNOWN, which KEEPS and flags. Never a hide.
//
// That last line is the one that matters. A confident wrong place is the ONLY failure here that can
// hide a real show from Dan, so every rule below is written to reach `.unknown` rather than guess.
// This resolver's job is to be certain or to say it isn't.
//
// WHY AN EXCLUDE LIST AND NOT AN INCLUDE LIST (Dan's call, and it is the crux):
//
// "About an hour by train" cannot be computed for free. The alternative was a hand-written list of
// in-range towns, which is wrong BY OMISSION and fails CLOSED: a town nobody thought to add is
// silently hidden and Dan never learns the show existed. Its errors are invisible.
//
// An exclude list is wrong BY INCLUSION and fails OPEN: an unlisted far town shows up ONCE, Dan says
// "never again", and it is gone. Its errors are visible and self-correcting, and each costs one row
// seen one time. Same shape as the watchlist rule (#768): start permissive, only a refusal narrows it.
enum EventPlace {
    enum Verdict: Equatable, Sendable {
        case inRange
        case outOfRange
        case unknown        // keep it, flag it. Never hide on this.
    }

    // Why, so the UI can tell Dan what happened and a wrong hide is traceable to the rule that made it
    // rather than arriving as a bare verdict.
    enum Reason: Equatable, Sendable {
        case insideTheBoroughs
        case insideTheRegion
        case excludedTown
        case outsideTheBoroughs     // in NY/NJ/CT, but this is music and music stays in the boroughs
        case outsideTheRegion       // a real place, and not NY/NJ/CT
        case noLocation             // the page named none. Common, not an error.
        case couldNotPlace          // it said something, and we will not guess what
    }

    struct Result: Equatable, Sendable {
        var verdict: Verdict
        var reason: Reason
    }

    // copy-inventory:ignore-start  Place names the resolver MATCHES against, never says: Dan reads a verdict, not this data (#970)

    // The SEED. Pre-seeded with places that are in-state but plainly not an hour away, so Dan does not
    // have to refuse the obvious ones himself. Town-level, never state-level: excluding Buffalo must not
    // take the rest of New York with it.
    //
    // #991: this is only HALF the list. The exclude rule grows only by Dan's refusal (#979), and his
    // refusals live in the ExcludedTown store, not here in source. `resolve` reads the UNION of this seed
    // and his stored refusals (its `userExcludedTowns` argument), which is what lets him add a twentieth
    // town without a code change.
    //
    // "Never show me this town again" reads as absolute, so it holds for every discipline.
    static let excludedTowns: Set<String> = [
        "buffalo", "albany", "rochester", "syracuse", "binghamton", "ithaca", "utica",
        "niagara falls", "plattsburgh", "watertown", "elmira", "jamestown", "olean",
        "montauk", "east hampton", "southampton",         // Long Island, far end
        "atlantic city", "cape may", "wildwood",          // NJ shore, far end
    ]

    private static let boroughs: Set<String> = [
        "new york", "manhattan", "brooklyn", "queens", "the bronx", "bronx", "staten island",
    ]

    // The in-range states, as lowercase codes. Ordered so callers that need a stable list (e.g. #1170's
    // OPERA America feed filter, which pre-narrows the national calendar to exactly this set) get a
    // deterministic order; the gate itself only needs membership, so it derives its Set from this.
    static let inRangeStateCodes: [String] = ["ny", "nj", "ct"]
    private static let inRangeStates: Set<String> = Set(inRangeStateCodes)

    private static let stateNames: [String: String] = [
        "new york": "ny", "new jersey": "nj", "connecticut": "ct",
        "maryland": "md", "california": "ca", "kentucky": "ky", "massachusetts": "ma",
        "pennsylvania": "pa", "illinois": "il", "texas": "tx", "florida": "fl",
        "virginia": "va", "ohio": "oh", "michigan": "mi", "georgia": "ga",
        "north carolina": "nc", "south carolina": "sc", "tennessee": "tn", "colorado": "co",
        "washington": "wa", "oregon": "or", "arizona": "az", "nevada": "nv", "utah": "ut",
        "minnesota": "mn", "wisconsin": "wi", "missouri": "mo", "indiana": "in",
        "louisiana": "la", "alabama": "al", "oklahoma": "ok", "iowa": "ia", "kansas": "ks",
        "arkansas": "ar", "mississippi": "ms", "nebraska": "ne", "idaho": "id",
        "new hampshire": "nh", "vermont": "vt", "maine": "me", "rhode island": "ri",
        "delaware": "de", "west virginia": "wv", "montana": "mt", "wyoming": "wy",
        "north dakota": "nd", "south dakota": "sd", "alaska": "ak", "hawaii": "hi",
        "new mexico": "nm",
    ]

    private static let usStateCodes: Set<String> = Set(stateNames.values)

    // Checked BEFORE any state code, because a foreign address can carry a token that reads as one:
    // "11 Lange Begijnestraat Haarlem, NH, 2011 HH Netherlands" has "NH" in it, which is New
    // Hampshire's code, and the answer is still the Netherlands.
    private static let foreignMarkers: [String] = [
        "germany", "netherlands", "holland", "france", "spain", "italy", "portugal", "belgium",
        "austria", "switzerland", "liechtenstein", "norway", "sweden", "denmark", "finland",
        "iceland", "poland", "czech", "hungary", "greece", "turkey", "russia", "ukraine",
        "u.k.", "uk", "united kingdom", "england", "scotland", "wales", "ireland",
        "china", "japan", "taiwan", "korea", "india", "singapore", "thailand", "vietnam",
        "australia", "new zealand", "canada", "mexico", "brazil", "argentina", "chile",
        "dominican republic", "cuba", "colombia", "peru", "south africa", "israel", "egypt",
    ]

    // copy-inventory:ignore-end

    // #991: `userExcludedTowns` is Dan's stored refusals (ExcludedTown, lowercased), unioned with the
    // seed here so the gate reads both at queue time. Defaulted empty, so every existing caller and test
    // is unchanged and only the live queue passes the real set.
    static func resolve(location: String?, discipline: Discipline,
                        userExcludedTowns: Set<String> = [],
                        // #1221: seed towns Dan has UN-SKIPPED from inside the app. Subtracted from the
                        // exclusion set, so a built-in far town he now cares about resolves normally again.
                        // Defaulted empty, so every existing caller and test is unchanged.
                        allowedSeedTowns: Set<String> = []) -> Result {
        let raw = (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return Result(verdict: .unknown, reason: .noLocation) }

        let text = raw.lowercased()
        let tokens = commaTokens(text)

        // A refusal wins over everything, including the boroughs, because it is Dan speaking directly.
        // #1221: minus the seed towns he has un-skipped, so an allow can take a built-in far town back.
        let allExcluded = excludedTowns.union(userExcludedTowns).subtracting(allowedSeedTowns)
        if tokens.contains(where: { allExcluded.contains($0) }) {
            return Result(verdict: .outOfRange, reason: .excludedTown)
        }

        // Before states: a foreign address can contain something that reads as a US state code.
        if foreignMarkers.contains(where: { containsWord(text, $0) }) {
            return Result(verdict: .outOfRange, reason: .outsideTheRegion)
        }

        guard let state = state(in: text, tokens: tokens) else {
            // It said something and named no state we recognise. Do NOT guess: "Amsterdam" is a real
            // town in New York, and a list of four California cities names no state at all.
            return Result(verdict: .unknown, reason: .couldNotPlace)
        }

        guard inRangeStates.contains(state) else {
            return Result(verdict: .outOfRange, reason: .outsideTheRegion)
        }

        // In NY/NJ/CT. Now the only question left is the discipline split.
        let inBoroughs = tokens.contains(where: { namesABorough($0) }) && state == "ny"
        if discipline.staysInTheBoroughs {
            return inBoroughs
                ? Result(verdict: .inRange, reason: .insideTheBoroughs)
                : Result(verdict: .outOfRange, reason: .outsideTheBoroughs)
        }
        return Result(verdict: .inRange, reason: inBoroughs ? .insideTheBoroughs : .insideTheRegion)
    }

    // Split on commas AND strip the noise a real address carries, so "santa monica" in
    // "Pasadena, and Santa Monica" is still recognisable as one token rather than "and santa monica".
    private static func commaTokens(_ text: String) -> [String] {
        text.split(separator: ",").map {
            var t = $0.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("and ") { t = String(t.dropFirst(4)) }
            return t.trimmingCharacters(in: .whitespaces)
        }
    }

    // #1656: the state a location names, through the SAME token rule `excludableTown` uses, plus one
    // inference for a borough phrase that names no state at all.
    //
    // This used to look for a full state name ANYWHERE in the text, on the reasoning that a spelled-out
    // name is unambiguous. A name is unambiguous; a name buried inside a longer place name is not. "New
    // York Mills, MN" is a real Minnesota town with a regional cultural centre, and it read as New York
    // state while its own "MN" was never considered. "Kansas City, MO" read as Kansas the same way. Worse,
    // `excludableTown` never shared the flaw (it has always required the state to BE a comma token), so
    // the two disagreed: the row was kept as a New York show AND offered no way to refuse its town, which
    // is the same withheld-control defect #1744 was about.
    //
    // So the state must be its own comma piece. That alone would lose the bare phrase "New York City",
    // which names no state and is the whole of #1656, hence the second step: a token that names a borough
    // IS New York. A real state token always wins over that inference, which is what keeps a Minnesota
    // town in Minnesota.
    private static func state(in text: String, tokens: [String]) -> String? {
        if let named = stateToken(in: tokens)?.code { return named }
        // No state named anywhere. A borough phrase is still a statement about where this is.
        return tokens.contains(where: { namesABorough($0) }) ? "ny" : nil
    }

    // #991: the town Dan's "never show me shows in this town" action would exclude, taken from a row's
    // own location string, or nil when there is nothing worth offering. It returns the town in its
    // ORIGINAL case (for the message he reads); storage lowercases it.
    //
    // The town is the piece just before the state ("Poughkeepsie" in "Poughkeepsie, NY", and in "123 Main
    // St, Poughkeepsie, NY, 12601"), so the offer targets the city, never the street or the ZIP.
    //
    // Three deliberate refusals, each so the offer only ever appears where excluding actually helps:
    //   - no US state named -> nil. "Amsterdam" could be Amsterdam, New York; guessing is the #979 mistake.
    //   - the state is OUT of NY/NJ/CT -> nil. The state already hides it, so there is no town to add.
    //   - the town is one of the five boroughs -> nil. That is the in-range core Dan always wants;
    //     "never show me New York" would silently empty his whole queue.
    static func excludableTown(from location: String?) -> String? {
        let raw = (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        // Original-case comma tokens (for the returned town) alongside the lowercased ones the state
        // detection needs, split the same way commaTokens splits, so the two stay aligned by index.
        let rawTokens: [String] = raw.split(separator: ",").map {
            var t = $0.trimmingCharacters(in: .whitespaces)
            if t.lowercased().hasPrefix("and ") { t = String(t.dropFirst(4)) }
            return t.trimmingCharacters(in: .whitespaces)
        }
        let lowerTokens = rawTokens.map { $0.lowercased() }

        guard let (stateIndex, stateCode) = stateToken(in: lowerTokens), stateIndex > 0,
              inRangeStates.contains(stateCode) else { return nil }

        let city = rawTokens[stateIndex - 1].trimmingCharacters(in: .whitespaces)
        let cityLower = city.lowercased()
        guard !cityLower.isEmpty, !namesABorough(cityLower) else { return nil }
        return city
    }

    // #1744: whether a comma token names one of the five boroughs, by the SAME rule for both callers
    // above. `resolve` asks it to decide the discipline split; `excludableTown` asks it to withhold the
    // "never show me shows in this town" offer. Two callers, one predicate, deliberately: a widening
    // that taught the gate to read a borough and left the refusal offering "never show me shows in
    // downtown Brooklyn" would quietly cut Dan's own city.
    //
    // The borough name has to appear as a WORD. Exact equality was correct while `location` only ever
    // held a page's own words, and #1744 stopped that being true: it fills the gap from the venue
    // string, and the live store's own text includes "downtown Brooklyn, NY". Under exact matching that
    // read as music outside the five boroughs, which would have hidden a real Red Hook folk festival.
    // Word matching keeps "Brooklynville" out (the letter after the match must not be a letter), and the
    // caller still requires the state to be New York, so West New York, NJ is not a borough either.
    private static func namesABorough(_ token: String) -> Bool {
        boroughs.contains(token) || boroughs.contains(where: { containsWord(token, $0) })
    }

    // #2378: a clause written in NYC's own shorthand, which names no US state and so anchors nothing.
    // Returns it as a "City, ST" pair fit to write into a location field, or nil.
    //
    // Two shapes, both live in the store: "NYC 10019" (54 Below's own listing, and 54 Below is the room
    // that motivated the room-answer feature in the first place), and a bare borough clause such as the
    // "Manhattan" ending `House of the Redeemer, Fabbri Mansion, 7 East 95th Street, Manhattan`.
    //
    // A borough is read as New York the SAME way `state(in:)` already reads one when a location string
    // names no state, so this adds no second opinion about what a borough means. The error it can make is
    // placing a Manhattan, Kansas show in New York, which errs toward SHOWING a show rather than hiding
    // one, and hiding is the failure this area guards against.
    static func cityShorthandInClause(_ clause: String) -> String? {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // The leading token, so a ZIP after it is ignored, matching stateInClause's own reading.
        let head = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        if head.lowercased() == "nyc" { return "New York, NY" }
        // A borough standing as the WHOLE clause. Not a word match: "Brooklyn Academy of Music" is a
        // venue, not a statement about where anything is.
        if boroughs.contains(trimmed.lowercased()) { return "\(trimmed), NY" }
        return nil
    }

    // #2378: the same predicate, for a caller outside this type. `StreetClause` asks it before it will
    // accept a ONE word tail as a town, so a single word is trusted only when it names a place this
    // codebase already knows. Exposed rather than copied, because a second list of the five boroughs is
    // exactly the drift `namesABorough` was consolidated to stop.
    static func namesAKnownBorough(_ text: String) -> Bool {
        namesABorough(text.trimmingCharacters(in: .whitespaces).lowercased())
    }

    // #1744: the state a single comma clause names, as text fit to write back into a location ("NY" from
    // "NY 11217", "Alabama" from "Alabama"), or nil. Exposed so EventLocationFill reads state names
    // through THIS vocabulary rather than starting a second list of the United States, which would drift
    // from the one the gate places shows with.
    static func stateInClause(_ clause: String) -> String? {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // A spelled-out state standing as the whole clause.
        if stateNames[trimmed.lowercased()] != nil { return trimmed }
        // A two-letter code as the clause's leading word, so a ZIP or a parenthetical after it is
        // ignored ("NY 11217", "NY (specific venue not named on page)").
        let head = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        if head.count == 2, usStateCodes.contains(head.lowercased()) { return head.uppercased() }
        return nil
    }

    // #1762: the two-letter CODE a clause names, or nil. The sibling above answers with the text as
    // WRITTEN, because it exists to write a value back into a location field; the card wants one shape
    // whatever a source published, so "Brooklyn, New York" and "Brooklyn, NY 11217" both end up reading
    // "Brooklyn, NY". Same table, two renderings, rather than a second list of the United States.
    static func stateCodeInClause(_ clause: String) -> String? {
        let trimmed = clause.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let code = stateNames[trimmed.lowercased()] { return code.uppercased() }
        let head = trimmed.split(separator: " ").first.map(String.init) ?? trimmed
        if head.count == 2, usStateCodes.contains(head.lowercased()) { return head.uppercased() }
        return nil
    }

    // #1744: whether this text names a country or US state the resolver already knows. It is what keeps
    // the tour-title rule narrow: the tail of a title counts as a place only when the gate would be able
    // to place it, so a show called "... in Concert" never becomes a show in a town called Concert.
    static func namesAKnownPlace(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return false }
        if foreignMarkers.contains(t) { return true }
        if stateNames[t] != nil { return true }
        return t.count == 2 && usStateCodes.contains(t)
    }

    // The index of the comma token that carries the state, and its code, scanned from the END so a
    // leading city that happens to be a state name ("New York" in "New York, NY") is read as the city and
    // the trailing "NY" as the state, not the other way round.
    private static func stateToken(in lowerTokens: [String]) -> (index: Int, code: String)? {
        for i in lowerTokens.indices.reversed() {
            let t = lowerTokens[i]
            if let code = stateNames[t] { return (i, code) }
            let head = t.split(separator: " ").first.map(String.init) ?? t
            if head.count == 2, usStateCodes.contains(head) { return (i, head) }
        }
        return nil
    }

    private static func containsWord(_ text: String, _ word: String) -> Bool {
        guard let r = text.range(of: word) else { return false }
        let before = r.lowerBound == text.startIndex ? " " : String(text[text.index(before: r.lowerBound)])
        let after = r.upperBound == text.endIndex ? " " : String(text[r.upperBound])
        return !before.first!.isLetter && !after.first!.isLetter
    }
}

extension Discipline {
    // Dan's split. Music and band stop at the boroughs; he will travel for a production.
    // `.other` takes the LOOSE rule (his call, #979): an unreadable title errs toward being shown.
    var staysInTheBoroughs: Bool {
        switch self {
        case .music, .band: return true
        case .dance, .opera, .theater, .comedy, .other: return false
        }
    }
}
