import Testing

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
    location: String? = nil, venue: String? = "Weill Recital Hall",
    date: String? = "2026-08-01"
) -> QueueItem {
    QueueItem(
        id: id, groupName: groupName, discipline: discipline, venue: venue,
        performanceDate: date, sourceListingURL: nil, websiteURL: nil,
        location: location,
        priorRelationship: "none", production: "self", profile: "strong", coverage: "unknown",
        fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
        possibleMatchSource: nil, possibleMatchName: nil, status: .new)
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
    // LIVE-STORE-CLAIM verified=2026-07-16 measure="live rows carrying no location at all"
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
    // "nothing was out of town" (#887: a guard that fails closed forever is still a bug). Counted through
    // the gate itself since #2348, which is where the number came from all along: `tooFarCount` wrapped it
    // in the retired queue window, and nothing in the app called it.
    @Test func theHiddenRowsAreCounted() {
        let items = [
            item(id: "a", discipline: "music", location: "Beijing, China"),
            item(id: "b", discipline: "music", location: "Berlin, Germany"),
            item(id: "c", discipline: "music", location: "New York, NY"),
            item(id: "d", discipline: "music", location: nil),
        ]
        #expect(items.filter(QueueModel.isTooFar).count == 2)
    }

    // The number is a promise about rows (#863): whatever a count says, revealing them must show exactly
    // that many. Named rows, not a count compared against its own definition (#996): the version of this
    // test that asserted `tooFarCount(items) == tooFar(items).count` could not fail, and it did not,
    // through the whole life of the bug. Both sides moved onto the surviving pair in #2348, the gate and
    // the filter that inverts it.
    @Test func theCountMatchesTheRowsBehindIt() {
        let items = [
            item(id: "a", discipline: "music", location: "Beijing, China"),
            item(id: "b", discipline: "music", location: "New York, NY"),
        ]
        let revealed = QueueModel.filter(items, discipline: nil, highOnly: false,
                                         pendingBookingsOnly: false, tooFarOnly: true)
        #expect(revealed.map(\.id) == ["a"])
        #expect(items.filter(QueueModel.isTooFar).count == revealed.count)
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
        // The raw predicate, deliberately: this asserts the GATE partitions the set, which is a claim
        // about the rule and not about the chip's number (#996 owns that, one layer up).
        let hidden = Set(items.filter(QueueModel.isTooFar).map(\.id))
        #expect(shown.isDisjoint(with: hidden))
        #expect(shown.union(hidden) == Set(items.map(\.id)))
    }

    // #2707: `theChipNamesItsCount` stood here. The chip it named went with #1134's removal of the four
    // queue filters, so the label it asserted was one no screen could render. The GATE below is what
    // survived and is still tested: it decides which rows a stage shows.

    // The four real rows from the first scout of Smoke Ring Quartet, with their real dates, read on the
    // day Dan saw #996: the chip said "Too far (4)" and showed ONE row, because three of them were also
    // beyond the 90-day window the queue applied after the count was taken. All four ARE out of range, so
    // the resolver was right and that was purely a counting bug.
    //
    // #2348: the window is gone (nothing applies it since #1567), so the mismatch that test reproduced
    // can no longer be built, and `theCountPromisesOnlyTheRowsClickingActuallyReveals` went with the
    // functions it called. What survives is the rule the rows still prove: a count is a promise about
    // ROWS (#863), and it moves with every other filter on the queue.
    private static let smokeRing = [
        item(id: "treble", groupName: "Treble Harmony Brigade", discipline: "music",
             location: "Baltimore, Maryland", date: "2026-07-31"),   // 15 days out: inside the window
        item(id: "sweeps", groupName: "Harmony Sweepstakes", discipline: "music",
             location: "San Rafael, CA", date: "2026-10-17"),        // 93 days: windowed away
        item(id: "palm", groupName: "Palm Springs Engagement", discipline: "music",
             location: "Palm Springs, CA", date: "2026-10-24"),      // 100 days: windowed away
        item(id: "labbs", groupName: "LABBS 50th Convention", discipline: "music",
             location: "Harrogate, UK", date: "2026-10-30"),         // 106 days: windowed away
    ]

    // All four are out of range, and with no window left to drop three of them, all four are what
    // revealing them shows.
    @Test func theCountPromisesTheRowsRevealingThemActuallyShows() {
        let revealed = QueueModel.filter(Self.smokeRing, discipline: nil, highOnly: false,
                                         pendingBookingsOnly: false, tooFarOnly: true)

        #expect(revealed.map(\.id) == ["treble", "sweeps", "palm", "labbs"])
        #expect(Self.smokeRing.filter(QueueModel.isTooFar).count == revealed.count)
    }

    // The count must move with the queue's other filters too, for the same reason: revealing them through
    // a discipline filter shows the intersection, so a count that ignored it would tell the same shape of
    // lie in a different place.
    @Test func theCountRespectsTheFiltersAlreadyOnTheQueue() {
        let revealed = QueueModel.filter(Self.smokeRing, discipline: "theater", highOnly: false,
                                         pendingBookingsOnly: false, tooFarOnly: true)
        #expect(revealed.isEmpty, "every Smoke Ring row is music, so a theater filter reveals none of them")
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
        #expect(items.filter(QueueModel.isTooFar).count == revealed.count)
    }

    // #2707: `theChipStaysClickableWhileItIsOnEvenWithNothingLeftToShow` (#996) and
    // `theHelpSaysSomethingDifferentInEachState` stood here. Both asserted real rules about a chip #1134
    // removed, and both went on passing over a surface that could not appear, which is what let their
    // copy sit in docs/copy-inventory.md to be cold-read. The rules themselves are not lost: if the chip
    // ever comes back it comes back with them.
}

// #992. The chip says HOW MANY were hidden; a hidden row must also say WHY it in particular was hidden,
// because the three reasons are genuinely different situations Dan reacts to differently. Weighted to
// the one thing that would make the whole feature pointless: three sentences that collapse into one on
// screen (#843/#844).
@Suite("Queue geo filter: why a row was placed too far")
struct QueueGeoFilterReasonTests {
    // The three hiding reasons each get their own sentence, and the sentences are asserted DIFFERENT
    // pairwise, not merely non-nil: a distinction real in the code that renders identically is exactly
    // the defect this feature exists to avoid.
    @Test func theThreeHidingReasonsHaveGenuinelyDistinctSentences() {
        let region = QueueModel.tooFarReasonSentence(.outsideTheRegion)
        let excluded = QueueModel.tooFarReasonSentence(.excludedTown)
        let boroughs = QueueModel.tooFarReasonSentence(.outsideTheBoroughs)
        #expect(region != nil)
        #expect(excluded != nil)
        #expect(boroughs != nil)
        #expect(region != excluded)
        #expect(region != boroughs)
        #expect(excluded != boroughs)
    }

    // A reason that never hides a row carries no sentence: the line appears only on rows the gate
    // positively placed out of range, never on a kept or unknown one.
    @Test func aReasonThatNeverHidesCarriesNoSentence() {
        #expect(QueueModel.tooFarReasonSentence(.insideTheBoroughs) == nil)
        #expect(QueueModel.tooFarReasonSentence(.insideTheRegion) == nil)
        #expect(QueueModel.tooFarReasonSentence(.noLocation) == nil)
        #expect(QueueModel.tooFarReasonSentence(.couldNotPlace) == nil)
    }

    // The three real shapes from the issue, resolved end to end through a QueueItem, each landing on its
    // own sentence. This is the actual text a hidden row shows Dan.
    @Test func theThreeRealRowsEachExplainThemselvesDistinctly() {
        let beijing = item(id: "far", discipline: "music", location: "Beijing, China").tooFarReason
        let buffalo = item(id: "buf", discipline: "music", location: "Buffalo, NY").tooFarReason
        let larchmont = item(id: "larch", discipline: "music", location: "Larchmont, NY").tooFarReason
        #expect(beijing == QueueModel.tooFarReasonSentence(.outsideTheRegion))
        #expect(buffalo == QueueModel.tooFarReasonSentence(.excludedTown))
        #expect(larchmont == QueueModel.tooFarReasonSentence(.outsideTheBoroughs))
        #expect(beijing != buffalo)
        #expect(buffalo != larchmont)
        #expect(beijing != larchmont)
    }

    // The most surprising outcome in the feature (the issue calls it out): the SAME town, as theater, is
    // kept and carries no reason at all, while as music it is hidden and carries the boroughs sentence.
    @Test func theSameTownAsTheaterIsKeptWithNoReason() {
        #expect(item(id: "play", discipline: "theater", location: "Larchmont, NY").tooFarReason == nil)
        let musicReason = item(id: "orchestra", discipline: "music", location: "Larchmont, NY").tooFarReason
        #expect(musicReason == QueueModel.tooFarReasonSentence(.outsideTheBoroughs))
    }

    // A kept row never shows a too-far reason, whatever its location: no place named, an unplaceable
    // place, or a plainly local one all resolve to no reason.
    @Test func aKeptRowHasNoReason() {
        #expect(item(id: "local", discipline: "music", location: "New York, NY").tooFarReason == nil)
        #expect(item(id: "none", location: nil).tooFarReason == nil)
        #expect(item(id: "amsterdam", location: "Amsterdam").tooFarReason == nil)
    }
}
