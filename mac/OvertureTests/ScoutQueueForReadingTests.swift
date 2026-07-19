import Testing
import Foundation
import SwiftData
@testable import Overture

// #802 slice 3: the handoff. Which pages a run actually sends to be read, and what happens when it
// cannot send them.
//
// The seams (pin, launch) are injected for the same reason the fetch is: pinning writes into the handoff
// directory and launching starts a real Claude run, so a test using the real ones would litter Dan's
// store and spend his tokens.
@MainActor
@Suite("What the scout hands off to be read (#802)")
struct ScoutQueueForReadingTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ScoutQueueForReadingTests-\(UUID().uuidString)")!
    }

    @discardableResult
    private func source(_ ctx: ModelContext, _ id: String, lastHash: String? = nil) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)",
                              listingsURL: "https://\(id).example/events", kind: .html)
        s.lastContentHash = lastHash
        ctx.insert(s)
        return s
    }

    private let noEvents = StubSourceExtractor(listing: ExtractedListing(events: [],
                                                                         verdict: .upcomingListings))

    private func page(_ hash: String) -> (URL, String?, String?) async throws -> FetchedPage {
        { url, _, _ in FetchedPage(normalizedHTML: "<p>shows</p>", finalURL: url.absoluteString,
                             contentHash: hash) }
    }

    // MARK: - What gets handed off

    @Test func aChangedPageIsPinnedAndSentToBeRead() async throws {
        let ctx = try context()
        source(ctx, "org", lastHash: "old")
        var launched: [ScoutExtractQueueItem] = []

        _ = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, id in URL(fileURLWithPath: "/tmp/pinned-\(id).html") },
            launch: { launched = $0 },
            defaults: defaults())

        #expect(launched.count == 1)
        // The id is OPAQUE and must be echoed verbatim by the run: a key it rebuilds matches nothing on
        // the way back and the work vanishes with no error anywhere.
        #expect(launched.first?.sourceId == "org")
        #expect(launched.first?.pagePath == "/tmp/pinned-org.html")
        #expect(launched.first?.orgName == "Org org")
    }

    // The hash of the bytes we sent is remembered, because it cannot be recomputed later: the ingest
    // happens minutes afterwards in another process, by which time the live page may have moved on, and
    // re-hashing would stamp a hash for bytes nobody ever read.
    @Test func theHashOfWhatWeSentIsHeldUntilTheResultsLand() async throws {
        let ctx = try context()
        let s = source(ctx, "org", lastHash: "old")

        _ = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: defaults())

        #expect(s.pendingContentHash == "new")
        #expect(s.lastContentHash == "old")   // NOT promoted: nothing has been read yet
        #expect(s.hasUnreadChanges)
    }

    @Test func anUnchangedPageIsNeverSentToBeRead() async throws {
        let ctx = try context()
        source(ctx, "org", lastHash: "same")
        var launched: [ScoutExtractQueueItem] = []

        _ = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("same"),
            pin: { _, _ in URL(fileURLWithPath: "/tmp/x.html") }, launch: { launched = $0 },
            defaults: defaults())

        #expect(launched.isEmpty)   // no pin, no queue, no Claude run, no tokens
    }

    // Dan's 4th decision, at the handoff: the free daily run notices the change and sends nothing.
    @Test func theFreeDailyRunHandsOffNothingEvenWhenPagesChanged() async throws {
        let ctx = try context()
        let s = source(ctx, "org", lastHash: "old")
        var launchCount = 0

        _ = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, extractor: noEvents, fetch: page("new"),
            pin: { _, _ in URL(fileURLWithPath: "/tmp/x.html") },
            launch: { _ in launchCount += 1 },
            defaults: defaults())

        #expect(launchCount == 0)
        #expect(s.hasUnreadChanges)          // but Dan can see there is something waiting
        #expect(s.pendingContentHash == nil) // nothing is in flight, because nothing was sent
    }

    // ONE run for every changed page, never one per source: one hung source must not be able to block
    // the marker guard or leave a bare indefinite spinner behind N subprocesses.
    @Test func everyChangedPageGoesIntoOneSingleRun() async throws {
        let ctx = try context()
        for id in ["a", "b", "c"] { source(ctx, id, lastHash: "old") }
        var launchCount = 0
        var items: [ScoutExtractQueueItem] = []

        _ = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { launchCount += 1; items = $0 },
            defaults: defaults())

        #expect(launchCount == 1)
        #expect(items.count == 3)
        #expect(Set(items.map(\.sourceId)) == ["a", "b", "c"])
    }

    // MARK: - When the handoff fails

    // The runner not being configured is the first thing Dan will hit. It must be LOUD: a watchlist that
    // quietly never reads anything is indistinguishable from one where every calendar happens to be
    // quiet, and he would go on believing his sources were being watched.
    @Test func aFailedHandOffIsNamedAndActionable() async throws {
        let ctx = try context()
        source(ctx, "org", lastHash: "old")

        let outcome = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, _ in URL(fileURLWithPath: "/tmp/x.html") },
            launch: { _ in throw ScoutExtractService.ExtractLaunchError.runnerUnavailable },
            defaults: defaults())

        let warning = outcome.warning ?? ""
        #expect(warning.isEmpty == false)
        #expect(warning.localizedCaseInsensitiveContains("set up"))     // and it says how to fix it
        #expect(warning.localizedCaseInsensitiveContains("next scout")) // and that nothing was lost
    }

    // And the SOURCES are not blamed for it. Those calendars are perfectly healthy: it is the app that
    // cannot read them. Marking twelve working websites "failing" would send Dan to debug twelve working
    // websites.
    @Test func aFailedHandOffDoesNotMarkTheSourcesAsBroken() async throws {
        let ctx = try context()
        let s = source(ctx, "org", lastHash: "old")

        let outcome = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, _ in URL(fileURLWithPath: "/tmp/x.html") },
            launch: { _ in throw ScoutExtractService.ExtractLaunchError.runnerUnavailable },
            defaults: defaults())

        #expect(s.health != .failing)
        #expect(s.lastFailure == nil)
        #expect(outcome.failedSources.isEmpty)

        // And nothing is lost: the page is still unread, so the next run picks it up again.
        #expect(s.hasUnreadChanges)
        #expect(s.lastContentHash == "old")
    }
}
