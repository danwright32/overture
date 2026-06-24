import Testing
import Foundation
import SwiftData
@testable import Overture

// #42: surface what converts. The view groups contacted prospects by a chosen dimension
// (production / discipline / tier) and feeds them to the tested OutcomeStats tallies.
// This covers the prospect -> sample mapping that the view depends on.
@MainActor
@Suite("Outcome patterns")
struct OutcomePatternsTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func make(_ ctx: ModelContext, group: String, production: String, discipline: String,
                      tier: String, status: ReviewStatus, outcome: Outcome) -> Prospect {
        let p = Prospect(naturalKey: group, groupName: group, discipline: discipline, venue: "V",
                         performanceDate: "2026-07-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: production, profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: tier, fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.outcome = outcome
        ctx.insert(p)
        return p
    }

    @Test func mapsProspectsToSamplesByChosenDimension() throws {
        let ctx = ModelContext(try container())
        _ = make(ctx, group: "A", production: "self", discipline: "choral", tier: "high",
                 status: .approved, outcome: .booked)
        _ = make(ctx, group: "B", production: "agency", discipline: "dance", tier: "longshot",
                 status: .new, outcome: .noResponse)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let byProduction = OutcomePatterns.samples(from: all, by: .production)
        #expect(Set(byProduction.map(\.dimension)) == ["self", "agency"])
        // wasContacted reflects approved/sent; the approved one counts, the .new one does not.
        #expect(byProduction.filter(\.wasContacted).count == 1)

        let byDiscipline = OutcomePatterns.samples(from: all, by: .discipline)
        #expect(Set(byDiscipline.map(\.dimension)) == ["choral", "dance"])

        // Fed through the tested tally, the self/contacted/booked one yields a booking.
        let tallies = OutcomeStats.tallyByDimension(byProduction)
        #expect(tallies["self"]?.booked == 1)
    }

    @Test func flagsLowSampleGroupsSoEarlyNoiseIsntReadAsAPattern() {
        // Under the threshold of meaningful contacts, a rate is noise (e.g. 1 of 1 = 100%).
        #expect(OutcomePatterns.isLowSample(OutcomeTally(contacted: 1, replied: 0, booked: 1, passed: 0, noResponse: 0)))
        #expect(OutcomePatterns.isLowSample(OutcomeTally(contacted: 3, replied: 1, booked: 0, passed: 0, noResponse: 2)))
        #expect(OutcomePatterns.isLowSample(OutcomeTally(contacted: 6, replied: 1, booked: 1, passed: 0, noResponse: 4)) == false)
    }

    @Test func rankedTalliesDropUncontactedGroupsAndSortByBookings() throws {
        let ctx = ModelContext(try container())
        // "self": 1 booked of 1 contacted. "agency": never contacted (.new). "band": contacted, no booking.
        _ = make(ctx, group: "A", production: "self", discipline: "choral", tier: "high", status: .approved, outcome: .booked)
        _ = make(ctx, group: "B", production: "agency", discipline: "dance", tier: "longshot", status: .new, outcome: .noResponse)
        _ = make(ctx, group: "C", production: "band", discipline: "band", tier: "mid", status: .approved, outcome: .noResponse)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())

        let ranked = OutcomePatterns.rankedTallies(from: all, by: .production)
        #expect(ranked.map(\.name) == ["self", "band"])     // agency dropped (0 contacted), self first (booked)
        #expect(ranked.first?.tally.booked == 1)
    }
}
