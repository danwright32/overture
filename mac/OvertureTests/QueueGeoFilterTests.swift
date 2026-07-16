import Testing
@testable import Overture

// #970 Phase 3. The gate finally runs. Everything before this was groundwork that changed nothing Dan
// could see; this is the first change that removes rows from his queue, so the tests are weighted to
// what it must NEVER hide.
//
// It hides at QUEUE time, not at ingest, and that is the whole safety argument. Every event is still
// upserted, so the Outcome invariant (found == inserted + updated + skipped + collapsedIntoRun) and
// seenSourceURLs are untouched by construction, and a geo-filtered show can never be mistaken for one
// the venue cancelled (#133, the live bug class of #897/#917). Hiding is a view concern; the store
// keeps everything.

private func item(
    id: String = "k", groupName: String = "A Show", discipline: String = "theater",
    location: String? = nil, venue: String? = "Weill Recital Hall"
) -> QueueItem {
    QueueItem(
        id: id, groupName: groupName, discipline: discipline, venue: venue,
        performanceDate: "2026-08-01", sourceListingURL: nil, websiteURL: nil,
        location: location,
        priorRelationship: "none", production: "self", profile: "strong", coverage: "unknown",
        fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
        possibleMatchSource: nil, possibleMatchName: nil, status: .untriaged)
}

@Suite("Queue geo filter: what it hides")
struct QueueGeoFilterHideTests {
    // The 11 real rows this feature exists for, in the shape they actually arrive.
    @Test func aConfirmedOutOfTownShowIsHidden() {
        let items = [
            item(id: "nyo", groupName: "NYO Jazz in Beijing, China", discipline: "music", location: "Beijing, China"),
            item(id: "local", groupName: "Cerddorion", discipline: "music", location: "New York, NY"),
        ]
        let kept = QueueModel.filter(items, discipline: nil, highOnly: false, pendingBookingsOnly: false)
        #expect(kept.map(\.id) == ["local"])
    }

    // Dan's discipline split, finally exercised on the queue rather than in the resolver alone.
    @Test func theSameTownHidesAMusicShowAndKeepsATheaterOne() {
        let items = [
            item(id: "orchestra", discipline: "music", location: "Larchmont, NY"),
            item(id: "play", discipline: "theater", location: "Larchmont, NY"),
        ]
        let kept = QueueModel.filter(items, discipline: nil, highOnly: false, pendingBookingsOnly: false)
        #expect(kept.map(\.id) == ["play"])
    }
}

@Suite("Queue geo filter: what it must never hide")
struct QueueGeoFilterKeepTests {
    // Dan's spec #5. A show whose page named no place is KEPT. This is the single most important
    // assertion in the feature: every one of his 128 live rows has no location today, so if unknown
    // hid anything, shipping this would empty his queue.
    @Test func aShowWithNoLocationIsKept() {
        let items = [item(id: "a", location: nil), item(id: "b", location: "")]
        let kept = QueueModel.filter(items, discipline: nil, highOnly: false, pendingBookingsOnly: false)
        #expect(kept.map(\.id) == ["a", "b"])
    }

    // A string the resolver will not place must not be hidden on a guess. "Amsterdam" could be
    // Amsterdam, New York.
    @Test func anUnplaceableLocationIsKept() {
        let items = [item(id: "a", location: "Amsterdam"), item(id: "b", location: "the usual spot")]
        let kept = QueueModel.filter(items, discipline: nil, highOnly: false, pendingBookingsOnly: false)
        #expect(kept.count == 2)
    }

    // Every existing live row, in one test: 128 prospects, none with a location, all Carnegie's.
    // Shipping the gate must be a no-op on the queue Dan has today, except for the rows it can
    // positively place.
    @Test func theGateDoesNotDisturbAQueueThatHasNoLocationsAtAll() {
        let items = (1...20).map { item(id: "\($0)", discipline: "music", location: nil) }
        let kept = QueueModel.filter(items, discipline: nil, highOnly: false, pendingBookingsOnly: false)
        #expect(kept.count == 20)
    }
}

@Suite("Queue geo filter: the count")
struct QueueGeoFilterCountTests {
    // A hidden row must be countable, or the filter is invisible and a bug in it looks identical to
    // "nothing was out of town" (#887: a guard that fails closed forever is still a bug).
    @Test func theHiddenRowsAreCounted() {
        let items = [
            item(id: "a", discipline: "music", location: "Beijing, China"),
            item(id: "b", discipline: "music", location: "Berlin, Germany"),
            item(id: "c", discipline: "music", location: "New York, NY"),
            item(id: "d", discipline: "music", location: nil),
        ]
        #expect(QueueModel.tooFarCount(items) == 2)
    }

    // The number is a promise about rows (#863): whatever the chip says, clicking it must show exactly
    // that many.
    @Test func theCountMatchesTheRowsBehindIt() {
        let items = [
            item(id: "a", discipline: "music", location: "Beijing, China"),
            item(id: "b", discipline: "music", location: "New York, NY"),
        ]
        #expect(QueueModel.tooFar(items).map(\.id) == ["a"])
        #expect(QueueModel.tooFarCount(items) == QueueModel.tooFar(items).count)
    }

    // Hidden and shown must partition the set exactly: a row cannot be in both, and none can vanish
    // from both. This is the queue's own version of the Outcome accounting invariant.
    @Test func everyRowIsEitherShownOrTooFarAndNeverBoth() {
        let items = [
            item(id: "a", discipline: "music", location: "Beijing, China"),
            item(id: "b", discipline: "theater", location: "Larchmont, NY"),
            item(id: "c", discipline: "music", location: "Larchmont, NY"),
            item(id: "d", location: nil),
            item(id: "e", location: "Amsterdam"),
        ]
        let shown = Set(QueueModel.filter(items, discipline: nil, highOnly: false,
                                          pendingBookingsOnly: false).map(\.id))
        let hidden = Set(QueueModel.tooFar(items).map(\.id))
        #expect(shown.isDisjoint(with: hidden))
        #expect(shown.union(hidden) == Set(items.map(\.id)))
    }

    @Test func theChipNamesItsCount() {
        #expect(QueueModel.tooFarLabel(count: 11) == "Too far (11)")
        #expect(QueueModel.tooFarLabel(count: 1) == "Too far (1)")
    }

    // Clicking the chip inverts the gate, which is what makes a hidden show recoverable rather than
    // gone. The same predicate decides both directions, so the count and the rows behind it cannot
    // drift apart.
    @Test func clickingTheChipShowsExactlyWhatWasHidden() {
        let items = [
            item(id: "far", discipline: "music", location: "Beijing, China"),
            item(id: "near", discipline: "music", location: "New York, NY"),
            item(id: "unknown", discipline: "music", location: nil),
        ]
        let shown = QueueModel.filter(items, discipline: nil, highOnly: false,
                                      pendingBookingsOnly: false, tooFarOnly: false)
        let revealed = QueueModel.filter(items, discipline: nil, highOnly: false,
                                         pendingBookingsOnly: false, tooFarOnly: true)
        #expect(shown.map(\.id) == ["near", "unknown"])
        #expect(revealed.map(\.id) == ["far"])
        #expect(revealed.count == QueueModel.tooFarCount(items))
    }

    // The help text is the only thing standing between "Overture hid rows" and "where did my rows go?",
    // so the two states must say genuinely different things (#843: a distinction real in the code that
    // collapses to one sentence on screen is the defect).
    @Test func theHelpSaysSomethingDifferentInEachState() {
        let off = QueueModel.tooFarHelp(showingOnly: false, count: 11)
        let on = QueueModel.tooFarHelp(showingOnly: true, count: 11)
        #expect(off != on)
        #expect(on.contains("11 shows"))
        #expect(on.contains("show the whole queue again"))
    }
}
