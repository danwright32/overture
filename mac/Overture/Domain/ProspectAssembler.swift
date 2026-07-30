import Foundation

// Combines a classified event with its repeat-client verdict and the blocked-date
// set into a final scored prospect, or a "skip" for anything that should never
// surface (blocked date, DNC-suppressed, or unreachable). Ported from
// assembleProspect.ts. The score and tier come from the ranker.

struct AssembledProspect: Equatable, Sendable {
    var groupName: String
    // The presenter EventClassifier actually read (its haystack is title + presenter). Kept, not
    // dropped, so a later classifier or scoring change can be replayed over the store instead of
    // being forward-only forever. #980 could not be: it fixed the classifier and the input that
    // produced every existing row was already gone.
    var presenter: String?
    // #1788: the run named the ROOM as the presenter and the boundary drained it, so this row's blank
    // presenter is a discarded name rather than a page that never said. Carried through here because a
    // fact about what was thrown away is useless if it stops at the guard.
    var presenterWasTheRoom: Bool? = nil
    // #970: where the page said the show is, verbatim. Carried through unresolved; EventPlace judges it
    // at queue time, so the store keeps the page's own words and the rule stays changeable.
    var location: String?
    var discipline: String
    var venue: String?
    var performanceDate: String?
    // #1174: the source's production id, carried through so RunGrouping can collapse every night of a
    // multi-night run (VenueTix's shared seriesId) into one prospect. Transient: it feeds RunGrouping and
    // is never persisted on the Prospect, so no store migration. Nil for sources that publish no such id.
    var seriesId: String? = nil
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
    var runNights: [String] = []          // #1523: the nights the run plays, for the conflict check
    // #901: the day of this run Dan cannot work, if any. Set by ScoutService.apply once the run is known
    // (a conflict is a fact about the whole run, not about its opening night), never by `decide`.
    var conflictKey: String? = nil
    // #771: which source surfaced this. Set by ScoutService.apply from the run it belongs to, never by
    // `decide`, which stays pure and knows nothing about sources.
    var sourceIds: [String] = []
}

// #901: `blocked` is gone from here. A day Dan cannot work no longer drops the show (he asked to see it,
// flagged, and decide himself), and the check could never have been correct at this level anyway: this
// runs per EVENT, before RunGrouping has collapsed the nights, so `runEndDate` does not exist yet and a
// run whose LATER nights collide could not be seen at all. It now happens in ScoutService.apply, at the
// run, next to the #798 upcoming-only guard, which lives there for exactly the same reason.
enum SkipReason: String, Equatable, Sendable { case suppressed, unreachable }

enum ProspectDecision: Equatable, Sendable {
    case prospect(AssembledProspect)
    case skip(SkipReason)
}

enum ProspectAssembler {
    static func decide(
        event: ExtractedEvent,
        classification c: EventClassification,
        verdict: MatchVerdict
    ) -> ProspectDecision {
        if verdict.suppressed { return .skip(.suppressed) }

        let candidate = Candidate(
            reachable: c.reachable,
            priorRelationship: verdict.relationship,
            production: c.production,
            profile: c.profile,
            coverage: c.coverage,
            discipline: c.discipline,
            passedOnThisShow: verdict.passedOnThisShow,
            // #1648: always unchecked here. This scores an ExtractedEvent, which by definition nobody
            // has researched contacts for yet; there is no Prospect in scope to carry an answer. A show
            // already in the store keeps its own, because the scout's Step B re-scores from the ROW
            // rather than copying this number (#1648 Phase A1).
            contactRoute: .unchecked
        )
        let fit = Ranker.scoreFit(candidate)
        if fit.excluded { return .skip(.unreachable) }

        return .prospect(AssembledProspect(
            // Decode entities for the displayed name (issue #25); the key canonicalizes
            // independently, so matching is unaffected either way. #1087: the name is
            // ExtractedEventGuard's derived name (title, else presenter, else venue), not the raw title,
            // so a titleless-but-genuine show the guard rescued surfaces named rather than blank. The
            // guard is the single authority on the name; only usable events reach here, so the fallback
            // is unreachable in practice and exists only to keep the type non-optional.
            groupName: Prospect.decodeHTMLEntities(ExtractedEventGuard.displayName(for: event) ?? event.title),
            presenter: event.presenter,
            presenterWasTheRoom: event.presenterWasTheRoom,
            // #1744: every path into the store passes through here, so this is where a show gets its
            // place: the page's own words when it published any, and otherwise whatever the venue text,
            // the tour-title convention or the shared venue table can say for certain (EventLocationFill).
            //
            // Deliberately HERE and not upstream on the ExtractedEvent itself. SourcePlacement.placedCount
            // reads the raw `location` off the same events to measure whether a SOURCE names places, which
            // is #970's drift detector for a run that has silently stopped reporting them. Filling the
            // field before that count would tell it every source places perfectly and switch the detector
            // off, so the wire keeps the page's own answer and only the stored prospect gets the fill.
            location: EventLocationFill.location(for: event),
            discipline: c.discipline.rawValue,
            venue: event.venue,
            performanceDate: event.performanceDate,
            seriesId: event.seriesId,
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
            // A confident org match is exactly one that resolved to a real relationship: matchRelationship
            // returns .none for both no-match and a merely-possible (fuzzy) match, neither of which
            // outranks a standing performer-match correction (#750).
            orgMatchConfident: verdict.relationship != .none,
            passedOnThisShow: verdict.passedOnThisShow
        ))
    }
}
