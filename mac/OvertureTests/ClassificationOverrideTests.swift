import Testing
import Foundation
@testable import Overture

@Suite("Classification override re-score")
struct ClassificationOverrideTests {
    private func prospect(discipline: String, production: String, prior: String = "none",
                          profile: String = "strong", coverage: String = "likely_uncovered") -> Prospect {
        Prospect(naturalKey: "k", groupName: "G", discipline: discipline, venue: "V",
                 performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: prior, production: production, profile: profile,
                 coverage: coverage, fitScore: 0, tier: "longshot", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .approved)
    }

    @Test func rescoringWithCorrectedDisciplineChangesFit() {
        // music (baseline, 0 pts) corrected to dance (+3 pts) raises the score.
        let p = prospect(discipline: "music", production: "self")
        let before = ClassificationOverride.rescored(p, discipline: nil, production: nil)
        let after = ClassificationOverride.rescored(p, discipline: .dance, production: nil)
        #expect(after.score > before.score)
    }

    @Test func nilArgsUseTheProspectsCurrentValues() {
        let p = prospect(discipline: "dance", production: "self")
        let r = ClassificationOverride.rescored(p, discipline: nil, production: nil)
        let direct = Ranker.scoreFit(Candidate(reachable: true, priorRelationship: .none,
            production: .selfProduced, profile: .strong, coverage: .likelyUncovered, discipline: .dance))
        #expect(r == direct)
    }
}
