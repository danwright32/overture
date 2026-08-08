import Testing
import Foundation

private func candidate(
    reachable: Bool = true,
    prior: PriorRelationship = .none,
    production: Production = .unknown,
    profile: Profile = .neutral,
    coverage: Coverage = .unknown,
    discipline: Discipline = .other,
    contactRoute: ContactRoute = .unchecked
) -> Candidate {
    Candidate(reachable: reachable, priorRelationship: prior, production: production,
              profile: profile, coverage: coverage, discipline: discipline,
              passedOnThisShow: false, contactRoute: contactRoute)
}

// #1648: whether Dan can reach anybody about a show is a scoring axis, not a second decoration on the
// card. Weights are Dan's, 2026-07-28, chosen against the measured live distribution: scores pile up
// on a few values (58 high rows sit at exactly 8, 280 longshots at exactly 0), so a penalty of 4 or a
// bump of 5 crosses a cliff and reshapes the whole queue. These sit deliberately short of both.
@Suite("Ranker: the contact route axis")
struct RankerContactRouteTests {
    @Test func aFoundEmailLiftsAShowAndAFormLiftsItLess() {
        // other 0 + self 2 + strong 2 + uncovered 2 = 6 before any contact answer.
        let base = candidate(production: .selfProduced, profile: .strong, coverage: .likelyUncovered)
        #expect(Ranker.scoreFit(base).score == 6)
        #expect(Ranker.scoreFit(candidate(production: .selfProduced, profile: .strong,
                                          coverage: .likelyUncovered, contactRoute: .emailFound)).score == 8)
        #expect(Ranker.scoreFit(candidate(production: .selfProduced, profile: .strong,
                                          coverage: .likelyUncovered, contactRoute: .contactFormOnly)).score == 7)
    }

    // Something was found, but it is a front desk or a generic inbox. It is not evidence Dan can reach
    // the act, so it earns nothing rather than a consolation point.
    @Test func aGenericInboxEarnsNothing() {
        #expect(Ranker.scoreFit(candidate(contactRoute: .weakContactOnly)).score
                == Ranker.scoreFit(candidate(contactRoute: .unchecked)).score)
    }

    // The load-bearing guard. 536 of the 559 untriaged shows have never been checked, and a show must
    // never be penalised for a question nobody asked it.
    @Test func aShowNobodyHasCheckedIsNeitherHelpedNorPunished() {
        let unchecked = candidate(prior: .warm, discipline: .dance, contactRoute: .unchecked)
        #expect(Ranker.scoreFit(unchecked).score == 13)   // warm 10 + dance 3, nothing added or taken
        #expect(Ranker.scoreFit(unchecked).tier == .high)
    }

    // Dan's rule, as far as a score can carry it: "it's not a high fit if I can't email anybody about
    // it." A dead end costs 5, so an ordinary strong show falls out of high fit on its own.
    @Test func aDeadEndDropsAnOrdinaryStrongShowOutOfHighFit() {
        let deadEnd = candidate(production: .selfProduced, profile: .strong, coverage: .likelyUncovered,
                                discipline: .music, contactRoute: .noEmailFound)
        // music 1 + self 2 + strong 2 + uncovered 2 = 7, less 5 = 2.
        #expect(Ranker.scoreFit(deadEnd).score == 2)
        #expect(Ranker.scoreFit(deadEnd).tier == .longshot)
    }

    // And the deliberate limit of that rule (Dan's call, 2026-07-28: the penalty alone, no hard tier
    // floor). The check looks for a PUBLIC address; a past client's details are already in Downbeat, so
    // a booked show is not thrown out of high fit because the web turned up nothing.
    @Test func aDeadEndDoesNotThrowAPastClientOutOfHighFit() {
        let booked = candidate(prior: .booked, production: .selfProduced, profile: .strong,
                               coverage: .likelyUncovered, discipline: .dance, contactRoute: .noEmailFound)
        #expect(Ranker.scoreFit(booked).score == 24)   // 29 less 5
        #expect(Ranker.scoreFit(booked).tier == .high)
    }

    // The axis must be applied by SUBSTITUTION, never by arithmetic on the stored score, or a row
    // re-scored twice would drift. Scoring the same candidate repeatedly is the cheapest proof.
    @Test func scoringTheSameShowTwiceGivesTheSameAnswer() {
        let c = candidate(discipline: .opera, contactRoute: .emailFound)
        #expect(Ranker.scoreFit(c).score == Ranker.scoreFit(c).score)
        #expect(Ranker.scoreFit(c).score == 4)   // opera 2 + email 2
    }
}

@Suite("Ranker")
struct RankerTests {
    @Test func priorBookingDominatesEverything() {
        // A warm booked relationship outranks any cold prospect, and clears high tier.
        let r = Ranker.scoreFit(candidate(prior: .booked))
        #expect(r.score == 20)
        #expect(r.tier == .high)
    }

    @Test func declinedByYouIsNeutralLikeAColdLead() {
        // #1362: a past decline (usually just an old date conflict) is irrelevant to a future pitch, so
        // it neither boosts nor penalizes, scoring 0 like a cold lead rather than nearly as hot as booked.
        let r = Ranker.scoreFit(candidate(prior: .declinedByYou))
        #expect(r.score == 0)
        #expect(r.tier == .longshot)
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
    // already-preferred disciplines aren't demoted.
    @Test func disciplinePreferenceOrder() {
        #expect(Ranker.disciplinePoints(.dance) == 3)
        #expect(Ranker.disciplinePoints(.opera) == 2)
        #expect(Ranker.disciplinePoints(.theater) == 2)
        #expect(Ranker.disciplinePoints(.music) == 1)
        #expect(Ranker.disciplinePoints(.band) == 1)
        #expect(Ranker.disciplinePoints(.comedy) == 1)
    }

    // #970 Phase 0. `.other` scored 0 on the theory that it was the no-signal baseline, but until Phase
    // 0 the classifier could never return it: no-signal rows fell back to `.music` and scored 1. Making
    // `.other` reachable therefore risked re-scoring live rows as a side effect of a bug fix. It does
    // not, and this test pins the reason: the row that sits exactly on the high-tier threshold of 5
    // ("Anna Pierre, Piano Virgile Roche, Piano") says "Piano", so the music vocabulary Phase 0 added
    // keeps it `.music` and keeps its point. Every live row scoring at or above 5 carries a music word.
    // Only genuinely unreadable titles reach `.other`, and they already score at or below 3, so no row
    // changes tier. If this ever goes red, a real prospect is being demoted by a classifier change and
    // Dan has to be asked, not accommodated.
    @Test func onlyUnreadableTitlesPayTheOtherBaseline() {
        #expect(Ranker.disciplinePoints(.other) == 0)
        #expect(EventClassifier.classify(ExtractedEvent(
            title: "Anna Pierre, Piano Virgile Roche, Piano", presenter: nil,
            venue: "Weill Recital Hall", performanceDate: "2026-06-25", sourceUrl: nil
        )).discipline == .music)
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

// Locked scoring-ladder spec (#490). Used to also be decoded by a TypeScript mirror
// (ranker.ts/ranker.test.ts) so a one-sided change to either side's point table would fail
// whichever suite didn't make the matching change; that mirror was retired in #493 once the app
// was confirmed to scout natively. This suite is now Ranker.swift's only locked spec, not a
// cross-language drift guard (see fixtures/ranker/README.md).
@Suite("Ranker locked fixture")
struct RankerFixtureTests {
    private struct FixtureCase: Decodable {
        let description: String
        let candidate: Candidate
        let expectedExcluded: Bool
        let expectedScore: Int
        let expectedTier: Tier
    }

    private func loadCases() throws -> [FixtureCase] {
        let repoRoot = RepoRoot.url
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
