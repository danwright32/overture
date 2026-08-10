import Testing

// #2399: the tally counts the three groups off `showOutcome`, the one field, so these samples say how each
// show ENDED. The legacy `outcome` is still passed for the source split and the open-pitch replied case,
// and it is mapped from the ending here so one argument describes one show rather than two that can
// disagree. Before this the tally read `Outcome.lostSoft`/`.lostHard`, which nothing in the app has ever
// written, so every assertion about a loss below was green while protecting nothing (#2401, L1).
private func sample(_ contacted: Bool, _ ending: ShowOutcome?, _ dim: String = "x",
                    source: OutcomeSource? = nil, replied: Bool = false) -> OutcomeSample {
    let legacy: Outcome = ending == .booked ? .booked : (replied ? .replied : .noResponse)
    return OutcomeSample(wasContacted: contacted, outcome: legacy, dimension: dim, outcomeSource: source,
                         showOutcome: ending, aContactReplied: replied)
}

@Suite("Outcome stats")
struct OutcomeStatsTests {
    @Test func countsOnlyContactedProspects() {
        let t = OutcomeStats.tally([
            sample(true, .booked),
            sample(true, nil),                  // pitched, no ending yet
            sample(false, nil),                 // never contacted and never ended: ignored
            sample(true, nil, replied: true),   // pitched, somebody wrote back, still open
            sample(true, .theySaidNotNow),
        ])
        #expect(t.contacted == 4)
        #expect(t.booked == 1)
        #expect(t.replied == 1)
        #expect(t.lost == 1)
        #expect(t.noResponse == 1)
    }

    @Test func ratesAreNilWhenNothingContacted() {
        let t = OutcomeStats.tally([sample(false, nil)])
        #expect(t.bookingRate == nil)
        #expect(t.responseRate == nil)
    }

    @Test func bookingAndResponseRates() {
        let t = OutcomeStats.tally([
            sample(true, .booked),     // engaged + booked
            sample(true, nil, replied: true),    // engaged
            sample(true, nil),
            sample(true, nil),
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
            sample(true, nil, replied: true),
            sample(true, nil),
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
            sample(true, nil, "agency"),
            sample(true, nil, "agency"),
            sample(true, .booked, "self"),
            sample(true, nil, "self", replied: true),
        ])
        #expect(byDim["agency"]?.booked == 0)
        #expect(byDim["agency"]?.contacted == 2)
        #expect(byDim["self"]?.bookingRate == 0.5)
    }
}
