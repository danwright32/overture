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
