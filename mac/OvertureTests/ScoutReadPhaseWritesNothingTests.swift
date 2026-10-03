import Testing
import Foundation
import SwiftData

// #4329 (A12): the read phase of each scout entry point writes nothing, and the landing saves everything it
// writes. The runtime half of the rule, in the direction the source scan (`ScoutReadPhaseWriteScanTests`)
// cannot see: calls through a value, an injected closure, anything a name does not reveal.
//
// Each entry point is driven with fakes through EVERY branch that writes (`SourceWrites.Site`), and
// `context.hasChanges` is read at every read-phase await the fakes can reach (each fetch, each extract, the
// Squarespace probe), at the end of the read phase (the landing waiting for a store the test holds), and
// across the read budget question, where `ScopeMemo` must still serve a refetch. A coverage check fails when
// a branch was not reached, so a fake that stopped driving one cannot make this pass about less.
//
// #4456: and every SAVE made into the store through the read phase is counted (`ReadPhaseSaves`). `hasChanges`
// cannot see a write made before the read phase's first await: the entry flush (`ScoutService.flushBeforeLanding`)
// saves it before the background corpus read, so the context is clean again at every await the fakes stand at
// and at the end. Measured 2026-10-02 by #4335's agent: a `LandingRun` inserted at the sequence mint left this
// suite green. A read phase that writes nothing saves nothing, so the count must be zero.
//
// Every flight here is the test's own (L524), so a store held across a suspension cannot make another test's
// landing wait, and no deadline waits in real time.

@MainActor
private final class HeldDeadlines {
    private var pending: [CheckedContinuation<Void, Never>] = []
    func sleep(_ d: Duration) async { await withCheckedContinuation { pending.append($0) } }
    func passAll() {
        let all = pending
        pending = []
        all.forEach { $0.resume() }
    }
}

// Every `context.hasChanges` the fakes read, labelled with where.
@MainActor
private final class Probe {
    private(set) var dirty: [String] = []
    private(set) var reads = 0
    let context: ModelContext
    init(_ context: ModelContext) { self.context = context }
    func read(_ label: String) {
        reads += 1
        if context.hasChanges { dirty.append(label) }
    }
}

// #4456: every save made into ONE store from the moment this is made, through any of its contexts. Made after the
// fixture's own save, so anything it counts was saved by the code under test. `StoreSaveCount` is the app's own
// per container count of `ModelContext.didSave`, made fresh here so no other store's saves are read.
@MainActor
private final class ReadPhaseSaves {
    private let counter = StoreSaveCount(center: .default)
    private let container: ModelContainer
    init(_ container: ModelContainer) { self.container = container }
    var count: Int { counter.value(for: container) }
}

private struct FeedThat: SourceExtractor {
    let events: [ExtractedEvent]
    let fails: Bool
    let probe: Probe
    let label: String
    func extract() async throws -> ExtractedListing {
        await probe.read("extract \(label)")
        if fails { throw SourceFetchError.unreachable }
        return ExtractedListing(events: events, verdict: .upcomingListings)
    }
}

@MainActor
@Suite("A scout's read phase writes nothing and its landing saves everything it writes (#4329)")
struct ScoutReadPhaseWritesNothingTests {
    private let now = Date()

    private func container() throws -> ModelContainer {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        // Nothing may reach the store except through a save the landing makes (L12).
        c.mainContext.autosaveEnabled = false
        return c
    }

    private func night(_ n: Int) -> String {
        EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 30 + n, to: now)!)
    }

    private func events(_ label: String, count: Int = 2) -> [ExtractedEvent] {
        (0..<count).map { k in
            ExtractedEvent(title: "Quartet \(label) \(k)", presenter: "Quartet \(label) \(k) Presents",
                           venue: "Venue \(k) Hall", performanceDate: night(k),
                           sourceUrl: "https://\(label).example/e\(k)", location: "New York, NY")
        }
    }

    @discardableResult
    private func html(_ id: String, in ctx: ModelContext, address: Bool = true) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)",
                              listingsURL: address ? "https://\(id).example/events" : nil, kind: .html)
        s.venueLocation = "New York, NY"
        s.lastContentHash = "old"
        ctx.insert(s)
        return s
    }

    @discardableResult
    private func feed(_ id: String, in ctx: ModelContext) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Feed \(id)", listingsURL: "https://\(id).example/", kind: .algolia)
        ctx.insert(s)
        return s
    }

    // The fields a read phase used to write, as a fresh context reads them back.
    private struct Written: Equatable, CustomStringConvertible {
        let id: String, health: String, lastError: String?, streak: Int, checkedAt: Date?, unread: Bool
        let pending: String?, months: String, ticketing: String?, kind: String, notes: String?
        let contentHash: String?, observed: String?, insecure: Bool, sequence: Int
        init(_ s: WatchedSource) {
            id = s.sourceId; health = s.healthRaw; lastError = s.lastErrorRaw; streak = s.failedReadStreak
            checkedAt = s.lastCheckedAt; unread = s.hasUnreadChanges; pending = s.pendingContentHash
            months = s.pendingPageMonthsRaw; ticketing = s.ticketingFeedURL; kind = s.kindRaw; notes = s.notes
            contentHash = s.lastContentHash; observed = s.lastObservedContentHash
            insecure = s.lastFetchWasInsecure; sequence = s.lastTouchedSequence
        }
        var description: String { "\(id) health=\(health) streak=\(streak) unread=\(unread) pending=\(pending ?? "nil") kind=\(kind) seq=\(sequence)" }
    }

    private func written(_ ctx: ModelContext) throws -> [Written] {
        try ctx.fetch(FetchDescriptor<WatchedSource>()).map(Written.init).sorted { $0.id < $1.id }
    }

    // A refetch with nothing unsaved is served, the condition `ScopeMemo` reads (`!main.hasChanges`). Built
    // over the shows in the store at the moment it is asked, so it answers about the store as Dan's screen
    // would see it at that moment.
    private func memoServesARefetch(_ c: ModelContainer) throws -> Bool {
        let rows = try c.mainContext.fetch(FetchDescriptor<Prospect>())
        let memo = ScopeMemo<String>(saves: StoreSaveCount(center: .default))
        func evaluate() {
            var key = ScopeFingerprint()
            key.add(rows)
            _ = memo.value(fingerprint: key, cardKeys: [], now: now, staleAfter: .never, savesIn: c,
                           onRefetch: .serveWhenNothingChanged) { rows.map(\.groupName).joined() }
        }
        evaluate()
        for row in rows { row.withMutation(keyPath: \.groupName) {} }
        evaluate()
        return memo.servedUnchanged == 1
    }

    private static let squarespaceCollection = Data(#"{"collection":{"typeName":"events"}}"#.utf8)

    // MARK: - runScout

    @Test func runScoutsReadPhaseWritesNothingAndItsLandingSavesWhatItWrote() async throws {
        let c = try container()
        let ctx = c.mainContext
        let probe = Probe(ctx)

        feed("feed-listed", in: ctx)
        feed("feed-broken", in: ctx)                          // nativeReadFailed
        html("inline", in: ctx)                               // readInline, with a ticketing feed
        html("squarespace", in: ctx)                          // promotedToSquarespace
        html("down", in: ctx)                                 // fetchFailed
        html("noaddress", in: ctx, address: false)            // noUsableAddress
        html("quiet", in: ctx)                                // pageUnchanged
        let retry = html("retry", in: ctx)                    // pageUnchangedRereadOwed, queuedForReading
        retry.lastFailure = .fetch(.http(500))
        retry.health = .failing
        // pageChanged and queuedForReading, enough of them that the read budget question is asked (#1498).
        let changed = (0...ScoutReadBudget.askAbove).map { "changed-\($0)" }
        for id in changed { html(id, in: ctx) }
        try ctx.save()
        #expect(!ctx.hasChanges, "the fixture itself left the context dirty, so nothing below would mean anything")
        let saves = ReadPhaseSaves(c)

        let ovationTix = Data("""
            [{"date":"\(night(1))","productions":[{"productionId":1,"name":"Bone Wars"}]}]
            """.utf8)
        let deadlines = HeldDeadlines()
        let flight = LandingSingleFlight(sleep: { await deadlines.sleep($0) })
        let holder = try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(1))

        var applied: [SourceWrites.Site] = []
        var askedWhileClean: Bool?
        var memoServed: Bool?
        var launched: [String] = []
        let run = Task { @MainActor in
            try await ScoutService.runScout(
                into: ctx, depth: .readChanged,
                extractorRegistry: { source in
                    guard let source, source.kind == .algolia else { return nil }
                    return FeedThat(events: events(source.sourceId), fails: source.sourceId == "feed-broken",
                                    probe: probe, label: source.sourceId)
                },
                fetch: { url, _, _ in
                    let host = url.host ?? ""
                    await probe.read("fetch \(host)")
                    switch host {
                    case "down.example":
                        throw SourceFetchError.http(503)
                    case "quiet.example", "retry.example":
                        return FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "old")
                    case "squarespace.example":
                        return FetchedPage(normalizedHTML: "<script src=\"https://static1.squarespace.com/x.js\"></script>",
                                           finalURL: url.absoluteString, contentHash: "sq-new")
                    case "inline.example":
                        return FetchedPage(normalizedHTML: "<p/>", finalURL: "https://web.ovationtix.com/trs/cal/277",
                                           contentHash: "inline-new",
                                           followedTicketLinkFrom: url.absoluteString,
                                           ticketingFeedURL: "https://web.ovationtix.com/trs/cal/277",
                                           ticketingFeedJSON: ovationTix)
                    default:
                        return FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "new-\(host)")
                    }
                },
                pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
                launch: { items in launched = items.map(\.sourceId) },
                now: now, defaults: ScratchDefaults.make("ScoutReadPhaseWritesNothingTests"),
                askReadBudget: { _ in
                    askedWhileClean = !ctx.hasChanges
                    memoServed = try? memoServesARefetch(c)
                    return .all
                },
                landings: flight, sequenceFloor: { 0 },
                squarespaceProbe: { _ in
                    await probe.read("squarespace probe")
                    return Self.squarespaceCollection
                },
                onApplyCaptured: { applied += $0.sites })
        }
        // The end of the read phase: every source read, the landing waiting for the store the test holds.
        await waitUntil("the run's landing is waiting for the store") { flight.queue == [.runScoutLanding] }
        #expect(!ctx.hasChanges, "runScout's read phase left writes pending in the main context at its end")
        #expect(saves.count == 0, Comment(rawValue:
            "runScout's read phase saved \(saves.count) times into the store before its landing took it"))
        #expect(probe.reads >= changed.count + 6, Comment(rawValue:
            "the fakes read the context \(probe.reads) times, fewer than the awaits they stand at"))
        #expect(probe.dirty.isEmpty, Comment(rawValue:
            "the main context held unsaved writes at these read-phase awaits: " + probe.dirty.joined(separator: ", ")))

        holder.end()
        let outcome = try await run.value
        deadlines.passAll()

        #expect(askedWhileClean == true, "the read budget question was asked with the landing's writes unsaved (save one must come before it)")
        #expect(memoServed == true, "ScopeMemo could not serve a refetch while the read budget question was open")
        #expect(!outcome.saveFailed)
        #expect(!flight.isHeld)
        #expect(launched.count == changed.count + 1, "the changed pages and the owed retry were not all handed to the reader")

        // Every branch that writes in runScout's read phase was driven by a fake.
        let runScoutSites: Set<SourceWrites.Site> = [
            .fetchFailed, .pageUnchanged, .pageUnchangedRereadOwed, .pageChanged, .noUsableAddress,
            .queuedForReading, .promotedToSquarespace, .readInline, .nativeReadFailed,
        ]
        #expect(Set(applied) == runScoutSites, Comment(rawValue:
            "runScout's landing applied writes from \(Set(applied).map(\.rawValue).sorted()), not every branch"))

        // Nothing left for autosave, and a fresh context reads every value the landing wrote.
        #expect(!ctx.hasChanges, "runScout returned with writes pending")
        let mine = try written(ctx)
        let fresh = try written(ModelContext(c))
        #expect(fresh == mine, Comment(rawValue: "a fresh context reads \(fresh) where the run wrote \(mine)"))
        let rows = Dictionary(uniqueKeysWithValues: mine.map { ($0.id, $0) })
        #expect(rows["down"]?.health == SourceHealth.failing.rawValue && rows["down"]?.streak == 1)
        #expect(rows["noaddress"]?.streak == 1)
        #expect(rows["feed-broken"]?.streak == 1)
        #expect(rows["squarespace"]?.kind == SourceKind.squarespaceFeed.rawValue)
        #expect(rows["inline"]?.ticketing == "https://web.ovationtix.com/trs/cal/277")
        #expect(rows["inline"]?.pending == nil)
        #expect(rows["changed-0"]?.pending == "new-changed-0.example" && rows["changed-0"]?.unread == true)
        #expect(rows["retry"]?.pending == "old" && rows["retry"]?.health == SourceHealth.ok.rawValue)
        #expect(rows["quiet"]?.checkedAt == now && rows["quiet"]?.unread == false)
    }

    // MARK: - ScoutExtractIngest

    private func result(_ id: String, _ verdict: PageVerdict, events: Int = 0, note: String? = nil) -> ScoutExtractResult {
        ScoutExtractResult(sourceId: id, verdict: verdict, events: (0..<events).map { k in
            ScoutExtractEvent(title: "Recital \(id) \(k)", presenter: "Recital \(id) \(k)", venue: "Merkin Hall",
                              performanceDate: night(k), sourceUrl: "https://\(id).example/r\(k)")
        }, note: note)
    }

    @Test func theIngestsReadPhaseWritesNothingAndItsLandingSavesWhatItWrote() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("ing-ok", in: ctx).pendingContentHash = "ok-hash"
        html("ing-contra", in: ctx)                               // a run that contradicted itself (#857)
        html("ing-broken", in: ctx)                               // a broken verdict
        let quiet = html("ing-quiet", in: ctx)                    // a quiet page Dan confirmed (#1027)
        quiet.pendingContentHash = "q-hash"
        quiet.confirmedEmptyHash = "q-hash"
        try ctx.save()
        let saves = ReadPhaseSaves(c)

        let results = ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z", results: [
            result("ing-ok", .upcomingListings, events: 2, note: "read fine"),
            result("ing-contra", .unreadable, events: 1, note: "said unreadable"),
            result("ing-broken", .unreadable, note: "could not read it"),
            result("ing-quiet", .noDatedContent, note: "nothing dated"),
            result("nobody", .upcomingListings, events: 1),
        ])
        let deadlines = HeldDeadlines()
        let flight = LandingSingleFlight(sleep: { await deadlines.sleep($0) })
        let holder = try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(1))

        var applied: [SourceWrites.Site] = []
        let ingest = Task { @MainActor in
            await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty,
                                            today: ScoutTestClock.beforeAllFixtures, now: now,
                                            landings: flight, sequenceFloor: { 0 },
                                            onApplyCaptured: { applied += $0.sites }, into: ctx)
        }
        await waitUntil("the ingest's landing is waiting for the store") { flight.queue == [.scoutExtractIngest] }
        #expect(!ctx.hasChanges, "the ingest's read loop left writes pending in the main context at its end")
        #expect(saves.count == 0, Comment(rawValue:
            "the ingest's read phase saved \(saves.count) times into the store before its landing took it"))

        holder.end()
        let outcome = await ingest.value
        deadlines.passAll()

        #expect(!outcome.saveFailed)
        #expect(outcome.unqueuedResultIds == ["nobody"])
        #expect(Set(applied) == [.runNote, .readFailed, .confirmedEmpty], Comment(rawValue:
            "the ingest's landing applied writes from \(Set(applied).map(\.rawValue).sorted()), not every branch"))

        #expect(!ctx.hasChanges, "the ingest returned with writes pending")
        let mine = try written(ctx)
        let fresh = try written(ModelContext(c))
        #expect(fresh == mine, Comment(rawValue: "a fresh context reads \(fresh) where the ingest wrote \(mine)"))
        let rows = Dictionary(uniqueKeysWithValues: mine.map { ($0.id, $0) })
        #expect(rows["ing-contra"]?.notes?.contains("could not be read but still returned") == true)
        #expect(rows["ing-contra"]?.streak == 1 && rows["ing-contra"]?.unread == true)
        #expect(rows["ing-broken"]?.notes == "could not read it" && rows["ing-broken"]?.streak == 1)
        #expect(rows["ing-quiet"]?.contentHash == "q-hash" && rows["ing-quiet"]?.pending == nil)
        #expect(rows["ing-ok"]?.notes == "read fine" && rows["ing-ok"]?.contentHash == "ok-hash")
    }

    // Both entry points together drive every branch the app captures a write on, so a Site added without a
    // fake to reach it fails here rather than going unguarded.
    @Test func theTwoEntryPointsCoverEveryCaptureSite() {
        let runScout: Set<SourceWrites.Site> = [
            .fetchFailed, .pageUnchanged, .pageUnchangedRereadOwed, .pageChanged, .noUsableAddress,
            .queuedForReading, .promotedToSquarespace, .readInline, .nativeReadFailed,
        ]
        let ingest: Set<SourceWrites.Site> = [.runNote, .readFailed, .confirmedEmpty]
        #expect(runScout.union(ingest) == Set(SourceWrites.Site.allCases), Comment(rawValue:
            "no fake reaches \(Set(SourceWrites.Site.allCases).subtracting(runScout.union(ingest)).map(\.rawValue).sorted())"))
    }

    // MARK: - A write made before the first await (#4456)

    // The guard's own positive control, through the one closure the ingest calls before its first await (the
    // sequence floor, read at the mint). A row inserted there is saved by the entry flush before the corpus read,
    // so `hasChanges` reads clean at the end of the read phase, which is the blindness #4456 found; the save count
    // is what sees it. If this stops counting that one save, the zero the two tests above assert means nothing.
    @Test func aWriteMadeBeforeTheFirstAwaitIsCountedThoughTheContextReadsClean() async throws {
        let c = try container()
        let ctx = c.mainContext
        html("early", in: ctx)
        try ctx.save()
        let saves = ReadPhaseSaves(c)

        let deadlines = HeldDeadlines()
        let flight = LandingSingleFlight(sleep: { await deadlines.sleep($0) })
        let holder = try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(1))
        let results = ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                                          results: [result("early", .upcomingListings, events: 1, note: "read")])
        let ingest = Task { @MainActor in
            await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty,
                                            today: ScoutTestClock.beforeAllFixtures, now: now,
                                            landings: flight,
                                            sequenceFloor: {
                                                ctx.insert(LandingRun(runIdentity: "written-at-the-mint", landedAt: nil))
                                                return 0
                                            },
                                            into: ctx)
        }
        await waitUntil("the ingest's landing is waiting for the store") { flight.queue == [.scoutExtractIngest] }
        #expect(!ctx.hasChanges, "the entry flush did not save the early write, so this control shows nothing about #4456")
        #expect(saves.count == 1, Comment(rawValue:
            "a row inserted before the first await was saved \(saves.count) times in the read phase, where the guard needs it counted once"))

        holder.end()
        _ = await ingest.value
        deadlines.passAll()
    }

    // MARK: - A reading a later run overtook leaves the row untouched

    // ScoutExtractIngest.swift's old read loop wrote a superseded source's failure (health, notes, the streak)
    // before the landing block set the reading aside (found reviewing #4401). Now nothing reaches the row.
    @Test func anIngestOvertakenByALaterRunLeavesItsFailedReadOffTheRow() async throws {
        let c = try container()
        let ctx = c.mainContext
        let s = html("org", in: ctx)
        s.health = .ok
        s.notes = "the later run's note"
        s.lastTouchedSequence = 10
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })

        let outcome = await ScoutExtractIngest.ingest(
            ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                                results: [result("org", .unreadable, note: "an older failure")]),
            clients: [], history: [], blocked: .empty, today: ScoutTestClock.beforeAllFixtures, now: now,
            landings: flight, sequence: 5, sequenceFloor: { 0 }, into: ctx)

        #expect(outcome.sources.map(\.state) == [.superseded])
        #expect(s.health == .ok, "an overtaken reading's failure was written on the row")
        #expect(s.failedReadStreak == 0)
        #expect(s.notes == "the later run's note")
        #expect(s.hasUnreadChanges == false)
        #expect(s.lastTouchedSequence == 10)
        #expect(!ctx.hasChanges)
    }

    // The same for runScout: an older run whose fetch FAILED, overtaken by a newer run that read the page
    // fine, leaves the newer run's health on the row and does not hand the page to the reader.
    @Test func aRunOvertakenByALaterRunLeavesItsFailedFetchOffTheRow() async throws {
        let c = try container()
        let ctx = c.mainContext
        let s = html("org", in: ctx)
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })
        let gate = OpenableGate()

        func run(failing: Bool) async throws -> ScoutService.Outcome {
            try await ScoutService.runScout(
                into: ctx, depth: .readChanged, only: ["org"],
                fetch: { url, _, _ in
                    if failing {
                        await gate.wait()
                        throw SourceFetchError.http(500)
                    }
                    return FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "newer")
                },
                pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
                launch: { _ in },
                now: now, defaults: ScratchDefaults.make("ScoutReadPhaseWritesNothingTests-overtaken"),
                landings: flight, sequenceFloor: { 0 })
        }
        let older = Task { @MainActor in try await run(failing: true) }
        await waitUntil("the older run is fetching") { gate.entered == 1 }
        _ = try await run(failing: false)
        #expect(s.health == .ok && s.pendingContentHash == "newer", "the newer run did not land its reading")
        let newerSequence = s.lastTouchedSequence

        gate.open()
        let set = try await older.value
        #expect(set.sources.first { $0.sourceId == "org" }?.state == .superseded)
        #expect(s.health == .ok, "the overtaken run's failed fetch was written over the newer run's health")
        #expect(s.failedReadStreak == 0)
        #expect(s.pendingContentHash == "newer")
        #expect(s.lastTouchedSequence == newerSequence)
    }

    // An older run that found the page CHANGED, overtaken before it landed, does not hand that page to the
    // reader: its pending hash was dropped with the rest of its writes, so an ingest of it would promote the
    // newer run's hash for bytes the newer run never read.
    @Test func aRunOvertakenByALaterRunDoesNotHandItsChangedPageToTheReader() async throws {
        let c = try container()
        let ctx = c.mainContext
        let s = html("org", in: ctx)
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })
        let gate = OpenableGate()

        func run(hash: String, gated: Bool, launched: @escaping ([String]) -> Void) async throws -> ScoutService.Outcome {
            try await ScoutService.runScout(
                into: ctx, depth: .readChanged, only: ["org"],
                fetch: { url, _, _ in
                    if gated { await gate.wait() }
                    return FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: hash)
                },
                pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
                launch: { launched($0.map(\.sourceId)) },
                now: now, defaults: ScratchDefaults.make("ScoutReadPhaseWritesNothingTests-handoff"),
                landings: flight, sequenceFloor: { 0 })
        }
        var olderLaunched: [String] = []
        var newerLaunched: [String] = []
        let older = Task { @MainActor in try await run(hash: "older", gated: true, launched: { olderLaunched = $0 }) }
        await waitUntil("the older run is fetching") { gate.entered == 1 }
        _ = try await run(hash: "newer", gated: false, launched: { newerLaunched = $0 })
        #expect(newerLaunched == ["org"], "the newer run did not hand its changed page over, so nothing below means anything")

        gate.open()
        let set = try await older.value
        #expect(set.sources.first { $0.sourceId == "org" }?.state == .superseded)
        #expect(olderLaunched.isEmpty, "an overtaken run handed its older page to the reader")
        #expect(s.pendingContentHash == "newer")
    }

    // MARK: - A kept copy offered again records its run once

    // Found while building #4330: a kept ingest copy, offered again, re-recorded its settled sources' read
    // phase writes, so a refused landing followed by its re-offer counted one failed read twice.
    @Test func aRefusedIngestOfferedAgainCountsItsFailedReadOnce() async throws {
        let c = try container()
        let ctx = c.mainContext
        let s = html("org", in: ctx)
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })
        let results = ScoutExtractResults(version: 1, generatedAt: "2026-07-12T00:00:00Z",
                                          results: [result("org", .unreadable, note: "could not read it")])
        func ingest() async -> ScoutService.Outcome {
            await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty,
                                            today: ScoutTestClock.beforeAllFixtures, now: now,
                                            landings: flight, sequence: 3, sequenceFloor: { 0 }, into: ctx)
        }

        let holder = try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(1))
        let refused = await ingest()
        #expect(refused.notLandedYet != nil, "the first offer was not refused, so the re-offer below proves nothing")
        #expect(s.failedReadStreak == 0, "a refused landing wrote its failed read")
        holder.end()

        let offeredAgain = await ingest()
        #expect(offeredAgain.notLandedYet == nil)
        #expect(s.failedReadStreak == 1, Comment(rawValue:
            "one failed read was counted \(s.failedReadStreak) times across a refusal and its re-offer"))
    }

    // MARK: - A failed save one stops the landing

    @Test func aFailedSaveOneStopsTheLandingBeforeTheReadIsHandedOff() async throws {
        struct SaveRefused: Error {}
        let c = try container()
        let ctx = c.mainContext
        let s = html("org", in: ctx)
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })
        var launched = false
        var saves = 0

        let outcome = try await ScoutService.runScout(
            into: ctx, depth: .readChanged, only: ["org"],
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "new") },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in launched = true },
            now: now, defaults: ScratchDefaults.make("ScoutReadPhaseWritesNothingTests-saveone"),
            landings: flight, sequenceFloor: { 0 },
            saveClosing: { _ in
                saves += 1
                throw SaveRefused()
            })

        #expect(saves == 1, "save one was not attempted, or the landing carried on to another save")
        #expect(outcome.saveFailed)
        #expect(!launched, "a page was handed to the reader on a pending hash the store never took")
        #expect(s.lastManualReadAt == nil, "the tail ran after save one failed")
        #expect(!flight.isHeld)
    }

    // Stopped is not silent: what this run found still reaches Dan when save one fails. The pages it never
    // handed over read as waiting, not as being read; a source over budget still reads as waiting; and the
    // past client list's health is still said. Only the tail's WRITES are stopped (lessons review of #4422).
    @Test func aFailedSaveOneStillReportsWhatTheRunFound() async throws {
        struct SaveRefused: Error {}
        let c = try container()
        let ctx = c.mainContext
        for id in ["a-org", "b-org"] { html(id, in: ctx).hasUnreadChanges = true }
        try ctx.save()
        let flight = LandingSingleFlight(sleep: { _ in })
        var launched = false

        let outcome = try await ScoutService.runScout(
            into: ctx, depth: .readChanged,
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "new") },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in launched = true },
            budget: 1,
            now: now, defaults: ScratchDefaults.make("ScoutReadPhaseWritesNothingTests-saveone-report"),
            landings: flight, sequenceFloor: { 0 },
            saveClosing: { _ in throw SaveRefused() })

        #expect(outcome.saveFailed)
        #expect(!launched)
        let states = Dictionary(outcome.sources.map { ($0.sourceId, $0.state) }, uniquingKeysWith: { $1 })
        #expect(states["a-org"] == .deferred, Comment(rawValue:
            "the page never handed over was reported as \(String(describing: states["a-org"]))"))
        #expect(states["b-org"] == .deferred, Comment(rawValue:
            "the source over budget was reported as \(String(describing: states["b-org"]))"))
        #expect(!outcome.sources.contains { $0.state == .queuedForReading })
        #expect(outcome.clientListWarning == DownbeatBridge.warningText(for: DownbeatBridge.loadWithHealth(now: now).health))
    }
}

// Holds a fetch until the test opens it, and says when it is holding.
@MainActor
private final class OpenableGate {
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
