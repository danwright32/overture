import Testing
import Foundation
import SwiftData
@testable import Overture

// #1189: the scout's coverage fairness, exercised through the real runScout loop with fetch/pin/launch
// injected (the same pattern as ScoutQueueForReadingTests). Two guarantees:
//
//   1. The daily watch-only run never advances the manual scout's own fairness clock, so a source it
//      deferred stays genuinely next in line on the next manual press regardless of the daily flatten.
//   2. A changed source stranded in the deferred tail actually REACHES the read/queue step across a
//      manual press, rather than being deferred forever behind the same unchanged first-20.
@MainActor
@Suite("Scout coverage fairness (#1189)")
struct ScoutFairnessClockTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ScoutFairnessClockTests-\(UUID().uuidString)")!
    }

    @discardableResult
    private func source(_ ctx: ModelContext, _ id: String, lastHash: String? = nil,
                        lastChecked: Date? = nil, hasUnreadChanges: Bool = false) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)",
                              listingsURL: "https://\(id).example/events", kind: .html)
        s.lastContentHash = lastHash
        s.lastCheckedAt = lastChecked
        s.hasUnreadChanges = hasUnreadChanges
        ctx.insert(s)
        return s
    }

    private let noEvents = StubSourceExtractor(listing: ExtractedListing(events: [],
                                                                         verdict: .upcomingListings))

    private func page(_ hash: String) -> (URL, String?, String?) async throws -> FetchedPage {
        { url, _, _ in FetchedPage(normalizedHTML: "<p>shows</p>", finalURL: url.absoluteString,
                             contentHash: hash) }
    }

    private let noPin: (FetchedPage, String) throws -> URL = { _, id in
        URL(fileURLWithPath: "/tmp/\(id).html")
    }

    // Guarantee 1a: the free daily run advances the SHARED fetch clock but leaves the manual scout's own
    // fairness clock alone. That separation is the whole fix: the daily flatten of lastCheckedAt must not
    // reorder the manual read plan.
    @Test func aWatchOnlyRunDoesNotAdvanceTheManualFairnessClock() async throws {
        let ctx = try context()
        let s = source(ctx, "org", lastHash: "old")
        #expect(s.lastManualReadAt == nil)

        _ = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, extractor: noEvents, fetch: page("new"),
            pin: noPin, launch: { _ in }, defaults: defaults())

        #expect(s.lastManualReadAt == nil)   // the daily run leaves the manual clock alone
        #expect(s.lastCheckedAt != nil)      // but the shared fetch clock DID advance
    }

    // Guarantee 1b: a run Dan started advances the manual clock for the sources it checked, so they move
    // to the back of the line and the ones it deferred are first next press.
    @Test func aRunDanStartedAdvancesTheManualFairnessClockForCheckedSources() async throws {
        let ctx = try context()
        let s = source(ctx, "org", lastHash: "old")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try await ScoutService.runScout(
            into: ctx, depth: .readChanged, extractor: noEvents, fetch: page("new"),
            pin: noPin, launch: { _ in }, now: now, defaults: defaults())

        #expect(s.lastManualReadAt == now)
    }

    // A deferred source is not advanced: only the ones actually checked this press are. So next press it is
    // genuinely first in line. (Cap 1: one source is checked, the other is deferred untouched.)
    @Test func aDeferredSourceKeepsItsManualClockAcrossAManualPress() async throws {
        let ctx = try context()
        // Both unchanged (nothing to read), so ordering falls to the manual clock then sourceId. "aaa"
        // sorts first and is the one that gets checked under a cap of 1.
        let checked = source(ctx, "aaa", lastHash: "same")
        let deferred = source(ctx, "zzz", lastHash: "same")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try await ScoutService.runScout(
            into: ctx, depth: .readChanged, extractor: noEvents, fetch: page("same"),
            pin: noPin, launch: { _ in }, budget: 1, now: now, defaults: defaults())

        #expect(checked.lastManualReadAt == now)     // it had its turn
        #expect(deferred.lastManualReadAt == nil)    // it did not, so it stays first in line
    }

    // Guarantee 2, the follow-path: a changed source stranded at the back of a daily-flattened watchlist
    // longer than the cap still reaches the read/queue step on a manual press. Before the fix its identical
    // lastCheckedAt left it permanently in the deferred tail and its changed calendar was never read.
    @Test func aChangedSourceInTheTailReachesTheReadStepDespiteTheCap() async throws {
        let ctx = try context()
        // A full watchlist longer than the cap. All but one are unchanged (nothing to read). The changed
        // source carries the NEWEST lastCheckedAt (the daily run happened to re-stamp it most recently), so
        // under the OLD oldest-lastCheckedAt-first plan it sorted dead last and lived permanently past the
        // cap in the deferred tail, its changed calendar never read.
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = older.addingTimeInterval(86_400)
        for i in 1...25 { source(ctx, "org-\(i)", lastHash: "same", lastChecked: older) }
        source(ctx, "zzz", lastHash: "old", lastChecked: newer, hasUnreadChanges: true)

        var launched: [ScoutExtractQueueItem] = []
        _ = try await ScoutService.runScout(
            into: ctx, depth: .readChanged, extractor: noEvents,
            fetch: { url, _, _ in
                // only the changed source's page returns new bytes; everyone else is unchanged
                let hash = url.absoluteString.contains("zzz") ? "new" : "same"
                return FetchedPage(normalizedHTML: "<p>x</p>", finalURL: url.absoluteString,
                                   contentHash: hash)
            },
            pin: noPin, launch: { launched = $0 }, budget: 20, defaults: defaults())

        #expect(launched.contains { $0.sourceId == "zzz" })
        // And the run still respected the cap: at most the budget of pages was queued.
        #expect(launched.count <= 20)
    }

    // An over-budget source with nothing new to read is NOT "waiting to be checked": the free daily
    // watch-only run keeps its content hash current, so it is fully covered, not neglected. Before this,
    // EVERY deferred source (changed or not) was surfaced as waiting, so the popup's "N venues still
    // waiting" was a fixed total-minus-budget that never fell however many times Dan pressed Run again
    // (42 fetchable sources, budget 20, so it read "22 waiting" on every press, forever).
    @Test func anUnchangedDeferredSourceIsNotSurfacedAsWaiting() async throws {
        let ctx = try context()
        // Both unchanged (the page returns the same hash the row already stored), budget 1: "aaa" sorts
        // first and is checked; "zzz" is deferred, but it has nothing unread, so it is not waiting.
        source(ctx, "aaa", lastHash: "same")
        source(ctx, "zzz", lastHash: "same")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let outcome = try await ScoutService.runScout(
            into: ctx, depth: .readChanged, extractor: noEvents, fetch: page("same"),
            pin: noPin, launch: { _ in }, budget: 1, now: now, defaults: defaults())

        #expect(outcome.sources.contains { $0.state == .deferred } == false)
    }

    // The other half: a CHANGED source pushed past the budget IS still waiting. It has unread listings,
    // so it must be counted, or a genuine backlog would go silent. This is what keeps the number honest
    // when a big batch changes at once, and it converges: the changed ones sort first next press and
    // their unread flag clears on ingest, so repeated presses drain it to zero.
    @Test func aChangedDeferredSourceIsStillSurfacedAsWaiting() async throws {
        let ctx = try context()
        // Two CHANGED sources (their stored hash is stale and the page returns new bytes), budget 1:
        // "aaa" is read; "zzz" is deferred but genuinely carries unread listings.
        source(ctx, "aaa", lastHash: "old", hasUnreadChanges: true)
        source(ctx, "zzz", lastHash: "old", hasUnreadChanges: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let outcome = try await ScoutService.runScout(
            into: ctx, depth: .readChanged, extractor: noEvents, fetch: page("new"),
            pin: noPin, launch: { _ in }, budget: 1, now: now, defaults: defaults())

        #expect(outcome.sources.contains { $0.sourceId == "zzz" && $0.state == .deferred })
    }
}
