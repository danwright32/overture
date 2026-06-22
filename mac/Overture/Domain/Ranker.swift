import Foundation

// Fit-score ranker, ported from the engine's ranker.ts (kept identical so the native
// scout scores exactly as the TypeScript tests specify). Pure, deterministic scoring
// of an already-classified candidate. See PLAN.md section 4.

enum Production: String, Sendable { case selfProduced = "self", agency, unknown }
enum Profile: String, Sendable { case strong, neutral, weak }
enum Coverage: String, Sendable { case likelyUncovered = "likely_uncovered", unknown, likelyCovered = "likely_covered" }
enum PriorRelationship: String, Sendable { case booked, contacted, none }
enum Discipline: String, Sendable {
    case dance, opera, theater, choral, music, band, comedy, other
}
enum Tier: String, Sendable { case high, longshot }

struct Candidate: Sendable {
    var reachable: Bool
    var priorRelationship: PriorRelationship
    var production: Production
    var profile: Profile
    var coverage: Coverage
    var discipline: Discipline
}

struct FitResult: Equatable, Sendable {
    var excluded: Bool
    var score: Int
    var tier: Tier
}

enum Ranker {
    // A strong cold prospect clears this; a flat-neutral or dead-zone one does not.
    static let highTierThreshold = 5

    // Prior warm relationship is the top weight: a prior booking dominates every
    // other signal combined. A prior cold contact is only a mild nudge.
    static func priorPoints(_ r: PriorRelationship) -> Int {
        switch r { case .booked: return 20; case .contacted: return 3; case .none: return 0 }
    }
    static func productionPoints(_ p: Production) -> Int {
        switch p { case .selfProduced: return 2; case .unknown: return 0; case .agency: return -2 }
    }
    static func profilePoints(_ p: Profile) -> Int {
        switch p { case .strong: return 2; case .neutral: return 0; case .weak: return -2 }
    }
    static func coveragePoints(_ c: Coverage) -> Int {
        switch c { case .likelyUncovered: return 2; case .unknown: return 0; case .likelyCovered: return -2 }
    }
    // Music is the baseline; every other discipline is preferred. Dance highest.
    static func disciplinePoints(_ d: Discipline) -> Int {
        switch d {
        case .dance: return 3
        case .opera, .theater: return 2
        case .choral, .band, .comedy: return 1
        case .music, .other: return 0
        }
    }

    static func scoreFit(_ c: Candidate) -> FitResult {
        let score = priorPoints(c.priorRelationship)
            + productionPoints(c.production)
            + profilePoints(c.profile)
            + coveragePoints(c.coverage)
            + disciplinePoints(c.discipline)
        let tier: Tier = score >= highTierThreshold ? .high : .longshot
        return FitResult(excluded: !c.reachable, score: score, tier: tier)
    }
}
