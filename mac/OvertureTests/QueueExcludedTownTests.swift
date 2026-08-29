import Testing

// #991: Dan's in-app refusal narrows the geo gate. Because the verdict is derived rather than stored
// (#990), the gate reads the union of the seed list and his stored refusals at QUEUE time, so a fresh
// refusal re-decides every row at once with no migration. These tests exercise that union end to end.

private func item(id: String = "k", discipline: String = "theater", location: String? = nil) -> QueueItem {
    QueueItem(
        id: id, groupName: "A Show", discipline: discipline, venue: "Weill Recital Hall",
        performanceDate: "2026-08-01", sourceListingURL: nil, location: location,
        priorRelationship: "none", production: "self", profile: "strong", coverage: "unknown",
        fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
        possibleMatchSource: nil, possibleMatchName: nil, status: .new)
}

@Suite("Queue geo filter: Dan's own excluded towns (#991)")
struct QueueExcludedTownTests {
    // The mechanism the feature exists for: a town not on the seed list shows up in the queue, and once
    // Dan excludes it the SAME rows are re-decided at once and it drops out. No migration, no re-scout.
    @Test func excludingATownReDecidesTheSameRowsAtQueueTime() {
        let items = [
            item(id: "pough", discipline: "theater", location: "Poughkeepsie, NY"),
            item(id: "nyc", discipline: "theater", location: "New York, NY"),
        ]
        // Before his refusal: an in-region town is kept, every time, forever (the bug this closes).
        #expect(QueueModel.filter(items, discipline: nil, highOnly: false, pendingBookingsOnly: false)
                    .map(\.id) == ["pough", "nyc"])
        // After his refusal: the same items, re-decided, and it is gone.
        let kept = QueueModel.filter(items, discipline: nil, highOnly: false, pendingBookingsOnly: false,
                                     userExcludedTowns: ["poughkeepsie"])
        #expect(kept.map(\.id) == ["nyc"])
    }

    // The gate reads the UNION: a seed town is still hidden with an empty user set, a stored town is
    // hidden without touching the seed, and a town on neither is kept.
    @Test func theGateReadsSeedAndStoredTogether() {
        #expect(QueueModel.isTooFar(item(discipline: "theater", location: "Buffalo, NY")))          // seed
        #expect(QueueModel.isTooFar(item(discipline: "theater", location: "Poughkeepsie, NY"),
                                    userExcludedTowns: ["poughkeepsie"]))                            // stored
        #expect(!QueueModel.isTooFar(item(discipline: "theater", location: "Poughkeepsie, NY")))    // neither
    }

    // Idempotent at the gate too: a town in BOTH the seed and the user set is hidden exactly once, and
    // still just hidden, never doubly so or errored.
    @Test func aTownInBothSeedAndUserSetIsSimplyHidden() {
        #expect(QueueModel.isTooFar(item(discipline: "theater", location: "Buffalo, NY"),
                                    userExcludedTowns: ["buffalo"]))
    }

    // A stored-excluded row explains itself with the skip-list sentence, the same one a seed town gets,
    // because to Dan they are the same fact (#992).
    @Test func anExcludedTownRowExplainsItselfAsTheSkipList() {
        let reason = QueueModel.tooFarReason(item(discipline: "theater", location: "Poughkeepsie, NY"),
                                             userExcludedTowns: ["poughkeepsie"])
        #expect(reason == QueueModel.tooFarReasonSentence(.excludedTown))
    }

    // A count is a promise about rows (#863), so it must move with the user's refusals too. Asked through
    // the filter since #2348, which is the pair that survived: `tooFarCount` ran this same set through the
    // retired queue window and had no caller in the app.
    @Test func theCountRespectsTheUserExcludedTowns() {
        let items = [
            item(id: "pough", discipline: "theater", location: "Poughkeepsie, NY"),
            item(id: "nyc", discipline: "theater", location: "New York, NY"),
        ]
        let revealed = QueueModel.filter(items, discipline: nil, highOnly: false,
                                         pendingBookingsOnly: false, tooFarOnly: true,
                                         userExcludedTowns: ["poughkeepsie"])
        #expect(revealed.map(\.id) == ["pough"])
    }
}

@Suite("Extracting the town to exclude from a location (#991)")
struct ExcludableTownTests {
    @Test func takesTheCityBeforeTheStateCode() {
        #expect(EventPlace.excludableTown(from: "Poughkeepsie, NY") == "Poughkeepsie")
        #expect(EventPlace.excludableTown(from: "New Haven, CT") == "New Haven")
    }

    @Test func takesTheCityBeforeASpelledOutState() {
        #expect(EventPlace.excludableTown(from: "Yonkers, New York") == "Yonkers")
    }

    // The messier real shape: a street address in front of the city. The city is the piece just before
    // the state, not the street, and not the ZIP after it.
    @Test func readsThroughStreetNoiseToTheCity() {
        #expect(EventPlace.excludableTown(from: "123 Main St, Poughkeepsie, NY, 12601") == "Poughkeepsie")
    }

    // No US state named, nothing to place: no town is offered. Amsterdam could be Amsterdam, New York,
    // so guessing here would be the exact reasoning-instead-of-evidence mistake #979 warns against.
    @Test func offersNoTownWhenNoStateIsNamed() {
        #expect(EventPlace.excludableTown(from: "Beijing, China") == nil)
        #expect(EventPlace.excludableTown(from: "Amsterdam") == nil)
        #expect(EventPlace.excludableTown(from: nil) == nil)
    }

    // An out-of-region show is already hidden by its state, so there is no town worth excluding: the
    // offer only appears where excluding a town actually changes the verdict.
    @Test func offersNoTownForAnOutOfRegionShow() {
        #expect(EventPlace.excludableTown(from: "Louisville, KY") == nil)
    }

    // The safety guard: the five boroughs are the in-range core Dan always wants, so "never show me
    // New York" must never be an offer. Excluding a borough would silently empty his whole queue.
    @Test func neverOffersToExcludeACoreBorough() {
        #expect(EventPlace.excludableTown(from: "New York, NY") == nil)
        #expect(EventPlace.excludableTown(from: "Brooklyn, NY") == nil)
    }

    // End to end: the token extraction and the gate agree, so a town Dan excludes actually hides its row.
    @Test func theExtractedTownActuallyExcludesTheRow() throws {
        let loc = "Poughkeepsie, NY"
        let town = try #require(EventPlace.excludableTown(from: loc))
        #expect(EventPlace.resolve(location: loc, discipline: .theater,
                                   userExcludedTowns: [town.lowercased()]).verdict == .outOfRange)
    }
}
