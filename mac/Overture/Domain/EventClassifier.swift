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

    private static func detectDiscipline(_ text: String) -> Discipline {
        if matches(text, #"\b(dance|ballet|balletto|tap|choreograph|nutcracker)\b"#) { return .dance }
        if matches(text, #"\b(opera|operetta)\b"#) { return .opera }
        // "play"/"musical" are too common in names to be reliable theater signals.
        if matches(text, #"\b(theatre|theater|drama|cabaret|playhouse)\b"#) { return .theater }
        // #350: Choral folded into Music; the keyword signal still disambiguates against
        // band/comedy checks below, it just no longer produces a separate discipline bucket.
        if matches(text, #"\b(choir|chorus|chorale|choral|voices|singers|cantata|vocal)\b"#) { return .music }
        if matches(text, #"\b(band|wind ensemble|brass|jazz band|marching)\b"#) { return .band }
        if matches(text, #"\b(comedy|comedian|stand.?up|improv)\b"#) { return .comedy }
        // #970 Phase 0. Checked last, because these words are weaker signals than the ones above and
        // must lose to them: "Opera in Concert" is opera, "Playhouse Orchestra Night" is theater.
        // Deliberately NOT here: "musical" (a theater word, already refused as a theater signal above)
        // and "performance"/"artist", which name no discipline at all. `music` is bounded so it cannot
        // match inside "musical".
        if matches(text, #"\b(music|orchestra|philharmoni\w*|symphon\w*|piano|pianist|violin\w*|viola|cello|cellist|flute|clarinet|trumpet|harpsichord|guitar|recital|concerto|sonata|quartet|quintet|octet|sextet|septet|trio|chamber|camerata|conservatory|soprano|tenor|baritone|mezzo|jazz|blues|bluegrass|folk|composer|conductor|concert|song|songs|melodies|sings)\b"#) { return .music }
        return .other
    }

    static func classify(_ event: ExtractedEvent) -> EventClassification {
        let presenter = event.presenter ?? ""
        let venue = event.venue ?? ""
        let haystack = "\(event.title) \(presenter)"
        let discipline = detectDiscipline(haystack)

        let isAgency = matches(haystack, agencySignal)
        let isProducer = !presenter.isEmpty && matches(presenter, producerSignal) && !isAgency

        let production: Production = isAgency ? .agency : (isProducer ? .selfProduced : .unknown)

        let profile: Profile
        if isAgency { profile = .weak }
        else if isProducer && matches(haystack, strongProfile) { profile = .strong }
        else { profile = .neutral }

        let atWeill = matches(venue, "weill")
        let coverage: Coverage =
            (atWeill || (production == .selfProduced && profile == .strong)) ? .likelyUncovered : .unknown

        let reachable = true

        return EventClassification(
            discipline: discipline,
            reachable: reachable,
            production: production,
            profile: profile,
            coverage: coverage,
            fitReason: buildReason(production: production, profile: profile, coverage: coverage, discipline: discipline)
        )
    }

    private static func buildReason(production: Production, profile: Profile, coverage: Coverage, discipline: Discipline) -> String {
        if production == .agency && profile == .weak {
            return "Agency-routed showcase rental, the dead zone that rarely converts."
        }
        if production == .selfProduced && profile == .strong {
            let where_ = coverage == .likelyUncovered ? ", likely without its own photographer" : ""
            return "Self-produced \(discipline.rawValue) group, a strong-fit target\(where_)."
        }
        if production == .selfProduced {
            return "Self-produced \(discipline.rawValue); worth a look once the fit is confirmed."
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
