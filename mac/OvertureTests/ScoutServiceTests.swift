import Testing
import Foundation
import SwiftData

@MainActor
@Suite("In-app scout application")
struct ScoutServiceTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // #801: a sweep of Carnegie's whole feed by a source past its warmup, which is the only thing
    // licensed to read a stored show's absence as a cancellation. Without a `feed:` the run reports on
    // nobody's feed and can mark nothing gone, which is exactly what a hand-added lead does (#826).
    private func carnegieSweep(baseline: Int = 0) -> ScoutService.FeedCheck {
        ScoutService.FeedCheck(sourceId: WatchedSource.carnegieId, baseline: baseline,
                               successfulCheckCount: WatchedSource.warmupRuns)
    }

    private let liveEvents = [
        ExtractedEvent(title: "Boston & New York International Music Competition Winners' Recital",
                       presenter: "Jam Generation", venue: "Weill Recital Hall",
                       performanceDate: "2026-06-22", sourceUrl: "https://example.com/a"),
        ExtractedEvent(title: "Indianapolis Children's Choir", presenter: "Indianapolis Children's Choir",
                       venue: "Stern Auditorium / Perelman Stage", performanceDate: "2026-06-24",
                       sourceUrl: "https://example.com/b"),
    ]

    @Test func classifiesRanksAndInsertsExtractedEvents() throws {
        let ctx = ModelContext(try container())
        let outcome = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(outcome.found == 2)
        #expect(outcome.inserted == 2)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let choir = stored.first { $0.groupName.contains("Children's Choir") }
        #expect(choir?.tier == "high")          // self + strong + uncovered + choral
        let recital = stored.first { $0.groupName.contains("Competition Winners") }
        #expect(recital?.tier == "longshot")    // agency dead zone
    }

    @Test func reScoutPreservesKeepDismissAndUpdates() throws {
        let ctx = ModelContext(try container())
        _ = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        // Dan keeps the choir.
        let key = Prospect.makeNaturalKey(groupName: "Indianapolis Children's Choir",
                                          performanceDate: "2026-06-24", venue: "Stern Auditorium / Perelman Stage")
        let choir = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        choir?.status = .queued
        try ctx.save()

        let outcome = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)
        #expect(outcome.inserted == 0)
        #expect(outcome.updated == 2)

        let refreshed = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(refreshed?.status == .queued)   // decision preserved across a re-scout
    }

    @Test func dncHistorySuppressesAProspect() throws {
        let ctx = ModelContext(try container())
        let history = [HistoryRecord(groupName: "Indianapolis Children's Choir", status: "dnc")]
        let outcome = ScoutService.apply(events: liveEvents, clients: [], history: history, blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(outcome.skipped == 1)   // the DNC choir is suppressed
        #expect(outcome.inserted == 1)  // only the recital remains
    }

    // #970 Phase 3. The scout reports a location (#985) and the resolver can read one (#989), but the
    // gate runs at QUEUE time against `Prospect.location`, so the string has to actually land on the
    // row. Without this hop the whole feature is a no-op with green tests either side of a gap, which
    // is the exact failure #970 has already produced four times.
    @Test func aScoutStoresTheLocationTheRunReported() throws {
        let ctx = ModelContext(try container())
        let e = ExtractedEvent(title: "Gotham Chorus Show", presenter: "Smoke Ring Quartet",
                               venue: "Gotham Hall", performanceDate: "2026-06-24",
                               sourceUrl: "https://example.com/a", location: "New York, NY")
        _ = ScoutService.apply(events: [e], clients: [], history: [], blocked: .empty,
                               today: ScoutTestClock.beforeAllFixtures, into: ctx)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).first?.location == "New York, NY")

        // A re-scout after the listing moved the show must refresh it, or the queue keeps gating on a
        // place the show no longer has.
        let moved = ExtractedEvent(title: "Gotham Chorus Show", presenter: "Smoke Ring Quartet",
                                   venue: "Gotham Hall", performanceDate: "2026-06-24",
                                   sourceUrl: "https://example.com/a", location: "Louisville, KY")
        _ = ScoutService.apply(events: [moved], clients: [], history: [], blocked: .empty,
                               today: ScoutTestClock.beforeAllFixtures, into: ctx)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).first?.location == "Louisville, KY")
    }

    // #1686: the re-key guard that exists for exactly this case was defeated by the same variance. When a
    // title has drifted, the show is recognised by its listing URL, its date and its venue instead
    // (#29/#797), and that venue comparison was a raw lowercase, so one respelling of the room made it
    // miss and a second row appeared. Three of the live store's four YNYC pairs carry the IDENTICAL
    // season-page URL on both rows, so this guard should have caught every one of them. It compares
    // through the same fold the key uses now.
    @Test func aDriftedTitleIsStillRecognisedWhenTheVenueIsRespelled() throws {
        let ctx = ModelContext(try container())
        let first = ExtractedEvent(title: "Summer Community Sings", presenter: "Young New Yorkers' Chorus",
                                   venue: "St. Paul's Episcopal Church (Carroll Gardens)",
                                   performanceDate: "2026-06-24",
                                   sourceUrl: "https://example.com/season")
        _ = ScoutService.apply(events: [first], clients: [], history: [], blocked: .empty,
                               today: ScoutTestClock.beforeAllFixtures, into: ctx)
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == 1)

        // The same night on the same season page, nine days later: the model put the neighbourhood in
        // `location` this time, and the billing gained words the title fold cannot absorb.
        let redrawn = ExtractedEvent(title: "Summer Community Sings with the Neighbourhood Choir",
                                     presenter: "Young New Yorkers' Chorus",
                                     venue: "St. Paul's Episcopal Church",
                                     performanceDate: "2026-06-24",
                                     sourceUrl: "https://example.com/season",
                                     location: "Carroll Gardens")
        _ = ScoutService.apply(events: [redrawn], clients: [], history: [], blocked: .empty,
                               today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.count == 1, "one night, one room, one card")
        #expect(all.first?.groupName == "Summer Community Sings with the Neighbourhood Choir")
    }

    // The presenter is half of what the classifier reads, and it used to be thrown away at assemble.
    // That made every classification a one-way door: #980 fixed the classifier and could not be
    // replayed over the existing rows, because the input was gone. Storing it is what makes a future
    // rule change backfillable. A scout must land it on the row, and a re-scout must refresh it, or a
    // presenter corrected at the source never reaches the store.
    @Test func aScoutStoresThePresenterItClassifiedOn() throws {
        let ctx = ModelContext(try container())
        let e = ExtractedEvent(title: "Cerddorion", presenter: "Cerddorion Vocal Ensemble",
                               venue: "Weill Recital Hall", performanceDate: "2026-06-24",
                               sourceUrl: "https://example.com/a")
        _ = ScoutService.apply(events: [e], clients: [], history: [], blocked: .empty,
                               today: ScoutTestClock.beforeAllFixtures, into: ctx)
        let stored = try ctx.fetch(FetchDescriptor<Prospect>()).first
        #expect(stored?.presenter == "Cerddorion Vocal Ensemble")

        // The same show, re-scouted after the listing corrected its presenter.
        let corrected = ExtractedEvent(title: "Cerddorion", presenter: "Cerddorion Inc",
                                       venue: "Weill Recital Hall", performanceDate: "2026-06-24",
                                       sourceUrl: "https://example.com/a")
        _ = ScoutService.apply(events: [corrected], clients: [], history: [], blocked: .empty,
                               today: ScoutTestClock.beforeAllFixtures, into: ctx)
        let refreshed = try ctx.fetch(FetchDescriptor<Prospect>()).first
        #expect(refreshed?.presenter == "Cerddorion Inc")
    }

    // #60 Task 3: Dan's corrected classification must survive a re-scout.
    // Set up an existing prospect whose discipline was corrected to "dance" by Dan
    // (classificationOverriddenByDan = true). Run apply with a fresh event that the
    // classifier produces as "choral". The prospect's discipline must stay "dance" and
    // fitScore must reflect dance (not the scout's choral value).
    @Test func reScoutPreservesDansCorrectedClassification() throws {
        let ctx = ModelContext(try container())

        // Build the natural key the incoming event will produce.
        let key = Prospect.makeNaturalKey(groupName: "Indianapolis Children's Choir",
                                          performanceDate: "2026-06-24",
                                          venue: "Stern Auditorium / Perelman Stage")

        // Dance score (no prior): discipline 3 + self 2 + strong 2 + likely_uncovered 2 = 9.
        let existing = Prospect(naturalKey: key, groupName: "Indianapolis Children's Choir",
                                discipline: "dance", venue: "Stern Auditorium / Perelman Stage",
                                performanceDate: "2026-06-24", sourceListingURL: nil,
                                priorRelationship: "none", production: "self", profile: "strong",
                                coverage: "likely_uncovered", fitScore: 9, tier: "high",
                                fitReason: "corrected", matchedClientName: nil,
                                possibleMatchSource: nil, possibleMatchName: nil)
        existing.classificationOverriddenByDan = true
        ctx.insert(existing)
        try ctx.save()

        // Scout re-runs; the classifier produces choral for this event (score = 7).
        let choirEvent = ExtractedEvent(title: "Indianapolis Children's Choir",
                                        presenter: "Indianapolis Children's Choir",
                                        venue: "Stern Auditorium / Perelman Stage",
                                        performanceDate: "2026-06-24",
                                        sourceUrl: "https://example.com/b")
        _ = ScoutService.apply(events: [choirEvent], clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let refreshed = try ctx.fetch(FetchDescriptor<Prospect>(
            predicate: #Predicate { $0.naturalKey == key })).first
        // Dan's discipline must survive the re-scout.
        #expect(refreshed?.discipline == "dance")
        // fitScore must be re-derived from dance (9), not copied from the scout's choral result (7).
        #expect(refreshed?.fitScore == 9)
        // The override flag itself must be untouched.
        #expect(refreshed?.classificationOverriddenByDan == true)
    }

    // #1648 Phase A1: every arm of Step B must end in ONE scoring expression that reads the ROW.
    //
    // The performer-match arm protects the score Prep computed, and it did so by writing the fresh
    // discipline and production while leaving fitScore alone. That leaves the row's stored score
    // describing a discipline the row no longer has: here Prep corrected the relationship to booked
    // while the show was classified dance, the listing then re-scouts as music, and the score stays
    // at dance's number. Re-scoring FROM THE ROW is what fixes it, and it cannot undo the correction
    // by the back door, because Step A has already put the protected relationship on the row and the
    // re-score reads it from there rather than from the scout's org guess.
    @Test func aProtectedPerformerMatchIsReScoredFromTheRowNotLeftOnAStaleDiscipline() throws {
        let ctx = ModelContext(try container())
        let key = Prospect.makeNaturalKey(groupName: "Indianapolis Children's Choir",
                                          performanceDate: "2026-06-24",
                                          venue: "Stern Auditorium / Perelman Stage")

        // Prep corrected the relationship to booked off a performer match, and scored it while the
        // show was classified dance: booked 20 + dance 3 + self 2 + strong 2 + uncovered 2 = 29.
        let existing = Prospect(naturalKey: key, groupName: "Indianapolis Children's Choir",
                                discipline: "dance", venue: "Stern Auditorium / Perelman Stage",
                                performanceDate: "2026-06-24", sourceListingURL: nil,
                                priorRelationship: "booked", production: "self", profile: "strong",
                                coverage: "likely_uncovered", fitScore: 29, tier: "high",
                                fitReason: "performer match", matchedClientName: "ICC",
                                possibleMatchSource: nil, possibleMatchName: nil)
        existing.relationshipCorrectedByPerformerMatch = true
        ctx.insert(existing)
        try ctx.save()

        // The scout re-reads the listing and the classifier now calls it music. No client list, so the
        // org match is not confident and Step A leaves the performer correction standing.
        let choirEvent = ExtractedEvent(title: "Indianapolis Children's Choir",
                                        presenter: "Indianapolis Children's Choir",
                                        venue: "Stern Auditorium / Perelman Stage",
                                        performanceDate: "2026-06-24",
                                        sourceUrl: "https://example.com/b")
        _ = ScoutService.apply(events: [choirEvent], clients: [], history: [], blocked: .empty,
                               today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let refreshed = try ctx.fetch(FetchDescriptor<Prospect>(
            predicate: #Predicate { $0.naturalKey == key })).first
        // The correction itself is untouched: that is the whole point of the arm.
        #expect(refreshed?.priorRelationship == "booked")
        #expect(refreshed?.relationshipCorrectedByPerformerMatch == true)
        #expect(refreshed?.discipline == "music")
        // booked 20 + music 1 + self 2 + strong 2 + uncovered 2 = 27, re-derived from the row.
        // Before #1648 Phase A1 this stayed 29, the number dance earned.
        #expect(refreshed?.fitScore == 27)
        #expect(refreshed?.tier == "high")
    }

    // #1274: Dan renames an ugly scout-generated groupName. The rename must survive the next scout
    // (the guard in apply()), and the anti-duplicate crux: it must NOT change the naturalKey, so the
    // scout's exact-key match keeps firing and no second row is inserted. scoutGroupName is kept
    // current so a later "reset to scout name" restores the real, latest scout name.
    @Test func reScoutPreservesDansManualRenameWithoutDuplicating() throws {
        let ctx = ModelContext(try container())
        _ = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let key = Prospect.makeNaturalKey(groupName: "Indianapolis Children's Choir",
                                          performanceDate: "2026-06-24",
                                          venue: "Stern Auditorium / Perelman Stage")
        let choir = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        // Dan renames it, exactly as the rename mutation does: change the display name, set the
        // override, leave the natural key alone.
        choir?.groupName = "Indy Kids Choir at Carnegie"
        choir?.scoutGroupName = "Indianapolis Children's Choir"
        choir?.groupNameOverriddenByDan = true
        try ctx.save()

        // The scout re-runs, still emitting its own original name for this show.
        let outcome = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)
        #expect(outcome.inserted == 0)   // no duplicate row spawned by the rename
        #expect(outcome.updated == 2)

        let refreshed = try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first
        #expect(refreshed?.groupName == "Indy Kids Choir at Carnegie")        // Dan's name survived
        #expect(refreshed?.groupNameOverriddenByDan == true)                   // flag untouched
        #expect(refreshed?.scoutGroupName == "Indianapolis Children's Choir")  // scout name kept fresh for reset

        // Exactly one row for this show still exists.
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.filter { $0.venue == "Stern Auditorium / Perelman Stage" }.count == 1)
    }

    // #1274: the override is a real gate, not a permanent freeze. When Dan has NOT renamed a show, the
    // scout still owns its groupName and a venue re-title flows through as before.
    @Test func reScoutRefreshesGroupNameWhenNotOverridden() throws {
        let ctx = ModelContext(try container())
        _ = ScoutService.apply(events: liveEvents, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        // The venue re-titles the show between runs; same source listing, date and venue, so the
        // stable-source arm re-keys it in place (#29).
        let reTitled = ExtractedEvent(title: "Indianapolis Children's Choir (Holiday Concert)",
                                      presenter: "Indianapolis Children's Choir",
                                      venue: "Stern Auditorium / Perelman Stage",
                                      performanceDate: "2026-06-24",
                                      sourceUrl: "https://example.com/b")
        _ = ScoutService.apply(events: [reTitled], clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        let choir = stored.first { $0.venue == "Stern Auditorium / Perelman Stage" }
        #expect(choir?.groupName == "Indianapolis Children's Choir (Holiday Concert)")  // scout still owns it
        #expect(choir?.groupNameOverriddenByDan == false)
    }

    // The performer-match guard (#750, plan #748, issue #585). Fixtures below share one event, so a
    // re-scout of it produces the natural key these prospects are stored under.
    private let choirEvent = ExtractedEvent(title: "Indianapolis Children's Choir",
                                            presenter: "Indianapolis Children's Choir",
                                            venue: "Stern Auditorium / Perelman Stage",
                                            performanceDate: "2026-06-24",
                                            sourceUrl: "https://example.com/b")

    private var choirKey: String {
        Prospect.makeNaturalKey(groupName: "Indianapolis Children's Choir",
                                performanceDate: "2026-06-24",
                                venue: "Stern Auditorium / Perelman Stage")
    }

    // A prospect Prep already corrected via a performer match: the org name still matches nothing,
    // but the performer behind it is a past client, so the relationship reads booked.
    private func performerCorrectedChoirProspect() -> Prospect {
        let p = Prospect(naturalKey: choirKey, groupName: "Indianapolis Children's Choir",
                         discipline: "music", venue: "Stern Auditorium / Perelman Stage",
                         performanceDate: "2026-06-24", sourceListingURL: nil,
                         priorRelationship: "booked", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 27, tier: "high",
                         fitReason: "performer match", matchedClientName: "Larkin Sable",
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.downbeatClientId = "client-larkin"
        p.relationshipCorrectedByPerformerMatch = true
        p.matchedPerformerName = "Larkin Sable"
        p.performerMatchNote = "Matched performer 'Larkin Sable' to Downbeat client Larkin Sable."
        return p
    }

    private func choirRow(_ ctx: ModelContext) throws -> Prospect {
        let key = choirKey
        return try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })).first!
    }

    // THE regression this whole phase exists for. The scout re-derives the relationship from the ORG
    // name, which by definition still doesn't match, so without the lock every performer-match
    // correction is silently reverted on the very next run: a warm draft next to a cold tier, with
    // nothing explaining it. All five fields must survive untouched.
    @Test func aPerformerMatchCorrectionSurvivesTheNextScout() throws {
        let ctx = ModelContext(try container())
        ctx.insert(performerCorrectedChoirProspect())
        try ctx.save()

        // Re-scout with no clients and no history, so the fresh org match is nothing at all.
        _ = ScoutService.apply(events: [choirEvent], clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let refreshed = try choirRow(ctx)
        #expect(refreshed.priorRelationship == "booked")
        #expect(refreshed.matchedClientName == "Larkin Sable")
        #expect(refreshed.downbeatClientId == "client-larkin")
        #expect(refreshed.fitScore == 27)
        #expect(refreshed.tier == "high")
        #expect(refreshed.relationshipCorrectedByPerformerMatch)
    }

    // The two flags are orthogonal: Dan can correct a prospect's discipline at any time, unrelated to
    // whether a performer match separately corrected its relationship. Resolving them as nested
    // branches (checking Dan's override first, as an outer short-circuit) would send this prospect
    // down the recompute-from-the-fresh-org-match path and reproduce the exact self-destruct above,
    // just triggered by an unrelated Dan action. Neither flag may clobber the other.
    @Test func dansClassificationOverrideAndThePerformerMatchLockDoNotClobberEachOther() throws {
        let ctx = ModelContext(try container())
        let p = performerCorrectedChoirProspect()
        p.discipline = "dance"                  // Dan's correction, not the classifier's guess
        p.classificationOverriddenByDan = true
        p.fitScore = 5                          // deliberately stale, must be recomputed below
        p.tier = "longshot"
        ctx.insert(p)
        try ctx.save()

        _ = ScoutService.apply(events: [choirEvent], clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let refreshed = try choirRow(ctx)
        // The performer-match lock still protects the relationship identity.
        #expect(refreshed.priorRelationship == "booked")
        #expect(refreshed.matchedClientName == "Larkin Sable")
        #expect(refreshed.downbeatClientId == "client-larkin")
        // Dan's discipline still survives too.
        #expect(refreshed.discipline == "dance")
        // And the score is re-derived from BOTH: dance 3 + self 2 + strong 2 + likely_uncovered 2 = 9,
        // plus the protected booked prior (20) = 29. Not the stale 5, and not a cold org-based score.
        #expect(refreshed.fitScore == 29)
        #expect(refreshed.tier == "high")
    }

    // The lock is not a permanent one-way override. A fresh, confident ORG match is a stronger signal
    // than a standing performer guess, so it wins and clears the lock (and its note) rather than
    // being blocked by it.
    @Test func aFreshConfidentOrgMatchOverridesAndClearsThePerformerLock() throws {
        let ctx = ModelContext(try container())
        ctx.insert(performerCorrectedChoirProspect())
        try ctx.save()

        let client = DownbeatClient(id: "client-choir", displayName: "Indianapolis Children's Choir",
                                    shortName: nil, email: "", contractEmail: "", phoneNumber: nil,
                                    isTaxExempt: nil, hasLeftReview: false, specialBehaviors: [],
                                    notes: nil, hostingSite: "")
        _ = ScoutService.apply(events: [choirEvent], clients: [client], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let refreshed = try choirRow(ctx)
        #expect(refreshed.priorRelationship == "booked")
        #expect(refreshed.matchedClientName == "Indianapolis Children's Choir")   // the ORG, not the performer
        #expect(refreshed.downbeatClientId == "client-choir")
        // The stale performer correction is gone, note and all, not left to contradict the org match.
        #expect(!refreshed.relationshipCorrectedByPerformerMatch)
        #expect(refreshed.matchedPerformerName == nil)
        #expect(refreshed.performerMatchNote == nil)
    }

    // Dan said the match was wrong. A dismissed lock protects nothing, so the scout goes back to
    // exactly today's behavior and the cold org verdict lands.
    @Test func aDismissedPerformerMatchNoLongerProtectsAnything() throws {
        let ctx = ModelContext(try container())
        let p = performerCorrectedChoirProspect()
        p.performerMatchDismissed = true
        ctx.insert(p)
        try ctx.save()

        _ = ScoutService.apply(events: [choirEvent], clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        let refreshed = try choirRow(ctx)
        #expect(refreshed.priorRelationship == "none")
        #expect(refreshed.matchedClientName == nil)
        #expect(refreshed.downbeatClientId == nil)
        #expect(refreshed.fitScore != 27)   // re-scored cold, not left at the performer-match score
    }

    // #133: a kept Carnegie prospect that drops out of the feed accrues misses and, after two
    // consecutive ones, reads as gone — while one that's still present stays at zero.
    @Test func disappearedCarnegieProspectAccruesMissesAcrossScouts() throws {
        let ctx = ModelContext(try container())
        let future = "2026-12-01"
        let x = ExtractedEvent(title: "Future Choir X", presenter: "Future Choir X",
                               venue: "Weill Recital Hall", performanceDate: future,
                               sourceUrl: "https://www.carnegiehall.org/event/x")
        let y = ExtractedEvent(title: "Future Choir Y", presenter: "Future Choir Y",
                               venue: "Weill Recital Hall", performanceDate: future,
                               sourceUrl: "https://www.carnegiehall.org/event/y")
        _ = ScoutService.applySweep(events: [x], clients: [], history: [], blocked: .empty, feed: carnegieSweep(), today: ScoutTestClock.beforeAllFixtures, sourceIds: [WatchedSource.carnegieId], into: ctx)
        let xKey = Prospect.makeNaturalKey(groupName: "Future Choir X", performanceDate: future, venue: "Weill Recital Hall")
        func xRow() throws -> Prospect { try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == xKey })).first! }
        #expect(try xRow().missedScoutCount == 0)

        // X is absent from a healthy (non-empty) feed: one miss, not yet gone.
        _ = ScoutService.applySweep(events: [y], clients: [], history: [], blocked: .empty, feed: carnegieSweep(), today: ScoutTestClock.beforeAllFixtures, sourceIds: [WatchedSource.carnegieId], into: ctx)
        #expect(try xRow().missedScoutCount == 1)
        #expect(try xRow().disappearedFromFeed == false)

        // Absent again: two misses, now gone.
        _ = ScoutService.applySweep(events: [y], clients: [], history: [], blocked: .empty, feed: carnegieSweep(), today: ScoutTestClock.beforeAllFixtures, sourceIds: [WatchedSource.carnegieId], into: ctx)
        #expect(try xRow().disappearedFromFeed == true)

        // X reappears: counter resets.
        _ = ScoutService.applySweep(events: [x], clients: [], history: [], blocked: .empty, feed: carnegieSweep(), today: ScoutTestClock.beforeAllFixtures, sourceIds: [WatchedSource.carnegieId], into: ctx)
        #expect(try xRow().missedScoutCount == 0)
    }

    // #150: a degraded (suspiciously small vs baseline) feed must not accrue misses through apply.
    @Test func applyWithDegradedFeedDoesNotAccrueMisses() throws {
        let ctx = ModelContext(try container())
        let future = "2026-12-01"
        let x = ExtractedEvent(title: "Future Choir X", presenter: "Future Choir X",
                               venue: "Weill Recital Hall", performanceDate: future,
                               sourceUrl: "https://www.carnegiehall.org/event/x")
        let y = ExtractedEvent(title: "Future Choir Y", presenter: "Future Choir Y",
                               venue: "Weill Recital Hall", performanceDate: future,
                               sourceUrl: "https://www.carnegiehall.org/event/y")
        _ = ScoutService.applySweep(events: [x], clients: [], history: [], blocked: .empty, feed: carnegieSweep(), today: ScoutTestClock.beforeAllFixtures, sourceIds: [WatchedSource.carnegieId], into: ctx)
        let xKey = Prospect.makeNaturalKey(groupName: "Future Choir X", performanceDate: future, venue: "Weill Recital Hall")
        func xRow() throws -> Prospect { try ctx.fetch(FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == xKey })).first! }

        // Tiny feed (only y) but a large healthy baseline → feed looks degraded → X is NOT a miss.
        _ = ScoutService.applySweep(events: [y], clients: [], history: [], blocked: .empty, feed: carnegieSweep(baseline: 80), today: ScoutTestClock.beforeAllFixtures, sourceIds: [WatchedSource.carnegieId], into: ctx)
        #expect(try xRow().missedScoutCount == 0)
    }

    // #901: the scout's blocked calendar is Downbeat's booked shoots AND the days off Dan typed into
    // Overture, from ONE builder that every path (scout, batched extract ingest, pasted lead) calls.
    //
    // It replaces `mergedBlockedDates`, which unioned Downbeat's dates with a local override FILE that
    // nothing in the app has ever written. The lead path did not even read that file, so a pasted lead
    // was judged against a different set of blocked days than a scouted show was.
    @Test func theBlockedCalendarUnionsDownbeatsShootsWithDansOwnDaysOff() throws {
        let ctx = ModelContext(try ModelContainer(for: Schema([Prospect.self, DayOff.self]),
                                                  configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
        DayOffEditing.add(start: "2026-04-01", end: "2026-04-01", note: "Vacation", into: ctx)

        let cal = ScoutService.blockedCalendar(
            export: (bookings: [OvertureBooking(id: "b1", clientId: "c1", clientDisplayName: "A Client",
                                                shootName: "Nguyen Recital", startDate: "2026-03-10",
                                                endDate: "2026-03-10", venueId: nil, venueName: "V")],
                     blockedDates: ["2026-03-10"], health: .ok),
            context: ctx)

        #expect(cal.conflict(performanceDate: "2026-03-10", runEndDate: nil)?.name == "Nguyen Recital")
        #expect(cal.conflict(performanceDate: "2026-04-01", runEndDate: nil)?.name == "Vacation")
        #expect(cal.conflict(performanceDate: "2026-05-01", runEndDate: nil) == nil)
    }

    @Test func healthyFeedCountPersistenceRoundTrips() {
        let defaults = UserDefaults(suiteName: "feedcount-\(UUID().uuidString)")!
        #expect(ScoutService.lastHealthyFeedCount(in: defaults) == 0)   // unset = no baseline
        ScoutService.recordHealthyFeedCount(42, in: defaults)
        #expect(ScoutService.lastHealthyFeedCount(in: defaults) == 42)
    }

    // #152: the persisted feed-health state self-heals across scouts — a full feed sets the
    // baseline, then three consecutive stable smaller feeds re-baseline to the new normal.
    @Test func feedHealthStatePersistsAndSelfHeals() {
        let defaults = UserDefaults(suiteName: "feedhealth-\(UUID().uuidString)")!
        #expect(ScoutService.feedHealthState(in: defaults).baseline == 0)   // unset = no baseline
        func scout(_ count: Int) {
            let next = FeedReconcile.updatedHealth(ScoutService.feedHealthState(in: defaults), currentCount: count)
            ScoutService.recordFeedHealthState(next, in: defaults)
        }
        scout(80)
        #expect(ScoutService.feedHealthState(in: defaults).baseline == 80)
        for c in [38, 37, 39] { scout(c) }
        #expect(ScoutService.feedHealthState(in: defaults).baseline == 39)   // re-baselined to new normal
        #expect(ScoutService.feedHealthState(in: defaults).degradedStreak == 0)
    }

    @Test func collapsesAConsecutiveRunIntoOneProspect() throws {
        let ctx = ModelContext(try container())
        let events = [
            ExtractedEvent(title: "Mark Morris", presenter: "The Joyce Theater", venue: "The Joyce", performanceDate: "2026-07-14", sourceUrl: "u14"),
            ExtractedEvent(title: "Mark Morris", presenter: "The Joyce Theater", venue: "The Joyce", performanceDate: "2026-07-15", sourceUrl: "u15"),
            ExtractedEvent(title: "Mark Morris", presenter: "The Joyce Theater", venue: "The Joyce", performanceDate: "2026-07-16", sourceUrl: "u16"),
        ]
        let outcome = ScoutService.apply(events: events, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)
        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.count == 1)
        #expect(stored[0].performanceDate == "2026-07-14")
        #expect(stored[0].runEndDate == "2026-07-16")
        #expect(outcome.inserted == 1)
    }

    @Test func reRecognizesARunWhoseOpeningNightAgedOut() throws {
        let ctx = ModelContext(try container())
        let day1 = [
            ExtractedEvent(title: "Run", presenter: "Producer Org", venue: "Hall", performanceDate: "2026-07-14", sourceUrl: "n14"),
            ExtractedEvent(title: "Run", presenter: "Producer Org", venue: "Hall", performanceDate: "2026-07-15", sourceUrl: "n15"),
        ]
        _ = ScoutService.apply(events: day1, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)
        let kept = try ctx.fetch(FetchDescriptor<Prospect>())[0]
        kept.statusRaw = "dismissed"   // Dan's decision
        try? ctx.save()

        // Next scout: the 14th has aged out of the window; only the 15th remains.
        let day2 = [ExtractedEvent(title: "Run", presenter: "Producer Org", venue: "Hall", performanceDate: "2026-07-15", sourceUrl: "n15")]
        _ = ScoutService.apply(events: day2, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)
        let stored = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(stored.count == 1)               // re-attached, not duplicated
        #expect(stored[0].statusRaw == "dismissed")  // decision preserved
    }

    @Test func titleDriftWithSameSourceURLCarriesTheDecisionForward() throws {
        let ctx = ModelContext(try container())
        let url = "https://www.carnegiehall.org/event/abc-123"
        let first = ExtractedEvent(title: "Acme Festival Chorus", presenter: "Acme Festival Chorus",
                                   venue: "Weill Recital Hall", performanceDate: "2026-07-01", sourceUrl: url)
        _ = ScoutService.apply(events: [first], clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        // Dan dismisses it.
        let p = try ctx.fetch(FetchDescriptor<Prospect>()).first { $0.status != .dismissed }
        p?.status = .dismissed
        try ctx.save()

        // Re-scout: the venue tweaked the listing title, but the source URL is unchanged.
        let drifted = ExtractedEvent(title: "Acme Festival Chorus — Summer Concert", presenter: "Acme Festival Chorus",
                                     venue: "Weill Recital Hall", performanceDate: "2026-07-01", sourceUrl: url)
        let outcome = ScoutService.apply(events: [drifted], clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(outcome.inserted == 0)                                    // no orphaned duplicate
        #expect(outcome.updated == 1)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.count == 1)                                          // still one record
        #expect(all.first?.status == .dismissed)                         // Dan's decision carried forward
        #expect(all.first?.groupName == "Acme Festival Chorus — Summer Concert") // refreshed to new title
    }

    // #1228: #1217 forces a manual scout to RE-READ a degraded source even when its page is byte-for-byte
    // unchanged, which re-runs AI extraction on identical bytes. Extraction is not perfectly deterministic,
    // so the same page can come back with a subtly different title, which shifts the natural key and could
    // split the prospect into a duplicate while the original is marked gone. This proves the whole path is
    // safe: the forced re-read fires (the #1217 decision), and when it returns a slightly different title on
    // the same source listing + date, the re-key guards reconcile it to the SAME row rather than duplicating.
    @Test func aForcedRereadWithASubtlyDifferentTitleReKeysRatherThanDuplicates() throws {
        // The #1217 trigger: a degraded source (its last read dropped events) whose page is unchanged is
        // still re-read on Dan's manual scout, so the extractor runs again on identical bytes.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = WatchedSource(sourceId: "dciny", orgName: "DCINY",
                                   listingsURL: "https://dciny.org/opportunities/", kind: .html)
        source.lastContentHash = "unchanged-bytes"
        source.lastUnreadableCount = 1
        let page = FetchedPage(normalizedHTML: "<p>listings</p>", finalURL: "https://dciny.org/opportunities/",
                               contentHash: "unchanged-bytes")
        #expect(SourceCheck.decide(source: source, result: .success(page), depth: .readChanged, now: now)
                == .read(page))   // re-read despite the unchanged hash: this is the path that re-extracts

        // First scout: the prospect lands and Dan queues it.
        let ctx = ModelContext(try container())
        let url = "https://dciny.org/opportunities/#carnegie-nov16"
        let first = ExtractedEvent(title: "The Four Freedoms", presenter: "DCINY",
                                   venue: "Stern Auditorium / Perelman Stage", performanceDate: "2026-11-16",
                                   sourceUrl: url)
        _ = ScoutService.apply(events: [first], clients: [], history: [], blocked: .empty,
                               today: ScoutTestClock.beforeAllFixtures, into: ctx)
        let p = try ctx.fetch(FetchDescriptor<Prospect>()).first
        p?.status = .queued
        try ctx.save()

        // The forced re-read of the SAME bytes returns a subtly different title (extraction non-determinism),
        // same source listing URL + date + venue. It must re-key the existing row, not orphan a duplicate.
        let reread = ExtractedEvent(title: "The Four Freedoms.", presenter: "DCINY",
                                    venue: "Stern Auditorium / Perelman Stage", performanceDate: "2026-11-16",
                                    sourceUrl: url)
        let outcome = ScoutService.apply(events: [reread], clients: [], history: [], blocked: .empty,
                                         today: ScoutTestClock.beforeAllFixtures, into: ctx)

        #expect(outcome.inserted == 0)   // no orphaned duplicate from the re-extracted title
        #expect(outcome.updated == 1)
        let all = try ctx.fetch(FetchDescriptor<Prospect>())
        #expect(all.count == 1)                          // still one record, reconciled
        #expect(all.first?.status == .queued)            // Dan's decision survives the forced re-read
        #expect(all.first?.groupName == "The Four Freedoms.")  // refreshed to the re-extracted title
    }

    // #617: a real save() failure (not just the source-scan guard in ScoutServiceSaveGuardTests),
    // via ImmutableStoreFixture.
    @Test func applyReportsSaveFailedOnAGenuineSaveFailure() async throws {
        let outcome = try await ImmutableStoreFixture.withFailingSave(
            schema: Schema([Prospect.self]),
            seed: { _ in },
            body: { ctx in
                ScoutService.apply(events: self.liveEvents, clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, into: ctx)
            })

        #expect(outcome.found == 2)
        #expect(outcome.inserted == 2)
        #expect(outcome.saveFailed)
    }
}
