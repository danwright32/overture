import Foundation

// Rule-based event classifier, ported from the engine's classifyEvent.ts. Turns a
// raw extracted calendar event into the ranker's classification inputs from simple
// signals (presenter, venue, title keywords). Ambiguous events are flagged
// `.uncertain` for an optional AI refine pass (issue #30).

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
}

enum Confidence: String, Sendable { case confident, uncertain }

struct EventClassification: Equatable, Sendable {
    var discipline: Discipline
    var reachable: Bool
    var production: Production
    var profile: Profile
    var coverage: Coverage
    var fitReason: String
    var confidence: Confidence
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

        let confidence: Confidence =
            (production == .unknown || (production == .selfProduced && profile == .neutral)) ? .uncertain : .confident

        return EventClassification(
            discipline: discipline,
            reachable: reachable,
            production: production,
            profile: profile,
            coverage: coverage,
            fitReason: buildReason(production: production, profile: profile, coverage: coverage, discipline: discipline),
            confidence: confidence
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
        return "Unclear producer; needs a closer look before pitching."
    }
}
