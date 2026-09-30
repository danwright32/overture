import Testing
import Foundation
import SwiftData

// #4330 (A13): the scout's own entry points going through `LandingSingleFlight`, with the design corrections
// decided on the issue on 2026-09-29: only store work holds the token, the sweep and the read budget
// question run without it, a landing re-validates what it read against `lastTouchedSequence` before
// applying anything, and a refused ingest keeps a copy of its results so nothing is lost (L665).
//
// Every flight here is the test's own, so a store held across a suspension in one test can never make
// another test's landing wait. Deadlines are driven by an injected sleep, never real time (L524).

// A sleep the test ends when it chooses, or at once.
@MainActor
private final class Deadlines {
    private var pending: [CheckedContinuation<Void, Never>] = []
    func sleep(_ d: Duration) async { await withCheckedContinuation { pending.append($0) } }
    func passAll() {
        let all = pending
        pending = []
        all.forEach { $0.resume() }
    }
}

// Holds a read (a fetch, an extract, a question) until the test opens it, and says when it is holding.
@MainActor
private final class Gate {
    private(set) var entered = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func wait() async {
        entered += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        let all = waiters
        waiters = []
        all.forEach { $0.resume() }
    }
}

private struct ListedFeed: SourceExtractor {
    let events: [ExtractedEvent]
    func extract() async throws -> ExtractedListing { ExtractedListing(events: events, verdict: .upcomingListings) }
}

private struct GatedFeed: SourceExtractor {
    let events: [ExtractedEvent]
    let gate: Gate
    func extract() async throws -> ExtractedListing {
        await gate.wait()
        return ExtractedListing(events: events, verdict: .upcomingListings)
    }
}

@MainActor
@Suite("The scout's landings wait their turn for the store, and lose nothing (#4330)")
struct ScoutLandingsWaitTheirTurnTests {
    private let sandboxes = TemporarySandboxes()
    private let now = Date()

    private func container() throws -> ModelContainer { try TestModelContainer.inMemory(AppSchema.models) }

    private static func night(_ n: Int) -> String {
        EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: Date())!)
    }

    private static func events(_ label: String, count: Int = 3) -> [ExtractedEvent] {
        (0..<count).map { k in
            ExtractedEvent(title: "Quartet \(label) \(k)", presenter: "Quartet \(label) \(k) Presents",
                           venue: "Venue \(k) Hall", performanceDate: night(k),
                           sourceUrl: "https://\(label).example/e\(k)", location: "New York, NY")
        }
    }

    private static func extractEvents(_ label: String) -> [ScoutExtractEvent] {
        (0..<2).map { k in
            ScoutExtractEvent(title: "Recital \(label) \(k)", presenter: "Recital \(label) \(k)",
                              venue: "Merkin Hall", performanceDate: night(k),
                              sourceUrl: "https://\(label).example/r\(k)")
        }
    }

    private static func results(_ label: String, sourceId: String = "org") -> ScoutExtractResults {
        ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                            results: [ScoutExtractResult(sourceId: sourceId, verdict: .upcomingListings,
                                                         events: extractEvents(label), note: nil)])
    }

    @discardableResult
    private func feed(_ id: String, in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Feed \(id)", listingsURL: "https://\(id).example/", kind: .algolia)
        ctx.insert(s)
        return s
    }

    @discardableResult
    private func htmlSource(_ id: String = "org", in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)", listingsURL: "https://\(id).example/events", kind: .html)
        s.venueLocation = "New York, NY"
        s.lastContentHash = "old"
        ctx.insert(s)
        return s
    }

    private func titles(_ ctx: ModelContext) throws -> [String] {
        try ctx.fetch(FetchDescriptor<Prospect>()).map(\.groupName)
    }

    private func run(_ ctx: ModelContext, flight: LandingSingleFlight, only: Set<String>,
                     extractor: @escaping (WatchedSource?) -> (any SourceExtractor)? = { _ in nil },
                     depth: ScoutDepth = .watchOnly, priority: LandingSingleFlight.Priority = .scout,
                     fetch: @escaping (URL, String?, String?) async throws -> FetchedPage = { url, _, _ in
                         FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "old")
                     },
                     askReadBudget: @escaping (Int) async -> ScoutReadBudget.Choice = { _ in .all })
        async throws -> ScoutService.Outcome {
        try await ScoutService.runScout(
            into: ctx, depth: depth, only: only, extractorRegistry: extractor, fetch: fetch,
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            now: now, defaults: ScratchDefaults.make("ScoutLandingsWaitTheirTurnTests"),
            askReadBudget: askReadBudget,
            landings: flight, landingPriority: priority, sequenceFloor: { 0 })
    }

    private func ingest(_ r: ScoutExtractResults, into ctx: ModelContext, flight: LandingSingleFlight,
                        sequence: Int? = nil) async -> ScoutService.Outcome {
        await ScoutExtractIngest.ingest(r, clients: [], history: [], blocked: .empty,
                                        today: ScoutTestClock.beforeAllFixtures, now: now,
                                        landings: flight, sequence: sequence, sequenceFloor: { 0 }, into: ctx)
    }

    // MARK: - Waiting, and both landing

    // An ingest arriving while a landing holds the store waits behind it, and so does a run Dan pressed;
    // when the store is released the Dan action goes first, and both land whole.
    @Test func landingsArrivingWhileTheStoreIsHeldWaitAndThenBothLand() async throws {
        let c = try container()
        let ctx = c.mainContext
        feed("feed-a", in: ctx)
        htmlSource(in: ctx)
        try ctx.save()
        let deadlines = Deadlines()
        let flight = LandingSingleFlight(sleep: { await deadlines.sleep($0) })
        let holder = try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(1))

        let scoutIngest = Task { @MainActor in await ingest(Self.results("waited"), into: ctx, flight: flight) }
        await waitUntil("the ingest queued") { flight.queue == [.scoutExtractIngest] }
        let press = Task { @MainActor in
            try await run(ctx, flight: flight, only: ["feed-a"],
                          extractor: { $0?.sourceId == "feed-a" ? ListedFeed(events: Self.events("pressed")) : nil },
                          // A press Dan made, which is also the only depth that honours `only` for the html
                          // sources: at watchOnly the sweep checks (and stamps) every fetchable source.
                          depth: .readChanged, priority: .danAction)
        }
        await waitUntil("the press's landing queued ahead of the ingest") {
            flight.queue == [.runScoutLanding, .scoutExtractIngest]
        }
        #expect(try titles(ctx).isEmpty, "a landing applied while another held the store")

        holder.end()
        let pressed = try await press.value
        let waited = await scoutIngest.value
        #expect(pressed.inserted == 3)
        #expect(waited.inserted == 2)
        #expect(waited.notLandedYet == nil)
        let stored = try titles(ctx)
        #expect(stored.filter { $0.contains("pressed") }.count == 3)
        #expect(stored.filter { $0.contains("waited") }.count == 2)
        #expect(!flight.isHeld)
        deadlines.passAll()
    }

    // The regression the earlier design would have shipped: runScout's token must end when runScout
    // returns, so the detached read's own ingest on the ordinary follow path is never refused by its parent.
    // Every deadline here passes AT ONCE, so any wait at all is a refusal.
    @Test func theDetachedReadsIngestOnTheFollowPathIsNeverRefusedByItsParentRun() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })

        let native = try await run(ctx, flight: flight, only: ["org"], depth: .readChanged, fetch: { url, _, _ in
            FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "new")
        })
        #expect(native.sources.contains { $0.state == .queuedForReading })
        #expect(!flight.isHeld, "runScout returned still holding the store")

        let followed = await ingest(Self.results("followed"), into: ctx, flight: flight)
        #expect(followed.notLandedYet == nil, Comment(rawValue:
            "the follow path's ingest was refused: \(followed.notLandedYet ?? "")"))
        #expect(try titles(ctx).filter { $0.contains("followed") }.count == 2)
        let source = try #require(try ctx.fetch(FetchDescriptor<WatchedSource>()).first)
        #expect(source.lastContentHash == "new", "the followed read's page hash was not promoted")
    }

    // A Run press while a landing holds the store (standing in for A6's recovery suspended on its re-read)
    // is acknowledged in the decided words, waits, and runs after the landing ends.
    @Test func aRunPressWhileALandingHoldsTheStoreIsAcknowledgedWaitsAndThenRuns() async throws {
        let c = try container()
        let ctx = c.mainContext
        feed("feed-a", in: ctx)
        try ctx.save()
        let deadlines = Deadlines()
        let flight = LandingSingleFlight(sleep: { await deadlines.sleep($0) })
        let holder = try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(1))

        var acknowledged: [String] = []
        var started = false
        let press = Task { @MainActor in
            try await flight.waitForTurnToStartARun(acknowledge: { acknowledged.append($0) })
            started = true
            return try await run(ctx, flight: flight, only: ["feed-a"],
                                 extractor: { _ in ListedFeed(events: Self.events("after")) }, priority: .danAction)
        }
        await waitUntil("the press is waiting") { flight.queue == [.runPress] }
        #expect(acknowledged == [LandingWaitCopy.runPressWaiting])
        #expect(LandingWaitCopy.runPressWaiting == "Your scout will start as soon as the landing in progress finishes.")
        #expect(!started, "the press started its sweep while a landing held the store")

        holder.end()
        let outcome = try await press.value
        #expect(started)
        #expect(outcome.inserted == 3)
        #expect(acknowledged.count == 1)
        deadlines.passAll()
    }

    @Test func aRunPressOnAFreeStoreSaysNothingAndGoesStraightOn() async throws {
        let flight = LandingSingleFlight(sleep: { _ in })
        var acknowledged: [String] = []
        try await flight.waitForTurnToStartARun(acknowledge: { acknowledged.append($0) })
        #expect(acknowledged.isEmpty)
        #expect(!flight.isHeld)
    }

    // MARK: - Only store work holds the token (L110)

    // A paste submitted while runScout is suspended in its fetch loop lands immediately, because the sweep
    // does not hold the store.
    @Test func aPasteLandsImmediatelyWhileTheSweepIsSuspendedInItsFetchLoop() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })
        let gate = Gate()

        let sweep = Task { @MainActor in
            try await run(ctx, flight: flight, only: ["org"], fetch: { url, _, _ in
                await gate.wait()
                return FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "old")
            })
        }
        await waitUntil("the sweep is suspended in its fetch") { gate.entered == 1 }
        #expect(!flight.isHeld, "the network sweep holds the store")

        try await pasteALead(into: ctx)
        #expect(try titles(ctx).contains { $0.contains("Pasted") }, "the paste did not land while the sweep was fetching")

        gate.open()
        _ = try await sweep.value
    }

    // And while runScout waits on the read budget question, which Dan can leave open as long as he likes.
    @Test func aPasteLandsImmediatelyWhileTheRunWaitsOnTheReadBudgetQuestion() async throws {
        let c = try container()
        let ctx = c.mainContext
        let ids = (0...ScoutReadBudget.askAbove).map { "org-\($0)" }
        for id in ids { htmlSource(id, in: ctx) }
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })
        let gate = Gate()

        let sweep = Task { @MainActor in
            try await run(ctx, flight: flight, only: Set(ids), depth: .readChanged, fetch: { url, _, _ in
                FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "new")
            }, askReadBudget: { _ in
                await gate.wait()
                return .all
            })
        }
        await waitUntil("the run is waiting on the read budget question") { gate.entered == 1 }
        #expect(!flight.isHeld, "the read budget question holds the store")

        try await pasteALead(into: ctx)
        #expect(try titles(ctx).contains { $0.contains("Pasted") })

        gate.open()
        _ = try await sweep.value
        #expect(!flight.isHeld)
    }

    // The tail (after the question) saves what it wrote under its own short token: the fairness clock is on
    // disk, read through a fresh context, with nothing left for autosave.
    @Test func theTailSavesTheFairnessClockUnderItsOwnToken() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })

        _ = try await run(ctx, flight: flight, only: ["org"], depth: .readChanged, fetch: { url, _, _ in
            FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "new")
        })
        #expect(!ctx.hasChanges, "the tail left writes pending for autosave")
        let fresh = ModelContext(c)
        let row = try #require(try fresh.fetch(FetchDescriptor<WatchedSource>()).first)
        #expect(row.lastManualReadAt == now)
    }

    private func pasteALead(into ctx: ModelContext) async throws {
        let html = String(repeating: "<p>Pasted Ensemble presents an evening of chamber music at Merkin Hall. </p>", count: 12)
        let model = LeadIntakeModel(
            defaults: ScratchDefaults.make("ScoutLandingsWaitTheirTurnTests-paste"),
            fetch: { url in FetchedPage(normalizedHTML: html, finalURL: url.absoluteString, contentHash: "p") },
            pin: { _, _ in URL(fileURLWithPath: "/tmp/pinned.html") },
            launch: { _ in },
            readResults: { id in
                ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z", results: [
                    ScoutExtractResult(sourceId: id, verdict: .upcomingListings, events: [
                        ScoutExtractEvent(title: "Pasted Ensemble", presenter: "Pasted Ensemble",
                                          venue: "Merkin Hall", performanceDate: Self.night(30),
                                          sourceUrl: "https://pasted.example/1")
                    ], note: nil)])
            })
        model.urlText = "https://pasted.example/events"
        await model.start(into: ctx, now: now, today: ScoutTestClock.beforeAllFixtures, sleep: { _ in })
        guard case .added(let n, _) = model.phase, n > 0 else {
            Issue.record("the paste did not land: \(model.phase)")
            return
        }
    }

    // MARK: - Re-validation against lastTouchedSequence

    // A source a later run landed after this run read it is set aside whole and reported by name.
    @Test func aSourceALaterRunLandedFirstIsSetAsideAndReported() async throws {
        let c = try container()
        let ctx = c.mainContext
        feed("feed-x", in: ctx)
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })
        let gate = Gate()

        let older = Task { @MainActor in
            try await run(ctx, flight: flight, only: ["feed-x"],
                          extractor: { _ in GatedFeed(events: Self.events("older"), gate: gate) })
        }
        await waitUntil("the older run is reading") { gate.entered == 1 }
        let newer = try await run(ctx, flight: flight, only: ["feed-x"],
                                  extractor: { _ in ListedFeed(events: Self.events("newer")) })
        #expect(newer.inserted == 3)
        gate.open()
        let set = try await older.value

        let result = try #require(set.sources.first { $0.sourceId == "feed-x" })
        #expect(result.state == .superseded, Comment(rawValue: "the older reading was reported as \(result.state)"))
        #expect(!(try titles(ctx)).contains { $0.contains("older") }, "the older reading was landed over the newer one")
        #expect(set.warning?.contains("superseded by a later run") == true)
        let warnings = ScoutWarnings.from(native: set, extract: nil, finishedEmpty: nil)
        #expect(warnings.sections.contains(.superseded([result])))
    }

    // The same rule for an ingest, and the part that makes it lose nothing: a set aside page's hash is not
    // promoted, so the next scout reads it again.
    @Test func anIngestOlderThanTheSourcesLastLandingPromotesNothing() async throws {
        let c = try container()
        let ctx = c.mainContext
        let s = htmlSource(in: ctx)
        s.pendingContentHash = "pending"
        s.hasUnreadChanges = true
        s.lastTouchedSequence = 10
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })

        let outcome = await ingest(Self.results("stale"), into: ctx, flight: flight, sequence: 5)

        #expect(outcome.sources.first?.state == .superseded)
        #expect(try titles(ctx).isEmpty)
        #expect(s.lastContentHash == "old")
        #expect(s.pendingContentHash == "pending")
        #expect(s.hasUnreadChanges)
        #expect(s.lastTouchedSequence == 10)
    }

    @Test func aLandingStampsEverySourceItLandsWithItsSequence() async throws {
        let c = try container()
        let ctx = c.mainContext
        let a = feed("feed-a", in: ctx)
        let s = htmlSource(in: ctx)
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })

        _ = try await run(ctx, flight: flight, only: ["feed-a", "org"],
                          extractor: { $0?.sourceId == "feed-a" ? ListedFeed(events: Self.events("a")) : nil })
        #expect(a.lastTouchedSequence == 1)
        #expect(s.lastTouchedSequence == 1, "a settled source was not stamped")
        _ = await ingest(Self.results("b"), into: ctx, flight: flight)
        #expect(s.lastTouchedSequence == 2)
    }

    // MARK: - A refused ingest loses nothing (L665)

    // Refused at its deadline, the ingest's results are kept by content hash. A second extract run then
    // rewrites the reader's results file and lands. Offered again from its OWN copy, the first run's
    // shows still land. The second run reads a DIFFERENT calendar: had it landed the same one, the first
    // run's reading would be the older of the two and set aside as superseded, which is the re-validation
    // doing its job (`anIngestOlderThanTheSourcesLastLandingPromotesNothing`).
    @Test func anIngestRefusedAtItsDeadlineKeepsItsResultsAndTheyLandWhenOffered() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        htmlSource("org2", in: ctx)
        try ctx.save()
        let dir = try sandboxes.make(named: "pending-ingests")
        let pending = PendingScoutIngests(directory: dir.appendingPathComponent("pending"))
        let resultsFile = dir.appendingPathComponent("overture-scout-extract-results.json")
        let flight = LandingSingleFlight(sleep: { _ in })
        let holder = try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(1))

        try JSONEncoder().encode(Self.results("first")).write(to: resultsFile)
        let firstData = try Data(contentsOf: resultsFile)
        let refused = await ScoutExtractLanding.land(
            firstData, try ScoutExtractResultsDecoder.decode(firstData), clients: [], history: [], blocked: .empty,
            today: ScoutTestClock.beforeAllFixtures, now: now, landings: flight, pending: pending, into: ctx)
        #expect(refused.outcome.notLandedYet?.contains("kept a copy") == true, Comment(rawValue:
            "the refusal said: \(refused.outcome.notLandedYet ?? "nothing")"))
        #expect(try titles(ctx).isEmpty)
        #expect(FileManager.default.fileExists(atPath: resultsFile.path), "the results file was discarded on refusal")
        #expect(try pending.list().count == 1)
        let warnings = ScoutWarnings.from(native: ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0),
                                          extract: refused.outcome, finishedEmpty: nil)
        #expect(warnings.sections.first == .notLandedYet(refused.outcome.notLandedYet!))

        // The next extract run rewrites the reader's file and lands normally.
        holder.end()
        try JSONEncoder().encode(Self.results("second", sourceId: "org2")).write(to: resultsFile)
        let secondData = try Data(contentsOf: resultsFile)
        let second = await ScoutExtractLanding.land(
            secondData, try ScoutExtractResultsDecoder.decode(secondData), clients: [], history: [], blocked: .empty,
            today: ScoutTestClock.beforeAllFixtures, now: now, landings: flight, pending: pending, into: ctx)
        #expect(second.outcome.notLandedYet == nil)
        #expect(try pending.list().count == 1, "landing without a wait recorded or removed a copy it never kept")

        let offered = await ScoutExtractLanding.offerPending(clients: [], history: [], blocked: .empty, now: now,
                                                            landings: flight, pending: pending, into: ctx)
        #expect(offered.landed.count == 1)
        let stored = try titles(ctx)
        #expect(stored.filter { $0.contains("first") }.count == 2, Comment(rawValue:
            "the first run's shows did not land from its copy: \(stored)"))
        #expect(stored.filter { $0.contains("second") }.count == 2)
        #expect(try pending.list().isEmpty, "the copy was not removed once it landed")
    }

    // L5, L665: a kept copy is removed only once the save carrying its results has succeeded. A landing
    // whose closing save fails never reached disk, so its copy is the only record left: kept, reported as
    // not landed, and landed by a later offer.
    @Test func aKeptCopyWhoseLandingFailedToSaveIsKeptAndLandsOnALaterOffer() async throws {
        struct SaveRefused: Error {}
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let dir = try sandboxes.make(named: "pending-save-failed")
        let pending = PendingScoutIngests(directory: dir)
        try pending.record(try JSONEncoder().encode(Self.results("unsaved")), sequence: 1, now: now)
        let flight = LandingSingleFlight(sleep: { _ in })

        let failed = await ScoutExtractLanding.offerPending(clients: [], history: [], blocked: .empty, now: now,
                                                           landings: flight, pending: pending,
                                                           saveClosing: { _ in throw SaveRefused() }, into: ctx)
        #expect(failed.landed.isEmpty, "a landing whose save failed was counted as landed")
        #expect(try pending.list().count == 1, "the only copy of results that never reached disk was deleted")

        let offered = await ScoutExtractLanding.offerPending(clients: [], history: [], blocked: .empty, now: now,
                                                            landings: flight, pending: pending, into: ctx)
        #expect(offered.landed.count == 1)
        #expect(try ModelContext(c).fetch(FetchDescriptor<Prospect>()).map(\.groupName).filter { $0.contains("unsaved") }.count == 2)
        #expect(try pending.list().isEmpty)
    }

    // L94: the single warning string never drops "kept, will be offered again" behind a higher part. The
    // early returns ahead of it (the save failure, and the reader that could not be launched) each carry it.
    @Test func theWarningKeepsTheNotLandedLineBesideTheLinesAheadOfIt() {
        let refused = LandingWaitCopy.refused(.scoutExtractIngest, waited: .seconds(1_800))
        var launch = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
        launch.extractLaunchFailure = "The reader is not set up."
        launch.notLandedYet = refused
        #expect(launch.warning?.contains("The reader is not set up.") == true)
        #expect(launch.warning?.contains(refused) == true, Comment(rawValue: launch.warning ?? "nil"))
        var save = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
        save.saveFailed = true
        save.notLandedYet = refused
        #expect(save.warning?.contains(ScoutWarningCopy.saveFailed) == true)
        #expect(save.warning?.contains(refused) == true, Comment(rawValue: save.warning ?? "nil"))
    }

    // L11: an ingest stopped before it ever waited attempted no copy, so it must not be told a copy failed.
    // Its results are still in the reader's file, which is what it says.
    @Test func anIngestStoppedBeforeItWaitedIsNotBlamedOnACopy() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let dir = try sandboxes.make(named: "pending-stopped")
        let pending = PendingScoutIngests(directory: dir)
        let flight = LandingSingleFlight(sleep: { _ in })
        let holder = try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(1))
        let data = try JSONEncoder().encode(Self.results("stopped"))
        let results = try ScoutExtractResultsDecoder.decode(data)
        let now = self.now
        let stopped = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await ScoutExtractLanding.land(data, results, clients: [], history: [], blocked: .empty,
                                                  today: ScoutTestClock.beforeAllFixtures, now: now,
                                                  landings: flight, pending: pending, into: ctx)
        }
        let landed = await stopped.value
        #expect(landed.outcome.notLandedYet == LandingWaitCopy.ingestStoppedBeforeItWaited,
                Comment(rawValue: landed.outcome.notLandedYet ?? "nil"))
        #expect(landed.outcome.notLandedYet?.contains("could not keep") != true)
        #expect(try pending.list().isEmpty)
        holder.end()
    }

    // L10: a leftover temporary folder that cannot be moved into place is reported by name, never retried
    // unseen.
    @Test func aTemporaryFolderThatCannotBeMovedIntoPlaceIsReported() throws {
        let dir = try sandboxes.make(named: "pending-stuck-move")
        let fm = FileManager.default
        let data = try JSONEncoder().encode(Self.results("blocked"))
        let hash = PendingScoutIngests.contentHash(of: data)
        let incoming = dir.appendingPathComponent(".incoming-blocked", isDirectory: true)
        try fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        try data.write(to: incoming.appendingPathComponent("results.json"))
        // The destination is a folder whose contents cannot be removed, so the move cannot happen.
        let destination = dir.appendingPathComponent(hash, isDirectory: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: destination.appendingPathComponent("pinned"))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: destination.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: destination.path) }

        let listed = try PendingScoutIngests(directory: dir).list()
        #expect(listed.contains { if case .unreadable(let path, _) = $0 { return path == incoming.path }; return false },
                Comment(rawValue: "the folder that could not be moved was not reported: \(listed)"))
        #expect(fm.fileExists(atPath: incoming.appendingPathComponent("results.json").path),
                "the results were lost when the move failed")
    }

    // A kept copy that keeps being refused for longer than a scout interval is STUCK, not waiting.
    @Test func aKeptCopyOlderThanAScoutIntervalIsReportedStuck() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let dir = try sandboxes.make(named: "pending-stuck")
        let pending = PendingScoutIngests(directory: dir)
        let data = try JSONEncoder().encode(Self.results("stuck"))
        try pending.record(data, sequence: 1, now: now.addingTimeInterval(-2 * ScoutSchedule.defaultInterval))
        try pending.record(try JSONEncoder().encode(Self.results("fresh")), sequence: 2, now: now)
        let flight = LandingSingleFlight(sleep: { _ in })
        let holder = try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(1))

        let offered = await ScoutExtractLanding.offerPending(clients: [], history: [], blocked: .empty, now: now,
                                                            landings: flight, pending: pending, into: ctx)
        #expect(offered.stuck == 1)
        #expect(offered.stuckAfter == ScoutSchedule.defaultInterval)
        #expect(offered.stillWaiting == 1)
        #expect(offered.landed.isEmpty)
        #expect(try pending.list().count == 2, "a refused offer lost its copy")
        #expect(LandingWaitCopy.offered(landed: 0, stillWaiting: 1, stuck: 1,
                                        stuckAfter: offered.stuckAfter)?.contains("stuck") == true)
        holder.end()
    }

    // L617: a copy is written whole or not at all, so nothing half written is left behind.
    @Test func recordingACopyLeavesOnlyTheFinishedFolder() throws {
        let dir = try sandboxes.make(named: "pending-atomic")
        let pending = PendingScoutIngests(directory: dir)
        let data = try JSONEncoder().encode(Self.results("whole"))
        let entry = try pending.record(data, sequence: 4, now: now)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == [entry.contentHash], Comment(rawValue: "left behind: \(names)"))
        #expect(try pending.list() == [.entry(entry)])
    }

    // A folder holding the results and no entry (a crash between the two writes, before this was atomic)
    // is recovered and offered, never stranded as unreadable on every sweep. It is recovered as the OLDEST
    // reading there can be (sequence 0), since its real sequence was never recorded, so it can never land
    // over a source any run has landed since.
    @Test func aCopyWhoseEntryWasNeverWrittenIsRecoveredAndOffered() async throws {
        let c = try container()
        let ctx = c.mainContext
        htmlSource(in: ctx)
        try ctx.save()
        let dir = try sandboxes.make(named: "pending-orphan")
        let pending = PendingScoutIngests(directory: dir)
        let data = try JSONEncoder().encode(Self.results("orphan"))
        let hash = PendingScoutIngests.contentHash(of: data)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(hash), withIntermediateDirectories: true)
        try data.write(to: pending.resultsURL(hash))

        let listed = try pending.list()
        guard case .entry(let recovered) = listed.first, listed.count == 1 else {
            Issue.record("a results-only folder was not recovered: \(listed)")
            return
        }
        #expect(recovered.contentHash == hash)
        #expect(recovered.sequence == 0)

        let flight = LandingSingleFlight(sleep: { _ in })
        let offered = await ScoutExtractLanding.offerPending(clients: [], history: [], blocked: .empty, now: now,
                                                            landings: flight, pending: pending, into: ctx)
        #expect(offered.landed.count == 1)
        #expect(try titles(ctx).filter { $0.contains("orphan") }.count == 2)
        #expect(try pending.list().isEmpty)
    }

    // A copy written in full into its temporary folder and never moved into place is moved, not lost.
    @Test func aCopyLeftInItsTemporaryFolderIsMovedIntoPlace() throws {
        let dir = try sandboxes.make(named: "pending-incoming")
        let staging = try sandboxes.make(named: "pending-incoming-staging")
        let data = try JSONEncoder().encode(Self.results("staged"))
        let entry = try PendingScoutIngests(directory: staging).record(data, sequence: 9, now: now)
        try FileManager.default.moveItem(at: staging.appendingPathComponent(entry.contentHash),
                                         to: dir.appendingPathComponent(".incoming-interrupted"))
        let pending = PendingScoutIngests(directory: dir)

        #expect(try pending.list() == [.entry(entry)])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names == [entry.contentHash], Comment(rawValue: "left behind: \(names)"))
    }

    @Test func aNewSequenceIsMintedAboveEveryKeptCopy() throws {
        let dir = try sandboxes.make(named: "pending-floor")
        let pending = PendingScoutIngests(directory: dir)
        #expect(pending.highestSequence == 0)
        try pending.record(Data("a".utf8), sequence: 7, now: now)
        try pending.record(Data("b".utf8), sequence: 3, now: now)
        #expect(pending.highestSequence == 7)
        #expect(LandingSingleFlight(sleep: { _ in }).mintSequence(above: pending.highestSequence) == 8)
    }

    // MARK: - The #1027 guard stays what it was

    // "A scout run is in flight" is still RootView's own guard, unchanged, and is not the landing
    // predicate: a double press starts one run.
    @Test func theRunInFlightGuardIsUnchanged() throws {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        let body = try #require(SourceGuardHelper.bodyOfFunction(named: "runScout", in: root))
        #expect(SourceGuardHelper.containsCode("guard !isScanning, readingStartedAt == nil else { return }", in: body))
        #expect(body.contains("ScoutStartGate.decide("))
        #expect(!body.contains("LandingSingleFlight.shared.isHeld"),
                "the landing predicate was lifted into the run in flight guard")
    }
}
