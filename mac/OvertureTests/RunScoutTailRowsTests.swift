import Testing
import Foundation
import SwiftData

// #4339 (A11): runScout's tail judges the shows its landing's working set holds rather than fetching the whole
// table again on the main thread. The two fetches it skips were measured at 200 and 216 ms at 1,372 shows and
// 801 and 866 at 5,500 (`LandingFirstHoldProbeTests`). When the tail had to wait for the store (another landing
// may have added shows meanwhile) it reads the table afresh, once for both passes, and a read that fails is
// recorded on the run rather than read as an empty store.
private struct ListedFeed: SourceExtractor {
    let events: [ExtractedEvent]
    func extract() async throws -> ExtractedListing { ExtractedListing(events: events, verdict: .upcomingListings) }
}

// The table reads runScout makes, by thread; bumped from whatever thread the read runs on.
private final class TableReads: @unchecked Sendable {
    private let lock = NSLock()
    private var onMain: [Bool] = []
    private var failOnMain = false
    func note() { lock.withLock { onMain.append(Thread.isMainThread) } }
    var mainThreadReads: Int { lock.withLock { onMain.filter { $0 }.count } }
    func failMainThreadReadsFromNowOn() { lock.withLock { failOnMain = true } }
    var failing: Bool { lock.withLock { failOnMain && Thread.isMainThread } }
}

private struct Refused: Error {}

@MainActor
@Suite("#4339 runScout's tail judges the landing's rows rather than fetching the table again", .serialized)
final class RunScoutTailRowsTests {
    private static func night(_ n: Int) -> String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: Date())!
        return EasternDate.dayString(from: day)
    }

    @discardableResult
    private func show(_ ctx: ModelContext, _ key: String, location: String) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "opera", venue: "A venue",
                         performanceDate: Self.night(3), sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 8, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.location = location
        ctx.insert(p)
        return p
    }

    private func status(_ key: String, in container: ModelContainer) throws -> ShowOutcome? {
        try ModelContext(container).fetch(FetchDescriptor<Prospect>()).first { $0.naturalKey == key }?.showOutcome
    }

    // One calendar that lands one show, so the landing's working set has been read before the tail runs.
    private func seededWithAFeed() throws -> (ModelContainer, ModelContext) {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = container.mainContext
        ctx.insert(WatchedSource(sourceId: "feed-tail", orgName: "Feed Tail",
                                 listingsURL: "https://feed-tail.example/", kind: .algolia))
        try ctx.save()
        return (container, ctx)
    }

    private func run(_ ctx: ModelContext, reads: TableReads, hiding hidden: String? = nil,
                     landings: LandingSingleFlight = LandingSingleFlight()) async throws -> ScoutService.Outcome {
        try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, only: ["feed-tail"],
            extractorRegistry: { source in
                guard source?.sourceId == "feed-tail" else { return nil }
                return ListedFeed(events: [ExtractedEvent(
                    title: "Tail Recital", presenter: "Tail Recital Presents", venue: "Tail Hall",
                    performanceDate: Self.night(1), sourceUrl: "https://feed-tail.example/e1", location: "New York, NY")])
            },
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "same") },
            pin: { _, id in URL(fileURLWithPath: "/dev/null/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("RunScoutTailRowsTests"),
            readProspectTable: { context in
                reads.note()
                if reads.failing { throw Refused() }
                let rows = try ScoutService.readProspectTable(context)
                return hidden.map { key in rows.filter { $0.naturalKey != key } } ?? rows
            },
            landings: landings)
    }

    @Test func theRetirementJudgesTheRowsItIsHandedAndOnlyThose() throws {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let ctx = container.mainContext
        let handed = show(ctx, "buffalo-a", location: "Buffalo, NY")
        let notHanded = show(ctx, "buffalo-b", location: "Buffalo, NY")
        try ctx.save()

        #expect(ExcludedTownRetirement.run(rows: [handed], in: ctx) == 1)
        #expect(handed.showOutcome == .tooFar)
        #expect(notHanded.status == .new, "a show the caller did not hand in was judged, so the table was fetched")
        // With none handed in, the table is fetched as before.
        #expect(ExcludedTownRetirement.run(in: ctx) == 1)
        #expect(notHanded.showOutcome == .tooFar)
    }

    /// No await let another landing in between the landing block and the tail, so the tail is handed the
    /// landing's working set: the main thread reads the table once in the whole run (the working set), and a
    /// row that read left out is not judged, which only a second fetch could have done.
    @Test func aTailNothingCouldInterleaveJudgesTheLandingsRowsWithoutReadingAgain() async throws {
        let (container, ctx) = try seededWithAFeed()
        show(ctx, "buffalo-read", location: "Buffalo, NY")
        show(ctx, "buffalo-unread", location: "Buffalo, NY")
        try ctx.save()
        let reads = TableReads()

        let outcome = try await run(ctx, reads: reads, hiding: "buffalo-unread")

        #expect(outcome.inserted == 1, "the feed's show did not land, so the working set was never read")
        #expect(try status("buffalo-read", in: container) == .tooFar, "the tail left a blocked town's show in the queue")
        #expect(try status("buffalo-unread", in: container) != .tooFar,
                "the tail judged a show the landing never read, so it fetched the table again")
        #expect(reads.mainThreadReads == 1,
                "the main thread read the show table \(reads.mainThreadReads) times; the tail should reuse the landing's")
    }

    // The landing waits behind a held store; a second waiter queued behind it takes the store when the landing
    // ends, so the tail has to wait too, and a show that waiter lands is there for the tail to judge.
    private func interleaved(failTheTailRead: Bool) async throws -> (ModelContainer, ScoutService.Outcome, TableReads) {
        let (container, ctx) = try seededWithAFeed()
        show(ctx, "buffalo-stored", location: "Buffalo, NY")
        try ctx.save()
        let reads = TableReads()
        let flight = LandingSingleFlight(sleep: { _ in try? await Task.sleep(for: .seconds(3600)) })
        let held = try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(60))
        let scout = Task { @MainActor in try await self.run(ctx, reads: reads, landings: flight) }
        let landingQueued = await waitUntil("the landing waits its turn", timeout: .seconds(60)) {
            flight.queue == [.runScoutLanding]
        }
        #expect(landingQueued, "the landing never queued: \(flight.queue)")
        let meanwhile = Task { @MainActor in
            let token = try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(60))
            self.show(ctx, "buffalo-meanwhile", location: "Buffalo, NY")
            try ctx.save()
            if failTheTailRead { reads.failMainThreadReadsFromNowOn() }
            token.end()
        }
        let bothQueued = await waitUntil("a second landing queues behind it", timeout: .seconds(30)) {
            flight.queue == [.runScoutLanding, .scoutExtractIngest]
        }
        #expect(bothQueued, "the second landing never queued: \(flight.queue)")
        held.end()
        try await meanwhile.value
        let outcome = try await scout.value
        return (container, outcome, reads)
    }

    @Test func aTailThatWaitedForTheStoreReadsTheTableAgainAndJudgesWhatLandedMeanwhile() async throws {
        let (container, outcome, reads) = try await interleaved(failTheTailRead: false)
        #expect(outcome.inserted == 1, "the feed's show did not land")
        #expect(try status("buffalo-meanwhile", in: container) == .tooFar,
                "a show another landing added while the tail waited was not judged: the tail used stale rows")
        #expect(try status("buffalo-stored", in: container) == .tooFar)
        // The working set, then the tail's one fresh read for both of its passes.
        #expect(reads.mainThreadReads == 2, "the main thread read the show table \(reads.mainThreadReads) times")
        #expect(!outcome.degradedReads.contains(.reconcileStoredShows))
    }

    @Test func aTailReadThatFailsIsRecordedAndJudgesNothing() async throws {
        let (container, outcome, _) = try await interleaved(failTheTailRead: true)
        #expect(outcome.degradedReads.filter { $0 == .reconcileStoredShows }.count == 1,
                "a tail that could not read the show table was not recorded once: \(outcome.degradedReads)")
        #expect(try status("buffalo-meanwhile", in: container) != .tooFar,
                "a tail whose read failed still judged shows, from rows it never read")
    }
}
