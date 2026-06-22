import Testing
@testable import Overture

private func candidate(
    reachable: Bool = true,
    prior: PriorRelationship = .none,
    production: Production = .unknown,
    profile: Profile = .neutral,
    coverage: Coverage = .unknown,
    discipline: Discipline = .music
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

    @Test func disciplinePreferenceOrder() {
        #expect(Ranker.disciplinePoints(.dance) == 3)
        #expect(Ranker.disciplinePoints(.opera) == 2)
        #expect(Ranker.disciplinePoints(.theater) == 2)
        #expect(Ranker.disciplinePoints(.choral) == 1)
        #expect(Ranker.disciplinePoints(.music) == 0)
    }

    @Test func unreachableIsExcludedRegardlessOfScore() {
        let r = Ranker.scoreFit(candidate(reachable: false, prior: .booked))
        #expect(r.excluded == true)
    }

    @Test func highTierThresholdBoundary() {
        // Exactly 5 is high; 4 is longshot.
        #expect(Ranker.scoreFit(candidate(production: .selfProduced, profile: .strong, discipline: .music)).score == 4)
        #expect(Ranker.scoreFit(candidate(production: .selfProduced, profile: .strong, discipline: .music)).tier == .longshot)
        #expect(Ranker.scoreFit(candidate(production: .selfProduced, profile: .strong, discipline: .choral)).tier == .high)
    }
}
