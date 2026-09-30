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
        #expect(offered.stillWaiting == 1)
        #expect(offered.landed.isEmpty)
        #expect(try pending.list().count == 2, "a refused offer lost its copy")
        #expect(LandingWaitCopy.offered(landed: 0, stillWaiting: 1, stuck: 1)?.contains("stuck") == true)
        holder.end()
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
