import Testing
import Foundation
import SwiftData
@testable import Overture

// #1034: the native "Scouting" phase of a manual scout (the fetch/hash loop over the html sources)
// reports its progress so the takeover modal can name the source it is checking and count "3 of 9",
// instead of a bare spinner. The callback fires after each source in the plan.fetch loop with its name
// and 1-based position. Default no-op, matching the file's existing fetch/pin/launch injection style,
// so every other caller is unchanged. Driven with injected fakes, no network.
@MainActor
@Suite("Scout native-phase progress reporting (#1034)")
struct ScoutServiceNativeProgressTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ScoutServiceNativeProgressTests-\(UUID().uuidString)")!
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
        { url, _, _ in FetchedPage(normalizedHTML: "<p>shows</p>", finalURL: url.absoluteString, contentHash: hash) }
    }

    @Test func reportsEachFetchedSourceByNameAndPosition() async throws {
        let ctx = try context()
        for id in ["a", "b", "c"] { source(ctx, id, lastHash: "old") }
        var updates: [(name: String, index: Int, total: Int)] = []

        _ = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: defaults(),
            onNativeProgress: { name, index, total in updates.append((name, index, total)) })

        // Every fetched source is reported exactly once, with sequential 1-based positions and the run's
        // total. The ORDER is the scheduler's (plan.fetch), not insertion order and not the modal's to
        // choose, so this asserts the set of names rather than a sequence.
        #expect(updates.count == 3)
        #expect(Set(updates.map(\.name)) == ["Org a", "Org b", "Org c"])
        #expect(updates.map(\.index) == [1, 2, 3])
        #expect(updates.allSatisfy { $0.total == 3 })
    }

    // It fires for a source whose page did NOT change too, not only for changed ones: the count is a
    // heartbeat through the WHOLE sweep, and skipping the unchanged ones would make the modal stall on a
    // number while the run kept working through pages it happened not to re-read.
    @Test func reportsAnUnchangedSourceAsProgressToo() async throws {
        let ctx = try context()
        source(ctx, "a", lastHash: "same")   // unchanged: fetch returns the same hash
        var updates: [(name: String, index: Int, total: Int)] = []

        _ = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("same"),
            pin: { _, _ in URL(fileURLWithPath: "/tmp/x.html") }, launch: { _ in },
            defaults: defaults(),
            onNativeProgress: { name, index, total in updates.append((name, index, total)) })

        #expect(updates.map(\.name) == ["Org a"])
        #expect(updates.first?.total == 1)
    }

    // The default is a no-op: every existing caller that passes no callback still runs, unchanged.
    @Test func defaultsToNoCallbackAndRunsUnchanged() async throws {
        let ctx = try context()
        source(ctx, "a", lastHash: "old")

        let outcome = try await ScoutService.runScout(
            into: ctx, extractor: noEvents, fetch: page("new"),
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: defaults())

        #expect(outcome.sources.contains { $0.sourceId == "a" })
    }
}
