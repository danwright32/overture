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
    // #384: Dan already passed on THIS show (same org, same venue). Its own axis, NOT a
    // priorRelationship value, because the two are orthogonal: he can have booked an org happily and
    // still not want their particular annual show. As a relationship it would just be outranked by
    // "booked" and never apply to the orgs he works with most.
    var passedOnThisShow: Bool = false

    // Spelled out because providing init(from:) below stops Swift synthesising these. A nested enum
    // does not suppress the memberwise init, so every existing Candidate(...) call site is unaffected.
    enum CodingKeys: String, CodingKey {
        case reachable, priorRelationship, production, profile, coverage, discipline, passedOnThisShow
    }
}

// Decoded in an EXTENSION so the memberwise init survives (declaring init(from:) in the body would
// suppress it). passedOnThisShow is decodeIfPresent, so every ranker fixture written before #384
// still decodes rather than throwing on a missing key.
extension Candidate {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reachable = try c.decode(Bool.self, forKey: .reachable)
        priorRelationship = try c.decode(PriorRelationship.self, forKey: .priorRelationship)
        production = try c.decode(Production.self, forKey: .production)
        profile = try c.decode(Profile.self, forKey: .profile)
        coverage = try c.decode(Coverage.self, forKey: .coverage)
        discipline = try c.decode(Discipline.self, forKey: .discipline)
        passedOnThisShow = try c.decodeIfPresent(Bool.self, forKey: .passedOnThisShow) ?? false
    }
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
        // #1362: a past decline is usually just an old date conflict, irrelevant to a future pitch.
        // Kept as a distinct status (it still exists in booking history) but weighted neutral, like a
        // cold lead, so it neither floats a declined show to the top nor auto-corrects a warm lead.
        case .declinedByYou: return 0
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
    // demoting it to Music's old baseline. "other" (no discipline signal) is the sole baseline.
    // Dance highest.
    //
    // #970 Phase 0 made `other` REACHABLE for the first time: the classifier used to fall back to
    // `.music`, so "no idea" scored 1 and this 0 applied to nothing. It stays 0 because Phase 0 also
    // taught the classifier real music words, which is what keeps the change invisible: every live row
    // that scores at or above the high-tier threshold carries a music word (piano, orchestra, concert)
    // and stays `.music`, so nothing is demoted. Only genuinely unreadable titles land here, and they
    // already score at or below 3. Do NOT "fix" this to 1 to hold scores still: it would shift every
    // case in the shared ranker fixture spec by a point for no reason.
    static func disciplinePoints(_ d: Discipline) -> Int {
        switch d {
        case .dance: return 3
        case .opera, .theater: return 2
        case .music, .band, .comedy: return 1
        case .other: return 0
        }
    }

    // #384: Dan already told us he doesn't want this show. A nudge below the high-fit cutoff (5), not
    // a burial (Dan's call): a typical strong show scores 9, so this lands it at 4, stopping it being
    // promoted while leaving it near the top of the longshots, where a change of heart next season
    // costs nothing. Deliberately much lighter than a hard loss (-20): his taste is not the same thing
    // as a client's rejection.
    static func passedPoints(_ passed: Bool) -> Int { passed ? -5 : 0 }

    static func scoreFit(_ c: Candidate) -> FitResult {
        let score = priorPoints(c.priorRelationship)
            + productionPoints(c.production)
            + profilePoints(c.profile)
            + coveragePoints(c.coverage)
            + disciplinePoints(c.discipline)
            + passedPoints(c.passedOnThisShow)
        let tier: Tier = score >= highTierThreshold ? .high : .longshot
        return FitResult(excluded: !c.reachable, score: score, tier: tier)
    }
}
