import Testing
import Foundation
@testable import Overture

private func candidate(
    reachable: Bool = true,
    prior: PriorRelationship = .none,
    production: Production = .unknown,
    profile: Profile = .neutral,
    coverage: Coverage = .unknown,
    discipline: Discipline = .other
) -> Candidate {
    Candidate(reachable: reachable, priorRelationship: prior, production: production,
              profile: profile, coverage: coverage, discipline: discipline)
}

@Suite("Ranker")
struct RankerTests {
    @Test func priorBookingDominatesEverything() {
        // A warm booked relationship outranks any cold prospect, and clears high tier.
        let r = Ranker.scoreFit(candidate(prior: .booked))
        #expect(r.score == 20)
        #expect(r.tier == .high)
    }

    @Test func declinedByYouIsNearlyAsHotAsBooked() {
        // Dan turned them down, almost always a date conflict: a strong shot next time.
        let r = Ranker.scoreFit(candidate(prior: .declinedByYou))
        #expect(r.score == 18)
        #expect(r.tier == .high)
    }

    @Test func warmIsAStrongBoost() {
        // A referral or expressed interest, no booking yet.
        let r = Ranker.scoreFit(candidate(prior: .warm))
        #expect(r.score == 10)
        #expect(r.tier == .high)
    }

    @Test func lostSoftRanksJustAboveAStranger() {
        // "Keep us in mind" — the door is open, a small nudge above a fresh org.
        #expect(Ranker.priorPoints(.lostSoft) == 3)
        #expect(Ranker.priorPoints(.lostSoft) > Ranker.priorPoints(.none))
    }

    @Test func coldContactIsNeutralNotWarm() {
        // #70: a bare send that got silence is not a warm prior relationship — it scores
        // the same as a never-contacted org, not a boost.
        #expect(Ranker.priorPoints(.contacted) == 0)
        #expect(Ranker.priorPoints(.contacted) == Ranker.priorPoints(.none))
    }

    @Test func lostHardIsHeavilyPenalizedButVisible() {
        // They said never: buried far below a stranger, but still scored (not removed).
        let r = Ranker.scoreFit(candidate(prior: .lostHard))
        #expect(r.score == -20)
        #expect(r.tier == .longshot)
    }

    @Test func deadZoneScoresNegativeAndStaysLongshot() {
        // Agency + weak + likely-covered: the dead zone.
        let r = Ranker.scoreFit(candidate(production: .agency, profile: .weak, coverage: .likelyCovered))
        #expect(r.score == -6)
        #expect(r.tier == .longshot)
    }

    @Test func strongSelfProducedDanceClearsHighTier() {
        let r = Ranker.scoreFit(candidate(production: .selfProduced, profile: .strong, coverage: .likelyUncovered, discipline: .dance))
        #expect(r.score == 9) // 2 + 2 + 2 + 3
        #expect(r.tier == .high)
    }

    // #350: Choral folded into Music, merged at Choral's former score (Dan's call) so
    // already-preferred disciplines aren't demoted; "other" (no discipline signal) is now the
    // sole baseline.
    @Test func disciplinePreferenceOrder() {
        #expect(Ranker.disciplinePoints(.dance) == 3)
        #expect(Ranker.disciplinePoints(.opera) == 2)
        #expect(Ranker.disciplinePoints(.theater) == 2)
        #expect(Ranker.disciplinePoints(.music) == 1)
        #expect(Ranker.disciplinePoints(.band) == 1)
        #expect(Ranker.disciplinePoints(.comedy) == 1)
        #expect(Ranker.disciplinePoints(.other) == 0)
    }

    @Test func unreachableIsExcludedRegardlessOfScore() {
        let r = Ranker.scoreFit(candidate(reachable: false, prior: .booked))
        #expect(r.excluded == true)
    }

    @Test func highTierThresholdBoundary() {
        // Exactly 5 is high; 4 is longshot.
        #expect(Ranker.scoreFit(candidate(production: .selfProduced, profile: .strong, discipline: .other)).score == 4)
        #expect(Ranker.scoreFit(candidate(production: .selfProduced, profile: .strong, discipline: .other)).tier == .longshot)
        #expect(Ranker.scoreFit(candidate(production: .selfProduced, profile: .strong, discipline: .music)).tier == .high)
    }
}

// Shared cross-language scoring fixture (#490). Ranker.swift is a hand port of ranker.ts (the app
// scouts natively; the TypeScript engine is a reference mirror, see docs/scout-runbook.md), so the
// two pure scoring functions need to agree even though neither reads the other's output at
// runtime. The SAME cases decoded here are decoded by src/lib/ranker.test.ts, so a one sided change
// to either side's point table fails whichever suite did not make the matching change.
@Suite("Ranker shared fixture")
struct RankerFixtureTests {
    private struct FixtureCase: Decodable {
        let description: String
        let candidate: Candidate
        let expectedExcluded: Bool
        let expectedScore: Int
        let expectedTier: Tier
    }

    private func loadCases() throws -> [FixtureCase] {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("fixtures/ranker/cases.json"))
        return try JSONDecoder().decode([FixtureCase].self, from: data)
    }

    @Test func everyFixtureCaseMatchesTheSharedSpec() throws {
        for testCase in try loadCases() {
            let result = Ranker.scoreFit(testCase.candidate)
            #expect(result.excluded == testCase.expectedExcluded, "\(testCase.description): excluded")
            #expect(result.score == testCase.expectedScore, "\(testCase.description): score")
            #expect(result.tier == testCase.expectedTier, "\(testCase.description): tier")
        }
    }
}
