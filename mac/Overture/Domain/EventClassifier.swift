import Foundation

// Rule-based event classifier, ported from the engine's classifyEvent.ts. Turns a
// raw extracted calendar event into the ranker's classification inputs from simple
// signals (presenter, venue, title keywords). It used to flag ambiguous events
// `.uncertain` for an optional AI refine pass (#30); that pass was never built, the
// round-trip files for it were retired in #493, and the flag itself in #1533.

struct ExtractedEvent: Codable, Equatable, Sendable {
    var title: String
    var presenter: String?
    var venue: String?
    var performanceDate: String?
    var sourceUrl: String?
    // #970: where the page says this show is, VERBATIM. Not parsed here and not normalized: what a
    // page writes ranges from "Louisville, KY" to "southern Norway" to a full street address to a
    // comma-joined list of four cities, and deciding what any of that MEANS is a resolver's job, not
    // the wire's. Nil means the page named no place, which is common and is not an error.
    //
    // The venue cannot stand in for this reliably: a venue can pick up a comma only when a source page
    // bakes a full street address into it (#1030), an artifact of the address rather than a location
    // report, and the touring artist pages this exists for frequently name no venue at all.
    var location: String?
    // #1174: the source's own production id, when it publishes one that ties several performances of one
    // show together (VenueTix tags every night of a run with a shared seriesId). It is not classified or
    // normalized here: RunGrouping uses it downstream to collapse those nights into one run regardless of
    // how far apart they fall. Nil for every source that names no such id, which is nearly all of them.
    var seriesId: String?
    // #1469: the run read this row's page and the PAGE ITSELF has not published a venue yet (a placeholder
    // row, an explicit TBA). Absent, the near-universal case, means the ordinary reading: a row that came
    // back with no venue is one whose detail page may never have been opened, which is a suspected reading
    // failure and still costs the source its ability to mark shows gone (#887).
    //
    // The two look identical in the data and are opposite facts about a source. Smoke Ring's own page prints
    // "Info coming soon" against its Oct 24 gig; counted as an unread page that one row is 25% of a four-show
    // calendar, so the band's page sat past the 5% tolerance with cancellation detection switched off, for as
    // long as the placeholder existed. The run is the only thing that can see the difference, so it says so.
    var venueNotPublished: Bool?
    // #1788: the run named a presenter and it was the ROOM, so the boundary drained it
    // (ExtractedEventGuard.presenterThatIsNotTheRoom). Absent means the ordinary case: the page named
    // nobody, or it named somebody real.
    //
    // The two are opposite facts and are identical in the data once the name is gone. Dan can act on
    // this one, because a show at a room he knows often has a company he can name himself; he can do
    // nothing about a page that simply never said. His words on the #1766 post-merge check: "flag the
    // card for me". Without this the drain is silent, and a silent drop is indistinguishable from a
    // value that never existed.
    var presenterWasTheRoom: Bool? = nil
    // #1699: the times this show starts on `performanceDate`, as "HH:mm", in the order the source lists
    // them. Empty for nearly every source, and that is the ORDINARY state, not a gap: only the three
    // native readers that receive a time publish one (VenueTix and Squarespace already held the exact
    // instant and discarded it; OvationTix states it per showtime). TicketTailor, the OPERA feed and
    // every AI-read page genuinely have only a day.
    //
    // A LIST because #1984 measured productions that play twice on one day (a 5:00 PM and 9:15 PM double
    // bill). One entry is the common case; the card must not turn two into one by showing the first.
    var startTimes: [String] = []
}

// LIVE-STORE-CLAIM verified=2026-07-28 measure="undecided rows the retired confidence sentence was true of, against all undecided rows"
// #1533: this used to carry a `confidence` too, and the queue showed it as "Not sure of the genre or
// type, tap to confirm or fix". It was derived from production and profile ALONE, so it never measured
// the genre it named, and it was true of 431 of the 556 undecided rows on the live store while having
// been answered twice in the app's life. Both halves of the sentence were dead ends: the app was not
// unsure of the genre, and the production type is a fact Dan does not research (it means reading the
// presenter's site to see who is putting the show on). `.unknown` production already scores a neutral 0,
// so leaving it unanswered was never a scoring error, and the whole prompt's ranking stake was 16 rows.
// The genre stays correctable by hand from the row; nothing prompts for it.
struct EventClassification: Equatable, Sendable {
    var discipline: Discipline
    var reachable: Bool
    var production: Production
    var profile: Profile
    var coverage: Coverage
    var fitReason: String
}

enum EventClassifier {
    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // #2508: ANCHORED, and every term that can be pluralised carries an optional trailing s.
    //
    // These were bare alternations, so they fired inside longer words: `Operation Mincemeat: Mission
    // Recast` matched "opera" and read as an organisation, `Sam Gelband` matched "band", and
    // `Let's Get Schooled!` matched "school" and was carried into strongProfile with it.
    //
    // The anchor cannot go on alone. Measured over every distinct presenter and title in the live store,
    // anchoring by itself stopped matching `NY Phil Ensembles at Merkin Hall`, because "ensemble" no
    // longer matched its own plural, and `Debuts on Debuts Niche Media Productions`, which is a debut
    // showcase. So the plural sweep is part of the same change, not a follow-up.
    //
    // Matched against `wordSeparated(_:)` below rather than the raw string, which is the other half the
    // measurement turned up. See its own note.
    private static let agencySignal =
        #"\b(competition|winners|rising stars|invitational|young artists?|debuts?|showcase|celebrations international|concerts international|distinguished concerts|mid.?america|national concerts|jam generation|tours?|gala of)\b"#
    private static let producerSignal =
        #"\b(choirs?|chorus|choruses|chorale|chorales|choral|orchestras?|philharmonics?|ensembles?|consorts?|schools?|academy|academies|conservatory|conservatories|universit(y|ies)|colleges?|institutes?|theatres?|theaters?|company|companies|operas?|ballets?|dance|societ(y|ies)|centers?|centres?|foundations?|churches?|church|temples?|youth|communit(y|ies)|collectives?|quartets?|quintets?|bands?)\b"#
    private static let strongProfile =
        #"\b(choirs?|chorus|choruses|chorale|chorales|choral|schools?|academy|academies|conservatory|conservatories|youth|communit(y|ies)|children|ensembles?|operas?|ballets?|dance|theatres?|theaters?|cultural|universit(y|ies)|colleges?|churches?|church|temples?)\b"#

    // A word glued to a prefix in camel case is still that word, and a plain word boundary refuses it.
    // Found by measuring the anchored lists over the live store rather than by reading them: it would
    // have silently stopped recognising `PUBLIQuartet` (a string quartet) and `iSchool of Music & Art`
    // (a school) as organisations, and each loss would have looked exactly like the fix working.
    //
    // The lowercase-to-uppercase transition is precisely what tells those apart from the shapes that
    // must STAY refused: "Gelband" and "Schooled" have no transition, so they are left glued and go on
    // matching nothing. The second pattern is the acronym case, splitting `PUBLIQuartet` before its last
    // capital rather than after the run.
    static func wordSeparated(_ text: String) -> String {
        var out = text.replacingOccurrences(of: #"([a-z0-9])([A-Z])"#, with: "$1 $2",
                                            options: .regularExpression)
        out = out.replacingOccurrences(of: #"([A-Z]+)([A-Z][a-z])"#, with: "$1 $2",
                                       options: .regularExpression)
        return out
    }

    // #2508: exposed so the rules can be tested as rules, and so a test names the QUESTION ("does this
    // string name an organisation") rather than restating the regex, which would be a second copy of the
    // thing under test (L103).
    static func namesAnOrganisation(_ party: String) -> Bool {
        matches(wordSeparated(party), producerSignal)
    }

    static func hasStrongProfileSignal(_ text: String) -> Bool {
        matches(wordSeparated(text), strongProfile)
    }

    static func hasAgencySignal(_ text: String) -> Bool {
        matches(wordSeparated(text), agencySignal)
    }

    // #2504: does this act line name the room it plays in? Then the show is the building's own, and the
    // building is never a party Dan may pitch.
    //
    // Whole-venue-string containment and nothing cleverer. A room named only in part ("in the theatre or
    // the tavern", on a Jalopy Theatre row) is not caught, which is a smaller and rarer miss than a word
    // list would create in the other direction: plenty of real acts are named for a place, and treating
    // every venue word as the room would silently disqualify them.
    private static func titleNamesTheRoom(_ title: String, venue: String) -> Bool {
        let room = venue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Too short to be a name of its own: a three-character venue would match inside ordinary words.
        guard room.count >= 4 else { return false }
        return title.range(of: room, options: [.caseInsensitive]) != nil
    }

    // #2688: does this ONE word already produce a genre here?
    //
    // Asked by the correction report, so it can never propose a word the classifier already matches on:
    // telling Dan to add something that is there, every time, is how a report stops being read. Answered
    // by RUNNING the real rules over the word rather than by a second copy of the vocabulary, which is
    // the point. A hand-maintained list of "words we know" beside the list that actually decides is two
    // definitions of one thing, and it would drift the first time either was edited (L41).
    static func alreadyReads(_ word: String) -> Bool {
        detectDiscipline(wordSeparated(word)) != .other
    }

    private static func detectDiscipline(_ text: String) -> Discipline {
        if matches(text, #"\b(dance|ballet|balletto|tap|choreograph|nutcracker)\b"#) { return .dance }
        if matches(text, #"\b(opera|operetta)\b"#) { return .opera }
        // "play" is too common in names to be a reliable theater signal, and stays out entirely.
        // "musical" is not refused any more, it is DEMOTED: see the weak-signal pass at the end, which
        // only ever reads a row nothing else could (#1946).
        if matches(text, #"\b(theatre|theater|drama|cabaret|playhouse)\b"#) { return .theater }
        // #350: Choral folded into Music; the keyword signal still disambiguates against
        // band/comedy checks below, it just no longer produces a separate discipline bucket.
        if matches(text, #"\b(choir|chorus|chorale|choral|voices|singers|cantata|vocal)\b"#) { return .music }
        if matches(text, #"\b(band|wind ensemble|brass|jazz band|marching)\b"#) { return .band }
        if matches(text, #"\b(comedy|comedian|stand.?up|improv)\b"#) { return .comedy }
        // #970 Phase 0. Checked last, because these words are weaker signals than the ones above and
        // must lose to them: "Opera in Concert" is opera, "Playhouse Orchestra Night" is theater.
        // Deliberately NOT here: "musical" (a theater word, read by the weak pass below) and
        // "performance"/"artist", which name no discipline at all. `music` is bounded so it cannot match
        // inside "musical".
        if matches(text, #"\b(music|orchestra|philharmoni\w*|symphon\w*|piano|pianist|violin\w*|viola|cello|cellist|flute|clarinet|trumpet|harpsichord|guitar|recital|concerto|sonata|quartet|quintet|octet|sextet|septet|trio|chamber|camerata|conservatory|soprano|tenor|baritone|mezzo|jazz|blues|bluegrass|folk|composer|conductor|concert|song|songs|melodies|sing|sings|singing|singalong)\b"#) { return .music }

        // #1946: the weak signals, read LAST and only when nothing above matched, so a word too common to
        // outrank a real signal can still rescue a row that would otherwise have no genre at all.
        //
        // MEASURED on the live store 2026-08-07 (845 rows, 537 with no genre). "musical" appears in 18 of
        // those unread rows and names a stage musical in nearly all of them: Bone Wars: A New Musical,
        // Alice in Wonderland the Musical, A Christmas Carol the Musical, Marlise (A New Golden Age
        // Musical), The Secret Circus Musical, Legends: A New Musical. Read at full strength it would also
        // have TAKEN four rows that already have a better genre ("Gross Prophets: A Comedy Musical" is
        // comedy, three times over), which is the cost the original refusal was protecting against and the
        // reason this pass is last rather than beside the theater check.
        if matches(text, #"\b(musicals?)\b"#) { return .theater }
        return .other
    }

    // #2565: the two strings the signal lists above are matched against for a given row, and WHICH of them
    // is the party, in one place.
    //
    // Exposed because the corrective pass for the rows #2508 already lifted has to ask what the OLD
    // pattern would have said about THIS row, and the only honest way to ask that is against the same
    // strings the classifier itself reads. A second spelling of "who is the party here" beside this one is
    // how the two come to disagree about the same row (L41), and the answer moves every time the party
    // rule does.
    static func signalStrings(for event: ExtractedEvent) -> (party: String, haystack: String) {
        let presenter = event.presenter ?? ""
        let actIsTheParty = OrganiserNaming.onlyTheActIsNamed(presenter: event.presenter)
            && !titleNamesTheRoom(event.title, venue: event.venue ?? "")
        return (actIsTheParty ? event.title : presenter, "\(event.title) \(presenter)")
    }

    static func classify(_ event: ExtractedEvent) -> EventClassification {
        let presenter = event.presenter ?? ""
        let venue = event.venue ?? ""
        let strings = signalStrings(for: event)
        let haystack = strings.haystack
        // #1658: the SHOW decides its own genre, and the organisation's name is only consulted when the
        // show's own title says nothing. Read together, the presenter's name outranked the show on 11 live
        // rows: "The 2026 Brooklyn Folk Festival" at Jalopy Theatre read as theater, "Headquarters Comedy"
        // at SoHo Playhouse read as theater, and a Beethoven symphony billed by an opera company read as
        // opera. A building's name is a poor witness to what is on inside it tonight.
        //
        // The fallback is the JOINED text rather than the presenter alone, so a title that says nothing
        // lands exactly where it always did: this phase changes which signal WINS, never how many rows are
        // readable. Title-only would leave 510 of 699 rows unreadable; with this fallback it stays at 377.
        let fromTitle = detectDiscipline(event.title)
        let discipline = fromTitle == .other ? detectDiscipline(haystack) : fromTitle

        // #2504: WHO this show would be pitched to. The presenting organisation when one is named, and
        // the ACT itself when none is.
        //
        // LIVE-STORE-CLAIM verified=2026-08-11 measure="rows naming no presenting organisation, and their mean fit score against the rest"
        // Measured on the live store 2026-08-11: 439 of 877 rows name no presenting organisation, and
        // they average a fit score of 0.4 against 3.2 for the rest. That gap was structural rather than a
        // judgement about the shows. `isProducer` was gated on the presenter string being non-empty, and
        // production, profile and coverage are all drawn from it, so on those 439 rows production could
        // never be anything but `unknown`, profile could never be `strong`, and coverage could never be
        // `likelyUncovered`. Every one of those is the "we know nothing" value and every one scores 0, so
        // the score read on the queue as "poor fit" while it actually meant "we could not look".
        //
        // Dan's call, 2026-08-11: judge the act, because the act is the party he would write to. His
        // position on these leads, from #2464: "do not filter. often solo performers are great leads."
        // Except when the act line is the ROOM'S OWN name. "Chain Theatre Fall One Act Festival" at Chain
        // Theatre is the building's own event, and the building is the one organisation on the page that
        // is certainly not a party Dan may pitch (#1787, #2259, and the hard venue-disqualify rule). An
        // act with nobody behind it and an organisation Overture refuses to write to are opposite
        // situations that look identical once the presenter field is empty, and lifting the second would
        // undo #1845, which exists to stop a room outranking shows that really are self-produced.
        //
        // LIVE-STORE-CLAIM verified=2026-08-11 measure="act-named rows whose title contains their own venue name"
        // The discriminator is the TITLE, not `presenterWasTheRoom`. Measured on the live store
        // 2026-08-11: 322 of the 439 act-named rows carry that flag, because rooms that rent themselves
        // out bill themselves as the presenter and the boundary drains it, and those rows are exactly the
        // soloists this change is for. Only 7 name the room in the title, and they are the genuine
        // article ("54 Does 54: The 54 Below Staff Show", "LOL! The Players Theatre Short Play Festival").
        //
        // What it gets wrong, named (L93): a real act playing AT a room it does not own reads as the
        // room's own event when the title says so ("NY Phil Ensembles at Merkin Hall", 1 live row). That
        // row keeps today's `unknown`, so the cost is a lift it does not receive, never a promotion it
        // should not have.
        let actIsTheParty = OrganiserNaming.onlyTheActIsNamed(presenter: event.presenter)
            && !titleNamesTheRoom(event.title, venue: venue)
        let party = strings.party

        let isAgency = hasAgencySignal(haystack)
        let namesAnOrganisation = Self.namesAnOrganisation(party) && !isAgency

        // Self-produced two ways, and they mean the same thing about who is putting the show on: the
        // party named IS an organisation billing its own show, or NOBODY but the act is named, which
        // leaves the act as the only party there is. The second is a fact about the row, not a guess
        // about the name, so it holds for a soloist billed under her own name and for a small show
        // billed under its own title alike. Agency still wins over both: an agency-routed rental is the
        // dead zone whoever is billed, and that is the one direction this must not lift.
        let production: Production
        if isAgency { production = .agency }
        else if namesAnOrganisation || actIsTheParty { production = .selfProduced }
        else { production = .unknown }

        // Profile is NOT lifted the same way, deliberately. `strong` is a claim that this is a
        // substantial organisation, and a soloist's own name says nothing either way. Answering it from
        // the act line would be the classifier claiming more than it measured (L11), so a soloist stays
        // neutral and only an act that names an organisation can reach strong.
        let profile: Profile
        if isAgency { profile = .weak }
        else if namesAnOrganisation && hasStrongProfileSignal(haystack) { profile = .strong }
        else { profile = .neutral }

        let derivedPair = derived(discipline: discipline, production: production, profile: profile, venue: venue)

        let reachable = true

        return EventClassification(
            discipline: discipline,
            reachable: reachable,
            production: production,
            profile: profile,
            coverage: derivedPair.coverage,
            fitReason: derivedPair.fitReason
        )
    }

    // #1949: coverage and the reason are DERIVED from the other three axes, never merged alongside them.
    //
    // Once two sources can each contribute a different axis to one row (Dan's call, 2026-08-01), copying
    // either source's coverage or reason would describe a show neither of them saw: the reason is a
    // sentence about the whole classification, and coverage is a conclusion drawn from production and
    // profile. So they are recomputed from whatever the merge settled on. Shared with `classify` above
    // rather than spelled twice, so a row assembled by merging and a row read from one source cannot
    // disagree about what the same three axes imply.
    static func derived(discipline: Discipline, production: Production, profile: Profile,
                        venue: String?) -> (coverage: Coverage, fitReason: String) {
        let atWeill = matches(venue ?? "", "weill")
        let coverage: Coverage =
            (atWeill || (production == .selfProduced && profile == .strong)) ? .likelyUncovered : .unknown
        return (coverage,
                buildReason(production: production, profile: profile, coverage: coverage, discipline: discipline))
    }

    private static func buildReason(production: Production, profile: Profile, coverage: Coverage, discipline: Discipline) -> String {
        if production == .agency && profile == .weak {
            return "Agency-routed showcase rental, the dead zone that rarely converts."
        }
        // #1657: the genre word, or NOTHING when no genre was read. The raw enum value used to go
        // straight into the sentence, so 21 live rows read "Self-produced other group, a strong-fit
        // target" and one still read "choral" after #350 folded that genre away. `other` is the
        // classifier finding no genre word at all, so the honest sentence simply does not mention one:
        // "Self-produced group" is true, and naming the absence here would state twice what the row's own
        // genre line already says once.
        // #2733: from `.label`, which #1657 made the one place a genre is NAMED, rather than from
        // the stored raw value. Built from the raw value this sentence said "theater" while the
        // picker one line above it offered "Performing Arts": one genre under two names on the
        // same card, each reading fine alone (L118). Lowercased because it sits mid-sentence.
        let genre = discipline == .other ? "" : " \(discipline.label.lowercased())"
        if production == .selfProduced && profile == .strong {
            let where_ = coverage == .likelyUncovered ? ", likely without its own photographer" : ""
            return "Self-produced\(genre) group, a strong-fit target\(where_)."
        }
        if production == .selfProduced {
            return "Self-produced\(genre); worth a look once the fit is confirmed."
        }
        // LIVE-STORE-CLAIM verified=2026-07-26 measure="rows carrying the classifier catch-all fit reason before Phase 7 cleared them, and how many named a room versus a real producer"
        // #1600 (milestone 32 Phase 7.1): the catch-all sentence is GONE, and nothing replaces it. It
        // was the final fallback of this chain, so it carried every show that is neither agency-routed
        // nor self-produced: 499 rows on the live store, three quarters of the queue. Dan read it as
        // "Overture doesn't know who the producer is", which it never meant, and measured on the same
        // store it was accidentally right on 233 rows and flatly wrong on 176, with nothing on the card
        // to tell those apart. The row already hides an empty reason, so this collapses the line with no
        // new copy and no new render arm. CatchAllFitReasonMigration clears the rows already carrying it.
        return ""
    }
}
