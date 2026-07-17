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
        #expect(QueueModel.tooFarCount(items, discipline: nil, highOnly: false,
                                       pendingBookingsOnly: false, reachedOutKeys: [],
                                       today: "2026-07-16") == 2)
    }

    // The number is a promise about rows (#863): whatever the chip says, clicking it must show exactly
    // that many. Named rows, not a count compared against its own definition (#996): the version of this
    // test that asserted `tooFarCount(items) == tooFar(items).count` could not fail, and it did not,
    // through the whole life of the bug.
    @Test func theCountMatchesTheRowsBehindIt() {
        let items = [
            item(id: "a", discipline: "music", location: "Beijing, China"),
            item(id: "b", discipline: "music", location: "New York, NY"),
        ]
        let revealed = QueueModel.tooFar(items, discipline: nil, highOnly: false,
                                         pendingBookingsOnly: false, reachedOutKeys: [],
                                         today: "2026-07-16")
        #expect(revealed.map(\.id) == ["a"])
        #expect(QueueModel.tooFarCount(items, discipline: nil, highOnly: false,
                                       pendingBookingsOnly: false, reachedOutKeys: [],
                                       today: "2026-07-16") == 1)
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

    @Test func theChipNamesItsCount() {
        #expect(QueueModel.tooFarLabel(count: 11) == "Too far (11)")
        #expect(QueueModel.tooFarLabel(count: 1) == "Too far (1)")
    }

    // #996. The chip counted rows the queue then threw away. Dan found this within minutes of the
    // feature shipping: it said "Too far (4)" and showed ONE row.
    //
    // These are the four real rows from the first scout of Smoke Ring Quartet, with their real dates,
    // read on the day he saw it. All four ARE out of range, so the resolver is right and this is purely
    // a counting bug: three of them are also beyond the 90-day lead-time window, so `toSendQueue`
    // windows them away AFTER the filter has already counted them.
    //
    // The count is the thing under test, and it is a promise about ROWS (#863). Whatever clicking the
    // chip puts on screen is the only number it may say.
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

    @Test func theCountPromisesOnlyTheRowsClickingActuallyReveals() {
        let today = "2026-07-16"
        let revealed = QueueModel.toSendQueue(
            QueueModel.filter(Self.smokeRing, discipline: nil, highOnly: false,
                              pendingBookingsOnly: false, tooFarOnly: true),
            reachedOutKeys: [], today: today)

        // What Dan sees when he clicks: one row, not four.
        #expect(revealed.map(\.id) == ["treble"])
        #expect(QueueModel.tooFarCount(Self.smokeRing, discipline: nil, highOnly: false,
                                       pendingBookingsOnly: false, reachedOutKeys: [],
                                       today: today) == revealed.count)
    }

    // The count must move with the queue's other filters too, for the same reason: clicking through a
    // discipline filter reveals the intersection, so a count that ignored it would tell the same
    // shape of lie in a different place.
    @Test func theCountRespectsTheFiltersAlreadyOnTheQueue() {
        let today = "2026-07-16"
        let count = QueueModel.tooFarCount(Self.smokeRing, discipline: "theater", highOnly: false,
                                           pendingBookingsOnly: false, reachedOutKeys: [], today: today)
        #expect(count == 0, "every Smoke Ring row is music, so a theater filter reveals none of them")
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
        #expect(QueueModel.tooFarCount(items, discipline: nil, highOnly: false,
                                       pendingBookingsOnly: false, reachedOutKeys: [],
                                       today: "2026-07-16") == 1)
    }

    // #996: the chip is the only way back out of its own filter, so it must not disappear underneath
    // Dan while it is on. Changing the discipline filter with it active empties its set, and a chip that
    // vanished then would strand him looking at an empty queue with nothing to click.
    @Test func theChipStaysClickableWhileItIsOnEvenWithNothingLeftToShow() {
        #expect(QueueModel.chipIsShown(count: 0, showingOnly: true))
        #expect(QueueModel.chipIsShown(count: 4, showingOnly: false))
        // Nothing out of range and the filter is off: the chip says nothing, which is the #887 promise
        // that a quiet queue looks quiet.
        #expect(!QueueModel.chipIsShown(count: 0, showingOnly: false))
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
