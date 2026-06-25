import Foundation

// Pure helper: rebuilds a Ranker.Candidate from a Prospect's stored string fields and
// re-scores it. Used when Dan corrects a wrong discipline or production classification.
// nil discipline/production means "use the prospect's current value"; non-nil substitutes.
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
    static func candidate(from p: Prospect, discipline: Discipline?, production: Production?) -> Candidate {
        let resolvedDiscipline = discipline ?? Discipline(rawValue: p.discipline) ?? .other
        let resolvedProduction = production ?? Production(rawValue: p.production) ?? .unknown
        let priorRelationship = PriorRelationship(rawValue: p.priorRelationship) ?? .none
        let profile = Profile(rawValue: p.profile) ?? .neutral
        let coverage = Coverage(rawValue: p.coverage) ?? .unknown
        return Candidate(
            reachable: true,
            priorRelationship: priorRelationship,
            production: resolvedProduction,
            profile: profile,
            coverage: coverage,
            discipline: resolvedDiscipline
        )
    }

    static func rescored(_ p: Prospect, discipline: Discipline?, production: Production?) -> FitResult {
        Ranker.scoreFit(candidate(from: p, discipline: discipline, production: production))
    }
}
