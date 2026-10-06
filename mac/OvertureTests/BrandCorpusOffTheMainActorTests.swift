import Testing
import Foundation
import SwiftData

// #4332 (A3): the venue brand corpus is read through a background context, off the main actor, by both scout
// entry points, behind the ENTRY FLUSH (`ScoutService.flushBeforeLanding`, A5's, the one implementation),
// which saves anything pending first, so the background read sees what Dan sees, and refuses the landing by
// name when it cannot. The flush under the token, before any apply, is A5's and is tested there.
//
// Before this, each entry point read the whole show table and Dan's producer corrections on the main actor
// at its first source (measured by #4327's probe at 0.24 s on a 1x clone and 1.02 s at 4x), inside the
// entry point's first hold.

// Which thread each table read ran on, written from whatever thread the read runs on.
private final class ReadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []
    func record() { lock.withLock { threads.append(Thread.isMainThread) } }
    var onMain: Int { lock.withLock { threads.filter { $0 }.count } }
    var offMain: Int { lock.withLock { threads.filter { !$0 }.count } }
}

private struct StoreSaysNo: Error, CustomStringConvertible {
    var description: String { "the store refused the save" }
}

// What each background corpus read saw of the pending edit, recorded from the thread it ran on.
private final class SawEdit: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Bool] = []
    func record(_ saw: Bool) { lock.withLock { seen.append(saw) } }
    var answers: [Bool] { lock.withLock { seen } }
}

private struct ListedFeed: SourceExtractor {
    let events: [ExtractedEvent]
    func extract() async throws -> ExtractedListing {
        ExtractedListing(events: events, verdict: .upcomingListings)
    }
}

@MainActor
@Suite("The venue brand corpus is read off the main actor, behind the entry flush (#4332)")
final class BrandCorpusOffTheMainActorTests {
    private let sandboxes = TemporarySandboxes()
    // Held for the life of the test: a container that goes away resets its context and destroys every row the
    // test still holds (measured here: SwiftData's "destroyed by calling ModelContext.reset" fatal error).
    private var containers: [ModelContainer] = []

    private static func night(_ n: Int) -> String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: Date())!
        return EasternDate.dayString(from: day)
    }

    private static func show(_ key: String, presenter: String, venue: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: "Stored \(key)", discipline: "music",
                         venue: venue, performanceDate: night(0),
                         sourceListingURL: "https://stored.example/\(key)", priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 5, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.presenter = presenter
        return p
    }

    private static func events(for id: String) -> [ExtractedEvent] {
        (0..<4).map { k in
            ExtractedEvent(title: "Ensemble \(id) \(k)", presenter: "Ensemble \(id) \(k) Presents",
                           venue: "Venue \(k) Hall", performanceDate: night(k),
                           sourceUrl: "https://\(id).example/e\(k)", location: "New York, NY")
        }
    }

    // One saved show whose presenter is NOT its room, so the room is not a brand until an edit says it is.
    private func store() throws -> (ModelContainer, ModelContext, Prospect) {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        containers.append(container)
        let ctx = container.mainContext
        let stored = Self.show("stored-0", presenter: "Ensemble Stored", venue: "Hall Of Glass")
        ctx.insert(stored)
        try ctx.save()
        return (container, ctx, stored)
    }

    private static func results(sources n: Int) -> ScoutExtractResults {
        ScoutExtractResults(
            version: 1, generatedAt: "2026-07-13T00:00:00Z",
            results: (0..<n).map { i in
                ScoutExtractResult(sourceId: "page-\(i)", verdict: .upcomingListings,
                                   events: Self.events(for: "page-\(i)").map {
                                       ScoutExtractEvent(title: $0.title, presenter: $0.presenter,
                                                         venue: $0.venue, performanceDate: $0.performanceDate,
                                                         sourceUrl: $0.sourceUrl)
                                   }, note: nil)
            })
    }

    private func addPages(_ n: Int, to ctx: ModelContext) throws {
        for i in 0..<n {
            let s = WatchedSource(sourceId: "page-\(i)", orgName: "Page \(i)",
                                  listingsURL: "https://page-\(i).example/events", kind: .html)
            s.pendingContentHash = "hash-\(i)"
            s.hasUnreadChanges = true
            ctx.insert(s)
        }
        try ctx.save()
    }

    // MARK: - Off the main actor

    @Test func theBackgroundCorpusReadRunsOffTheMainActorAndSeesTheSavedStore() async throws {
        let (container, ctx, stored) = try store()
        stored.presenter = "Hall Of Glass"
        try ctx.save()
        let log = ReadLog()
        let read = await ScoutService.venueBrandCorpusOffMain(
            container: container,
            read: { context in log.record(); return try ScoutService.readProspectTable(context) },
            readOverrides: ScoutService.readProducerOverrides)
        #expect(log.offMain == 1 && log.onMain == 0, Comment(rawValue:
            "the corpus read ran \(log.onMain) times on the main actor and \(log.offMain) off it"))
        #expect(read.brands.contains("Hall Of Glass"), "the background corpus did not see the saved presenter")
        #expect(read.degradedReads.isEmpty)
    }

    @Test func anIngestReadsTheCorpusOffTheMainActorAndTheWorkingSetOnIt() async throws {
        let (_, ctx, _) = try store()
        try addPages(2, to: ctx)
        let log = ReadLog()
        let outcome = await ScoutExtractIngest.ingest(
            Self.results(sources: 2), clients: [], history: [], blocked: .empty,
            readProspectTable: { context in log.record(); return try ScoutService.readProspectTable(context) },
            into: ctx)
        // The control: the sources landed, so the reads below are a real landing's (L159).
        #expect(outcome.inserted == 8, Comment(rawValue: "only \(outcome.inserted) shows landed"))
        #expect(log.offMain == 1, Comment(rawValue: "the corpus was read off the main actor \(log.offMain) times"))
        #expect(log.onMain == 1, Comment(rawValue:
            "the show table was read on the main actor \(log.onMain) times; only the working set belongs there"))
    }

    @Test func aSweepReadsTheCorpusOffTheMainActor() async throws {
        let (_, ctx, _) = try store()
        ctx.insert(WatchedSource(sourceId: "feed-0", orgName: "Feed 0",
                                 listingsURL: "https://feed-0.example/", kind: .algolia))
        try ctx.save()
        let log = ReadLog()
        let outcome = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, only: ["feed-0"],
            extractorRegistry: { source in
                source?.sourceId == "feed-0" ? ListedFeed(events: Self.events(for: "feed-0")) : nil
            },
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString,
                                             contentHash: "same") },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("BrandCorpusOffTheMainActorTests"),
            readProspectTable: { context in log.record(); return try ScoutService.readProspectTable(context) })
        #expect(outcome.inserted == 4, Comment(rawValue: "only \(outcome.inserted) shows landed"))
        // #4339 (A11) moved the history off the main actor, as this test's comment said it would: the corpus and
        // the history are read off it, and only the landing's working set stays on it.
        #expect(log.offMain == 2, Comment(rawValue: "the corpus and the history were read off the main actor \(log.offMain) times"))
        #expect(log.onMain == 1, Comment(rawValue: "the show table was read on the main actor \(log.onMain) times"))
    }

    // MARK: - The entry flush before the background read

    // Whether the background read saw the presenter edit, recorded from inside the read itself.
    private static func readSeeingTheEdit(_ saw: SawEdit) -> ScoutLandingStore.SendableRead {
        { context in
            let rows = try ScoutService.readProspectTable(context)
            if !Thread.isMainThread { saw.record(rows.contains { $0.presenter == "Hall Of Glass" }) }
            return rows
        }
    }

    // A presenter edit still pending on the main context when a landing starts is saved before the corpus is
    // read, so the background context, which sees only what is saved, judges brands against what Dan sees.
    // The flush under the token (A5's) comes too late for that: the corpus has already been read by then.
    @Test func aPendingPresenterEditIsSeenByTheIngestsBackgroundCorpus() async throws {
        let (_, ctx, stored) = try store()
        try addPages(1, to: ctx)
        stored.presenter = "Hall Of Glass"
        #expect(ctx.hasChanges, "the fixture's edit was not pending, so this would flush nothing")
        let saw = SawEdit()
        let outcome = await ScoutExtractIngest.ingest(Self.results(sources: 1), clients: [], history: [],
                                                      blocked: .empty, readProspectTable: Self.readSeeingTheEdit(saw),
                                                      into: ctx)
        #expect(outcome.inserted == 4)
        #expect(saw.answers == [true], Comment(rawValue:
            "the background corpus read saw the pending edit \(saw.answers), so it judged against an older store"))
    }

    @Test func aPendingPresenterEditIsSeenByTheSweepsBackgroundCorpus() async throws {
        let (_, ctx, stored) = try store()
        ctx.insert(WatchedSource(sourceId: "feed-0", orgName: "Feed 0",
                                 listingsURL: "https://feed-0.example/", kind: .algolia))
        try ctx.save()
        stored.presenter = "Hall Of Glass"
        let saw = SawEdit()
        let outcome = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, only: ["feed-0"],
            extractorRegistry: { source in
                source?.sourceId == "feed-0" ? ListedFeed(events: Self.events(for: "feed-0")) : nil
            },
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString,
                                             contentHash: "same") },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("BrandCorpusOffTheMainActorTests.sees"),
            readProspectTable: Self.readSeeingTheEdit(saw))
        #expect(outcome.inserted == 4)
        #expect(saw.answers == [true], Comment(rawValue:
            "the background corpus read saw the pending edit \(saw.answers), so it judged against an older store"))
    }

    // #4338 (A10): each landing records on its own landing record how many of its entry flushes saved an edit,
    // which `scripts/landing-flush-rate.sh` reads as a rate. The read phase flush saves the pending edit and the
    // flush under the store finds nothing more, so one; with nothing pending, zero, which is a recorded count and
    // not "no count" (nil, the marker the reader leaves out).
    @Test func theIngestRecordsHowManyOfItsEntryFlushesSavedAnEdit() async throws {
        let (_, edited, stored) = try store()
        try addPages(1, to: edited)
        stored.presenter = "Hall Of Glass"
        _ = await ScoutExtractIngest.ingest(Self.results(sources: 1), clients: [], history: [], blocked: .empty,
                                            into: edited)
        #expect(try edited.fetch(FetchDescriptor<LandingRun>()).map(\.entryFlushSaves) == [1])

        let (_, quiet, _) = try store()
        try addPages(1, to: quiet)
        _ = await ScoutExtractIngest.ingest(Self.results(sources: 1), clients: [], history: [], blocked: .empty,
                                            into: quiet)
        #expect(try quiet.fetch(FetchDescriptor<LandingRun>()).map(\.entryFlushSaves) == [0])
    }

    @Test func theSweepRecordsHowManyOfItsEntryFlushesSavedAnEdit() async throws {
        let (_, ctx, stored) = try store()
        ctx.insert(WatchedSource(sourceId: "feed-0", orgName: "Feed 0",
                                 listingsURL: "https://feed-0.example/", kind: .algolia))
        try ctx.save()
        stored.presenter = "Hall Of Glass"
        _ = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, only: ["feed-0"],
            extractorRegistry: { source in
                source?.sourceId == "feed-0" ? ListedFeed(events: Self.events(for: "feed-0")) : nil
            },
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString,
                                             contentHash: "same") },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("BrandCorpusOffTheMainActorTests.flushCount"))
        #expect(try ctx.fetch(FetchDescriptor<LandingRun>()).map(\.entryFlushSaves) == [1])
    }

    // A flush that cannot save refuses the landing BY NAME before the corpus is read and before any apply,
    // reports every source not attempted, and leaves the pending edit exactly as it was.
    @Test func aFlushFailureRefusesTheIngestBeforeTheCorpusIsRead() async throws {
        let (_, ctx, stored) = try store()
        try addPages(1, to: ctx)
        stored.presenter = "Hall Of Glass"
        let log = ReadLog()
        let outcome = await ScoutExtractIngest.ingest(
            Self.results(sources: 1), clients: [], history: [], blocked: .empty,
            readProspectTable: { context in log.record(); return try ScoutService.readProspectTable(context) },
            saveEntry: { _ in throw StoreSaysNo() },
            into: ctx)
        #expect(outcome.inserted == 0 && outcome.updated == 0, "the refused landing applied shows")
        #expect(log.onMain + log.offMain == 0, Comment(rawValue:
            "the refused landing read the show table \(log.onMain + log.offMain) times"))
        #expect(outcome.landingStop == .recentEditsUnsaved(rows: ["Stored stored-0"]), Comment(rawValue:
            "\(String(describing: outcome.landingStop))"))
        #expect(outcome.notAttemptedSources.map(\.sourceId) == ["page-0"], Comment(rawValue:
            "reported \(outcome.sources.map { "\($0.sourceId) \($0.state)" })"))
        #expect(ctx.hasChanges && stored.presenter == "Hall Of Glass", "the pending edit was not left as it was")
    }

    @Test func aFlushFailureRefusesTheSweepBeforeTheCorpusIsRead() async throws {
        let (_, ctx, stored) = try store()
        ctx.insert(WatchedSource(sourceId: "feed-0", orgName: "Feed 0",
                                 listingsURL: "https://feed-0.example/", kind: .algolia))
        try ctx.save()
        stored.presenter = "Hall Of Glass"
        let log = ReadLog()
        let outcome = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, only: ["feed-0"],
            extractorRegistry: { source in
                source?.sourceId == "feed-0" ? ListedFeed(events: Self.events(for: "feed-0")) : nil
            },
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString,
                                             contentHash: "same") },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("BrandCorpusOffTheMainActorTests.refused"),
            readProspectTable: { context in log.record(); return try ScoutService.readProspectTable(context) },
            saveEntry: { _ in throw StoreSaysNo() })
        #expect(outcome.inserted == 0, "the refused landing applied shows")
        // The history read sits above the flush and is the run's own; with this edit pending it stays on the main
        // thread (#4339: a background read would not see the edit). Nothing reads after the refused flush.
        #expect(log.offMain == 0, "the refused landing still read the corpus")
        #expect(outcome.landingStop == .recentEditsUnsaved(rows: ["Stored stored-0"]), Comment(rawValue:
            "\(String(describing: outcome.landingStop))"))
        #expect(outcome.notAttemptedSources.map(\.sourceId) == ["feed-0"], Comment(rawValue:
            "reported \(outcome.sources.map { "\($0.sourceId) \($0.state)" })"))
        #expect(ctx.hasChanges && stored.presenter == "Hall Of Glass", "the pending edit was not left as it was")
    }

    // The ingest refused before its corpus read keeps a content hash copy of its results, and offers it again.
    @Test func anIngestRefusedBeforeItsCorpusReadKeepsACopyOfItsResults() async throws {
        let (_, ctx, stored) = try store()
        try addPages(1, to: ctx)
        stored.presenter = "Hall Of Glass"
        let pending = PendingScoutIngests(directory: try sandboxes.make(named: "refused-ingest-copy"))
        let results = Self.results(sources: 1)
        let data = try JSONEncoder().encode(results)
        let landed = await ScoutExtractLanding.land(data, results, clients: [], history: [], blocked: .empty,
                                                    pending: pending, saveEntry: { _ in throw StoreSaysNo() },
                                                    into: ctx)
        #expect(landed.outcome.landingStop == .recentEditsUnsaved(rows: ["Stored stored-0"]))
        let kept = try pending.list()
        #expect(kept.count == 1, Comment(rawValue: "kept \(kept.count) copies of the refused results"))

        // Once the edit can save, the kept copy lands and is removed.
        let offered = await ScoutExtractLanding.offerPending(clients: [], history: [], blocked: .empty,
                                                             pending: pending, into: ctx)
        #expect(offered.landed.count == 1 && offered.landed.first?.inserted == 4, Comment(rawValue:
            "the kept copy did not land once the edit could save: \(offered)"))
        #expect(try pending.list().isEmpty)
    }

    // MARK: - Both joined reads are gated (L530, L215)

    @Test func aFailingShowTableReadDegradesTheCorpusAndTheLandingProceeds() async throws {
        let (_, ctx, _) = try store()
        try addPages(1, to: ctx)
        let outcome = await ScoutExtractIngest.ingest(
            Self.results(sources: 1), clients: [], history: [], blocked: .empty,
            readProspectTable: { context in
                if !Thread.isMainThread { throw StoreSaysNo() }
                return try ScoutService.readProspectTable(context)
            },
            into: ctx)
        #expect(outcome.degradedReads == [.venueBrandCorpus], Comment(rawValue: "recorded \(outcome.degradedReads)"))
        #expect(outcome.inserted == 4, "the landing did not proceed on the degraded corpus")
    }

    @Test func aFailingOverrideReadDegradesTheCorpusUnderItsOwnName() async throws {
        let (_, ctx, _) = try store()
        try addPages(1, to: ctx)
        let outcome = await ScoutExtractIngest.ingest(
            Self.results(sources: 1), clients: [], history: [], blocked: .empty,
            readProducerOverrides: { _ in throw StoreSaysNo() },
            into: ctx)
        #expect(outcome.degradedReads == [.producerOverrides], Comment(rawValue: "recorded \(outcome.degradedReads)"))
        #expect(outcome.inserted == 4, "the landing did not proceed on the degraded corpus")
        #expect(outcome.warning?.contains(ScoutService.StoreRead.producerOverrides.label) == true)
    }
}
