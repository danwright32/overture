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
        if matches(text, #"\b(choir|chorus|chorale|choral|voices|singers|cantata|vocal)\b"#) { return .choral }
        if matches(text, #"\b(band|wind ensemble|brass|jazz band|marching)\b"#) { return .band }
        if matches(text, #"\b(comedy|comedian|stand.?up|improv)\b"#) { return .comedy }
        return .music
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
