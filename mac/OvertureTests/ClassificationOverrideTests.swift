import Testing
import Foundation

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
        let before = ClassificationOverride.rescored(p, now: Date())
        p.discipline = "dance"
        #expect(ClassificationOverride.rescored(p, now: Date()).score > before.score)
    }

    @Test func theCandidateIsBuiltFromTheProspectsOwnValues() {
        let p = prospect(discipline: "dance", production: "self")
        let r = ClassificationOverride.rescored(p, now: Date())
        let direct = Ranker.scoreFit(Candidate(reachable: true, priorRelationship: .none,
            production: .selfProduced, profile: .strong, coverage: .likelyUncovered, discipline: .dance,
            passedOnThisShow: false, contactRoute: .unchecked))
        #expect(r == direct)
    }

    @Test func correctingDisciplineSetsFlagsAndRerank() {
        let p = prospect(discipline: "music", production: "self")
        let before = p.fitScore
        ClassificationOverride.correct(p, discipline: .dance, now: Date())
        #expect(p.discipline == "dance")
        #expect(p.classificationOverriddenByDan == true)
        #expect(p.fitScore > before)
    }

    // #1533: production type is no longer Dan's to set. A genre correction must leave whatever the
    // scout guessed exactly as it found it, rather than writing a value he was never asked for.
    @Test func correctingTheGenreLeavesTheScoutsProductionGuessAlone() {
        for guess in ["self", "agency", "unknown"] {
            let p = prospect(discipline: "music", production: guess)
            ClassificationOverride.correct(p, discipline: .opera, now: Date())
            #expect(p.discipline == "opera")
            #expect(p.production == guess)
        }
    }

    // The re-score has to read the UNCHANGED production back off the prospect, or a corrected genre
    // would silently re-rank the show as if its production were the enum's default. An agency row
    // carries a 2 point penalty; losing it would float a dead-zone showcase up the queue.
    @Test func theRescoreKeepsTheProductionPenaltyOnAnAgencyRow() {
        let agency = prospect(discipline: "music", production: "agency")
        let selfProduced = prospect(discipline: "music", production: "self")
        ClassificationOverride.correct(agency, discipline: .opera, now: Date())
        ClassificationOverride.correct(selfProduced, discipline: .opera, now: Date())
        #expect(agency.fitScore == selfProduced.fitScore - 4)
    }
}
