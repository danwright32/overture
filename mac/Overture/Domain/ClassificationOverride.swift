import Foundation
import SwiftData

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
    // #1648: `now` decides one thing only, whether the row's contact answer has aged out. It is a
    // parameter rather than a `Date()` inside, so a test can pin it and so the expiry is evaluated at
    // the same instant as the badge's, rather than each reading the host clock separately (LESSONS L39).
    static func candidate(from p: Prospect, now: Date) -> Candidate {
        Candidate(rawDiscipline: p.discipline, rawProduction: p.production,
                  rawPriorRelationship: p.priorRelationship, rawProfile: p.profile,
                  rawCoverage: p.coverage, passedOnThisShow: p.passedOnThisShow,
                  // Read off the row, which is what makes the adjustment idempotent by construction.
                  // Nothing anywhere adds to or subtracts from a stored score.
                  contactRoute: p.contactRouteForScoring(now: now),
                  // #2622: and WHO the check found, read off the row for the same reason.
                  contactTier: p.contactTierForScoring(now: now))
    }

    static func rescored(_ p: Prospect, now: Date) -> FitResult {
        Ranker.scoreFit(candidate(from: p, now: now))
    }

    // Applies Dan's genre correction to a prospect in place: writes the discipline, sets the override
    // flag so no later scout reverts it, then recomputes fitScore and tier. Does NOT save the context;
    // caller owns that.
    //
    // #1533: production is deliberately NOT a parameter. It stays exactly as the scout guessed, and the
    // re-score reads it back off the prospect, so an agency row keeps its 2 point penalty through a genre
    // correction instead of being silently re-ranked as if its production were unknown.
    // #2688: `context` is optional and defaulted, so every existing caller is unchanged, and the
    // correction is RECORDED before the write, which is the only moment the classifier's own answer is
    // still knowable. `classificationOverriddenByDan` is a bare boolean, and re-reading the row later
    // would answer with whatever the rules say then.
    static func correct(_ p: Prospect, discipline: Discipline, now: Date,
                        in context: ModelContext? = nil) {
        if let context { GenreCorrection.record(p, danSaid: discipline, now: now, in: context) }
        // #1658: through the one writer, so Dan's own correction cannot be the thing that removes the
        // row he just corrected.
        GenreVisibility.write(discipline, to: p)
        p.classificationOverriddenByDan = true
        let result = rescored(p, now: now)
        p.fitScore = result.score
        p.tier = result.tier.rawValue
        // #1657: the reason is a sentence ABOUT the genre, so a correction that left it alone produced a
        // card whose line says one genre and whose reason names another. The genre editor is one tap from
        // that line (#1662), which makes it the easiest place in the app to reach that state.
        //
        // Through the same `derived` every other writer uses, and coverage rides along with it because the
        // two are one pair drawn from one set of axes (#1949). Coverage does not depend on the genre, so
        // this is a no-op for it, and separating them is how they would come to describe different rows.
        let derived = EventClassifier.derived(discipline: discipline,
                                              production: Production(rawValue: p.production) ?? .unknown,
                                              profile: Profile(rawValue: p.profile) ?? .neutral,
                                              venue: p.venue)
        // An empty reason stays empty: #1600 retired the catch-all sentence deliberately, and a genre
        // correction is not the moment to put one back.
        if !p.fitReason.isEmpty { p.fitReason = derived.fitReason }
    }
}
