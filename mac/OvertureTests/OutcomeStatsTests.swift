import Testing
@testable import Overture

private func sample(_ contacted: Bool, _ outcome: Outcome, _ dim: String = "x",
                    source: OutcomeSource? = nil) -> OutcomeSample {
    OutcomeSample(wasContacted: contacted, outcome: outcome, dimension: dim, outcomeSource: source)
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

    @Test func splitsBookingsByAutoVersusManualSource() {
        // After #99/#114 a booking is either auto-detected from a Downbeat match (.auto) or
        // confirmed by Dan (.manual). The split must be auditable per segment: count and rate.
        let t = OutcomeStats.tally([
            sample(true, .booked, source: .auto),    // hard Downbeat match
            sample(true, .booked, source: .auto),
            sample(true, .booked, source: .manual),  // Dan's own call
            sample(true, .replied),
            sample(true, .noResponse),
        ])
        #expect(t.booked == 3)            // total still intact
        #expect(t.bookedAuto == 2)
        #expect(t.bookedManual == 1)
        #expect(t.bookingRate == 0.6)     // 3 of 5
        #expect(t.autoBookingRate == 0.4) // 2 of 5
        #expect(t.manualBookingRate == 0.2) // 1 of 5
    }

    @Test func autoAndManualBookingRatesAreNilWhenNothingContacted() {
        let t = OutcomeStats.tally([sample(false, .booked, source: .auto)])
        #expect(t.autoBookingRate == nil)
        #expect(t.manualBookingRate == nil)
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
