import Foundation

// Combines a classified event with its repeat-client verdict and the blocked-date
// set into a final scored prospect, or a "skip" for anything that should never
// surface (blocked date, DNC-suppressed, or unreachable). Ported from
// assembleProspect.ts. The score and tier come from the ranker.

struct AssembledProspect: Equatable, Sendable {
    var groupName: String
    var discipline: String
    var venue: String?
    var performanceDate: String?
    var sourceListingURL: String?
    var websiteURL: String?
    var reachable: Bool
    var priorRelationship: String
    var production: String
    var profile: String
    var coverage: String
    var fitScore: Int
    var tier: String
    var fitReason: String
    var matchedClientName: String?
    var downbeatClientId: String?
    var possibleMatchSource: String?
    var possibleMatchName: String?
    var confidence: String
    // Did the ORG-name match resolve to a real relationship this run (#750)? Threaded through
    // explicitly rather than inferred from `priorRelationship != "none"`, because ScoutService.apply
    // has to tell "the org matched nothing" apart from "the org matched nothing, but a performer
    // match already corrected this prospect and must not be reverted", and a string comparison on a
    // field the guard is itself protecting cannot answer that.
    var orgMatchConfident: Bool = false
    // #384: Dan passed on this exact show before (same org, same venue), so it carries a fit penalty.
    var passedOnThisShow: Bool = false
    var runEndDate: String? = nil
    var partOfRelatedRun: Bool = false
    var runSourceURLs: [String] = []
    // #771: which source surfaced this. Set by ScoutService.apply from the run it belongs to, never by
    // `decide`, which stays pure and knows nothing about sources.
    var sourceIds: [String] = []
}

enum SkipReason: String, Equatable, Sendable { case blocked, suppressed, unreachable }

enum ProspectDecision: Equatable, Sendable {
    case prospect(AssembledProspect)
    case skip(SkipReason)
}

enum ProspectAssembler {
    static func isBlockedDate(_ date: String?, _ blocked: Set<String>) -> Bool {
        guard let date else { return false }
        return blocked.contains(date)
    }

    static func decide(
        event: ExtractedEvent,
        classification c: EventClassification,
        verdict: MatchVerdict,
        blocked: Set<String>
    ) -> ProspectDecision {
        if isBlockedDate(event.performanceDate, blocked) { return .skip(.blocked) }
        if verdict.suppressed { return .skip(.suppressed) }

        let candidate = Candidate(
            reachable: c.reachable,
            priorRelationship: verdict.relationship,
            production: c.production,
            profile: c.profile,
            coverage: c.coverage,
            discipline: c.discipline,
            passedOnThisShow: verdict.passedOnThisShow
        )
        let fit = Ranker.scoreFit(candidate)
        if fit.excluded { return .skip(.unreachable) }

        return .prospect(AssembledProspect(
            // Decode entities for the displayed name (issue #25); the key canonicalizes
            // independently, so matching is unaffected either way.
            groupName: Prospect.decodeHTMLEntities(event.title),
            discipline: c.discipline.rawValue,
            venue: event.venue,
            performanceDate: event.performanceDate,
            sourceListingURL: event.sourceUrl,
            websiteURL: nil,
            reachable: c.reachable,
            priorRelationship: verdict.relationship.rawValue,
            production: c.production.rawValue,
            profile: c.profile.rawValue,
            coverage: c.coverage.rawValue,
            fitScore: fit.score,
            tier: fit.tier.rawValue,
            fitReason: c.fitReason,
            matchedClientName: verdict.matchedClientName,
            downbeatClientId: verdict.downbeatClientId,
            possibleMatchSource: verdict.possible?.source,
            possibleMatchName: verdict.possible?.name,
            confidence: c.confidence.rawValue,
            // A confident org match is exactly one that resolved to a real relationship: matchRelationship
            // returns .none for both no-match and a merely-possible (fuzzy) match, neither of which
            // outranks a standing performer-match correction (#750).
            orgMatchConfident: verdict.relationship != .none,
            passedOnThisShow: verdict.passedOnThisShow
        ))
    }
}
