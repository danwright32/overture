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

    private static let agencySignal =
        #"competition|winners|rising stars|invitational|young artists?|debut|showcase|celebrations international|concerts international|distinguished concerts|mid.?america|national concerts|jam generation|tour|gala of"#
    private static let producerSignal =
        #"choir|chorus|chorale|choral|orchestra|philharmonic|ensemble|consort|school|academy|conservatory|university|college|institute|theatre|theater|company|opera|ballet|dance|society|center|centre|foundation|church|temple|youth|community|collective|quartet|quintet|band"#
    private static let strongProfile =
        #"choir|chorus|chorale|choral|school|academy|conservatory|youth|community|children|ensemble|opera|ballet|dance|theatre|theater|cultural|university|college|church|temple"#

    // #2504: the act line with the room's own name taken out of it, so a venue quoted inside an act
    // billing cannot be read as the organisation behind the show.
    //
    // Removes the venue string as a whole and nothing cleverer. A room whose name is echoed only in part
    // ("in the theatre or the tavern", on a Jalopy Theatre row) still slips through, which is a smaller
    // and rarer miss than a word list would create in the other direction: several real acts ARE named
    // for a place, and stripping every venue word would silently unname them.
    private static func withoutTheRoomsOwnName(_ title: String, venue: String) -> String {
        let room = venue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard room.count >= 4 else { return title }   // too short to be a name; never worth removing
        return title.replacingOccurrences(of: room, with: " ", options: [.caseInsensitive])
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

    static func classify(_ event: ExtractedEvent) -> EventClassification {
        let presenter = event.presenter ?? ""
        let venue = event.venue ?? ""
        let haystack = "\(event.title) \(presenter)"
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
        let actIsTheParty = OrganiserNaming.onlyTheActIsNamed(presenter: event.presenter)
        // The room is the one organisation on the page that is certainly NOT the producer (#1787, #2259),
        // and several live rows repeat the room's own name inside the act line ("LOL! The Players Theatre
        // Short Play Festival", four rows). Reading "Theatre" there as an organisation would promote the
        // venue by the back door, on a row whose whole problem is that nobody else was named. Only ever
        // removed from the ACT text: a presenter is a name somebody billed, not an echo of the room.
        let party = actIsTheParty ? withoutTheRoomsOwnName(event.title, venue: venue) : presenter

        let isAgency = matches(haystack, agencySignal)
        let namesAnOrganisation = matches(party, producerSignal) && !isAgency

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
        else if namesAnOrganisation && matches(haystack, strongProfile) { profile = .strong }
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
        let genre = discipline == .other ? "" : " \(discipline.rawValue)"
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
