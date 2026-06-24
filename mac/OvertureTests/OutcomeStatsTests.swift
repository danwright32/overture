import Testing
@testable import Overture

private func sample(_ contacted: Bool, _ outcome: Outcome, _ dim: String = "x") -> OutcomeSample {
    OutcomeSample(wasContacted: contacted, outcome: outcome, dimension: dim)
}

@Suite("Outcome stats")
struct OutcomeStatsTests {
    @Test func countsOnlyContactedProspects() {
        let t = OutcomeStats.tally([
            sample(true, .booked),
            sample(true, .noResponse),
            sample(false, .noResponse),   // never contacted: ignored
            sample(true, .replied),
            sample(true, .lostSoft),
        ])
        #expect(t.contacted == 4)
        #expect(t.booked == 1)
        #expect(t.replied == 1)
        #expect(t.lost == 1)
        #expect(t.noResponse == 1)
    }

    @Test func ratesAreNilWhenNothingContacted() {
        let t = OutcomeStats.tally([sample(false, .noResponse)])
        #expect(t.bookingRate == nil)
        #expect(t.responseRate == nil)
    }

    @Test func bookingAndResponseRates() {
        let t = OutcomeStats.tally([
            sample(true, .booked),     // engaged + booked
            sample(true, .replied),    // engaged
            sample(true, .noResponse),
            sample(true, .noResponse),
        ])
        #expect(t.bookingRate == 0.25)      // 1 of 4
        #expect(t.responseRate == 0.5)      // 2 of 4
    }

    @Test func splitsByDimensionToRevealPatterns() {
        let byDim = OutcomeStats.tallyByDimension([
            sample(true, .noResponse, "agency"),
            sample(true, .noResponse, "agency"),
            sample(true, .booked, "self"),
            sample(true, .replied, "self"),
        ])
        #expect(byDim["agency"]?.booked == 0)
        #expect(byDim["agency"]?.contacted == 2)
        #expect(byDim["self"]?.bookingRate == 0.5)
    }
}
