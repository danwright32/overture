import Testing
import Foundation
import SwiftData
@testable import Overture

// #1037: a scout Dan started can be stopped. In the native "Scouting" sweep the stop is a flag checked
// between sources: the loop exits cleanly and, crucially, launches NO detached read for a run Dan chose
// to abandon. Driven with injected fakes, no network, no real run.
@MainActor
@Suite("Cancelling the native scout sweep (#1037)")
struct ScoutCancelTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ScoutCancelTests-\(UUID().uuidString)")!
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

    private func page(_ hash: String) -> (URL) async throws -> FetchedPage {
        { url in FetchedPage(normalizedHTML: "<p>shows</p>", finalURL: url.absoluteString, contentHash: hash) }
    }

    // Cancelled before the first source: nothing is checked and no read is launched.
    @Test func aCancelBeforeTheSweepChecksNothingAndLaunchesNoRead() async throws {
        let ctx = try context()
        for id in ["a", "b", "c"] { source(ctx, id, lastHash: "old") }
        var launched = false

        let outcome = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in launched = true },
            defaults: defaults(),
            isCancelled: { true })

        #expect(launched == false)
        // No html source was checked (the sweep stopped before the first).
        #expect(outcome.sources.allSatisfy { $0.state == .deferred } || outcome.sources.isEmpty)
        #expect(!outcome.sources.contains { if case .queuedForReading = $0.state { return true }; return false })
    }

    // Cancelled after the first source: the rest of the sweep is skipped and, because the run was
    // abandoned, its changed page is NOT handed off to be read.
    @Test func aCancelAfterTheFirstSourceStopsTheSweepAndLaunchesNoRead() async throws {
        let ctx = try context()
        for id in ["a", "b", "c"] { source(ctx, id, lastHash: "old") }
        var launched = false
        var checks = 0

        let outcome = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in launched = true },
            defaults: defaults(),
            isCancelled: { checks += 1; return checks > 1 })   // false for the first check, then true

        #expect(launched == false)
        // Exactly one html source was checked before the cancel stopped the rest.
        let checked = outcome.sources.filter { if case .deferred = $0.state { return false }; return true }
        #expect(checked.count == 1)
    }

    // The default is no-cancel, so every existing caller sweeps and hands off as before.
    @Test func defaultsToNoCancelSoAChangedPageStillLaunches() async throws {
        let ctx = try context()
        source(ctx, "a", lastHash: "old")
        var launched = false

        _ = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") },
            launch: { _ in launched = true },
            defaults: defaults())

        #expect(launched == true)
    }
}

// #1037: the detached-read half of cancel. The app writes a sentinel the runner reads on its heartbeat.
// This covers the Swift side of that contract: writing the sentinel, and clearing a stale one before a
// fresh run so a leftover from a cancelled run can never stop the next one instantly.
@MainActor
@Suite("Cancelling the detached scout read (#1037)")
struct ScoutExtractCancelServiceTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scout-extract-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ScoutExtractCancelServiceTests-\(UUID().uuidString)")!
    }
    private let item = ScoutExtractQueueItem(sourceId: "x", orgName: "Org", listingsURL: "https://x.test/e",
                                             pagePath: "/tmp/x.html")

    @Test func requestCancelWritesTheSentinelTheRunnerReads() throws {
        let cancel = try tempDir().appendingPathComponent("scout-extract-cancel")
        #expect(!FileManager.default.fileExists(atPath: cancel.path))
        ScoutExtractService.requestCancel(cancelURL: cancel)
        #expect(FileManager.default.fileExists(atPath: cancel.path))
    }

    // A sentinel left over from a previously cancelled run must be gone before a new run starts, or the
    // new run's heartbeat would read it and stop instantly (assume-it-runs-twice). startExtract clears it
    // as it takes the run.
    @Test func startExtractClearsAStaleCancelSentinelBeforeLaunching() throws {
        let dir = try tempDir()
        let cancel = dir.appendingPathComponent("scout-extract-cancel")
        try Data().write(to: cancel)   // a leftover from a prior cancelled run
        var launched = false

        _ = try ScoutExtractService.startExtract(
            items: [item], now: Date(),
            queueURL: dir.appendingPathComponent("queue.json"),
            markerURL: dir.appendingPathComponent("marker"),
            defaults: defaults(),
            cancelURL: cancel,
            launch: { launched = true })

        #expect(launched == true)
        #expect(!FileManager.default.fileExists(atPath: cancel.path))   // cleared before the run began
    }
}
