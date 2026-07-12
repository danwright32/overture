import Testing
import Foundation
import SwiftData
@testable import Overture

// #384: Dan passes on a show ("Don't want to shoot this"), the identical recurring show comes back
// next season, and it scores exactly as high as before, so the app pitches him the same thing he
// already turned down.
//
// The key design decision, and the reason this is not just a new PriorRelationship value: the pass is
// ORTHOGONAL to the relationship. Dan can have booked an org happily and still not want this
// particular annual show of theirs. As a relationship value, "passed" would simply be outranked by
// "booked" (20 beats a negative every time) and the penalty would silently never apply to exactly
// the orgs he works with most. It is a separate axis, applied ON TOP of whatever relationship the org
// has.
//
// The venue is what makes the pass safe to remember at all. #351 deliberately recorded NOTHING for
// this dismissal, so it could never turn into an org-wide black mark. Aiming the penalty at org AND
// venue keeps that guarantee: the same org anywhere else is completely untouched.
@MainActor
@Suite("Passed-show penalty (#384)")
struct PassedShowPenaltyTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func passedRecord(group: String = "Aurora Strings",
                              venue: String? = "Weill Recital Hall") -> HistoryRecord {
        HistoryRecord(groupName: group, status: "passed", email: nil, venue: venue)
    }

    // MARK: - The matcher aims the pass at one show, not at the org

    @Test func theSameOrgAtTheSameVenueIsFlaggedAsPassed() {
        let verdict = HistoryMatch.matchRelationship(
            name: "Aurora Strings", venue: "Weill Recital Hall",
            clients: [], history: [passedRecord()])

        #expect(verdict.passedOnThisShow)
    }

    // The whole point of keeping the venue. Dan turned down their Carnegie run; their show somewhere
    // else is a completely different proposition and must be untouched.
    @Test func theSameOrgAtADifferentVenueIsNotPenalized() {
        let verdict = HistoryMatch.matchRelationship(
            name: "Aurora Strings", venue: "Merkin Hall",
            clients: [], history: [passedRecord()])

        #expect(!verdict.passedOnThisShow)
        #expect(verdict.relationship == .none)   // and it stays a perfectly ordinary cold lead
    }

    // Venue names arrive from scraped listings, so they are compared through the same canonicaliser
    // the natural key uses: casing, stray whitespace and HTML entities must not defeat the match.
    @Test func venueMatchingSurvivesMessyScrapedText() {
        for messy in ["weill recital hall", "  Weill   Recital Hall  ", "Weill&nbsp;Recital Hall"] {
            let verdict = HistoryMatch.matchRelationship(
                name: "Aurora Strings", venue: messy, clients: [], history: [passedRecord()])
            #expect(verdict.passedOnThisShow, "should have matched: \(messy)")
        }
    }

    // A pass is Dan's taste, not the org's rejection. It must never suppress the show, and must never
    // make the org read as a cold or lost relationship.
    @Test func aPassNeverSuppressesTheShowNorChangesTheRelationship() {
        let verdict = HistoryMatch.matchRelationship(
            name: "Aurora Strings", venue: "Weill Recital Hall",
            clients: [], history: [passedRecord()])

        #expect(!verdict.suppressed)
        #expect(verdict.relationship == .none)
    }

    // THE case that a relationship-based design would have got wrong. He booked them before AND
    // passed on this particular show: both facts are true, and both must survive.
    @Test func aBookedOrgKeepsItsRelationshipAndStillTakesThePenalty() {
        let verdict = HistoryMatch.matchRelationship(
            name: "Aurora Strings", venue: "Weill Recital Hall",
            clients: [],
            history: [passedRecord(),
                      HistoryRecord(groupName: "Aurora Strings", status: "booked")])

        #expect(verdict.relationship == .booked)   // not clobbered by the pass
        #expect(verdict.passedOnThisShow)          // and not swallowed by the booking
    }

    // A history record with no venue (every record the CSV importer writes) can never be a pass, so
    // an old file cannot accidentally start penalising shows.
    @Test func aVenuelessRecordNeverPenalizes() {
        let verdict = HistoryMatch.matchRelationship(
            name: "Aurora Strings", venue: "Weill Recital Hall",
            clients: [], history: [passedRecord(venue: nil)])

        #expect(!verdict.passedOnThisShow)
    }

    // MARK: - The ranker

    @Test func aPassCostsFivePointsAndNothingElse() {
        let base = Candidate(reachable: true, priorRelationship: .none, production: .selfProduced,
                             profile: .strong, coverage: .likelyUncovered, discipline: .dance)
        var passed = base
        passed.passedOnThisShow = true

        // dance 3 + self 2 + strong 2 + likely_uncovered 2 = 9, a solidly high-fit show.
        #expect(Ranker.scoreFit(base).score == 9)
        #expect(Ranker.scoreFit(base).tier == .high)

        // Dan's call: a nudge below the cutoff (5), not a burial. It stops being promoted while
        // staying near the top of the longshots, so a change of heart next season is cheap.
        #expect(Ranker.scoreFit(passed).score == 4)
        #expect(Ranker.scoreFit(passed).tier == .longshot)

        // Never excluded. He asked for a decrease, not a removal.
        #expect(!Ranker.scoreFit(passed).excluded)
    }

    // MARK: - End to end, and the trap this feature exists to close

    private let auroraAtWeill = ExtractedEvent(
        title: "Aurora Strings", presenter: "Aurora Strings", venue: "Weill Recital Hall",
        performanceDate: "2026-09-12", sourceUrl: "https://example.com/a")

    @Test func aShowDanPassedOnScoresLowerWhenItComesBackToTheSameVenue() throws {
        let ctx = ModelContext(try container())

        // Season one: it is scouted and Dan passes on it.
        _ = ScoutService.apply(events: [auroraAtWeill], clients: [], history: [], blocked: [], today: ScoutTestClock.beforeAllFixtures, into: ctx)
        let first = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        let originalScore = first.fitScore
        first.status = .dismissed
        first.dismissReasonRaw = DismissReason.dontWantToShoot.rawValue
        try ctx.save()

        // Season two: the identical show returns. Its natural key differs (a new date), so it is a
        // brand-new prospect, which is exactly why nothing remembered the pass before this.
        let nextSeason = ExtractedEvent(
            title: "Aurora Strings", presenter: "Aurora Strings", venue: "Weill Recital Hall",
            performanceDate: "2027-09-11", sourceUrl: "https://example.com/b")
        let history = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        _ = ScoutService.apply(events: [nextSeason], clients: [], history: history, blocked: [], today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let returning = try ctx.fetch(FetchDescriptor<Prospect>())
            .first { $0.performanceDate == "2027-09-11" }!

        #expect(returning.fitScore == originalScore - 5)
        #expect(returning.passedOnThisShow)
    }

    private let auroraElsewhere = ExtractedEvent(
        title: "Aurora Strings", presenter: "Aurora Strings", venue: "Merkin Hall",
        performanceDate: "2027-09-11", sourceUrl: "https://example.com/c")

    // The same org at a DIFFERENT venue must be completely untouched by the pass.
    //
    // Compared against a control run of the identical event with no pass in the history, NOT against
    // the score of the Weill show: the classifier reads the venue, so two venues score differently for
    // reasons that have nothing to do with this feature. Comparing across venues would have "passed"
    // while measuring the wrong thing entirely.
    @Test func theSameOrgAtANewVenueComesBackAtFullScore() throws {
        let control = ModelContext(try container())
        _ = ScoutService.apply(events: [auroraElsewhere], clients: [], history: [], blocked: [], today: ScoutTestClock.beforeAllFixtures, into: control)
        let unpenalizedScore = try control.fetch(FetchDescriptor<Prospect>()).first!.fitScore

        let ctx = ModelContext(try container())
        _ = ScoutService.apply(events: [auroraAtWeill], clients: [], history: [], blocked: [], today: ScoutTestClock.beforeAllFixtures, into: ctx)
        let first = try ctx.fetch(FetchDescriptor<Prospect>()).first!
        first.status = .dismissed
        first.dismissReasonRaw = DismissReason.dontWantToShoot.rawValue
        try ctx.save()

        let history = LocalHistory.records(from: try ctx.fetch(FetchDescriptor<Prospect>()))
        #expect(history.contains { $0.status == "passed" })   // the pass really is in play

        _ = ScoutService.apply(events: [auroraElsewhere], clients: [], history: history, blocked: [], today: ScoutTestClock.beforeAllFixtures, into: ctx)
        let other = try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.venue == "Merkin Hall" }!

        #expect(other.fitScore == unpenalizedScore)
        #expect(!other.passedOnThisShow)
    }

    // The penalty has to survive a re-score, or it silently evaporates the moment Dan corrects the
    // discipline on a prospect he already passed on. That is why the flag is stored on the Prospect
    // and read back by ClassificationOverride, rather than only existing at scout time.
    @Test func correctingTheClassificationDoesNotWipeThePenalty() throws {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2027-09-11",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 2, tier: "longshot", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.passedOnThisShow = true
        ctx.insert(p)

        ClassificationOverride.correct(p, discipline: .dance, production: nil, now: Date())

        // dance 3 + self 2 + strong 2 + likely_uncovered 2 = 9, minus the 5 for the pass.
        #expect(p.fitScore == 4)
    }
}
