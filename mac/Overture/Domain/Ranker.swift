import Foundation

// Fit-score ranker. Pure, deterministic scoring of an already-classified candidate. Used to be
// kept identical to a TypeScript mirror (ranker.ts); that mirror was retired in #493 once the
// app was confirmed to scout natively, so RankerFixtureTests (fixtures/ranker/cases.json) is now
// this logic's only locked spec, not a cross-language drift guard. See PLAN.md section 4.

enum Production: String, Decodable, Sendable { case selfProduced = "self", agency, unknown }
enum Profile: String, Decodable, Sendable { case strong, neutral, weak }
enum Coverage: String, Decodable, Sendable { case likelyUncovered = "likely_uncovered", unknown, likelyCovered = "likely_covered" }
enum PriorRelationship: String, Decodable, Sendable {
    case booked
    case declinedByYou = "declined_by_you"
    case warm
    case lostSoft = "lost_soft"
    case contacted
    case lostHard = "lost_hard"
    case none
}
enum Discipline: String, Decodable, Sendable, CaseIterable {
    case dance, opera, theater, music, band, comedy, other
}
enum Tier: String, Decodable, Sendable { case high, longshot }

struct Candidate: Decodable, Sendable {
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
        switch r {
        case .booked: return 20
        case .declinedByYou: return 18
        case .warm: return 10
        case .lostSoft: return 3
        case .contacted: return 0   // #70: a bare send that got silence is not warm
        case .lostHard: return -20
        case .none: return 0
        }
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
    // #350: Choral folded into Music, merged at Choral's former score (Dan's call) rather than
    // demoting it to Music's old baseline. "other" (no discipline signal) is now the sole
    // baseline. Dance highest.
    static func disciplinePoints(_ d: Discipline) -> Int {
        switch d {
        case .dance: return 3
        case .opera, .theater: return 2
        case .music, .band, .comedy: return 1
        case .other: return 0
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
