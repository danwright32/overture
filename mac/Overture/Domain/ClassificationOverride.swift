import Foundation

// Pure helper: rebuilds a Ranker.Candidate from a Prospect's stored string fields and re-scores it.
// Used when Dan corrects a wrong genre, and by the scout and the Prep importer to re-derive a score
// from whatever the prospect now holds.
//
// #1533 removed the "substitute this dimension" parameters. Every caller wrote the corrected value onto
// the prospect first and then scored it, so the substitution arm was only ever passed nil in the app;
// scoring straight from the row leaves one path instead of two that could disagree.
//
// Any persisted Prospect is reachable (unreachable events are never inserted), so the
// rebuilt Candidate always uses reachable: true.
//
// String-to-enum defaults when a raw value doesn't match any case:
//   Production        -> .unknown
//   PriorRelationship -> .none
//   Profile           -> .neutral
//   Coverage          -> .unknown
//   Discipline        -> .other
enum ClassificationOverride {
    // #1669: the string-to-enum resolution moved onto Candidate itself so this and the masthead's
    // merit split share one implementation. #384's note still applies and is now enforced for both:
    // passedOnThisShow is carried through, or correcting a discipline would silently drop the penalty
    // on a show Dan already passed on and hand it back its old score.
    static func candidate(from p: Prospect) -> Candidate {
        Candidate(rawDiscipline: p.discipline, rawProduction: p.production,
                  rawPriorRelationship: p.priorRelationship, rawProfile: p.profile,
                  rawCoverage: p.coverage, passedOnThisShow: p.passedOnThisShow)
    }

    static func rescored(_ p: Prospect) -> FitResult {
        Ranker.scoreFit(candidate(from: p))
    }

    // Applies Dan's genre correction to a prospect in place: writes the discipline, sets the override
    // flag so no later scout reverts it, then recomputes fitScore and tier. Does NOT save the context;
    // caller owns that.
    //
    // #1533: production is deliberately NOT a parameter. It stays exactly as the scout guessed, and the
    // re-score reads it back off the prospect, so an agency row keeps its 2 point penalty through a genre
    // correction instead of being silently re-ranked as if its production were unknown.
    static func correct(_ p: Prospect, discipline: Discipline, now: Date) {
        p.discipline = discipline.rawValue
        p.classificationOverriddenByDan = true
        let result = rescored(p)
        p.fitScore = result.score
        p.tier = result.tier.rawValue
    }
}
