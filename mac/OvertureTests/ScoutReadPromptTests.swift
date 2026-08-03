import Testing
import Foundation
import SwiftData

// #1498: the prompt that guards the PAID half of a scout, exercised through the real runScout loop with
// fetch/pin/launch injected (the same pattern as ScoutFairnessClockTests).
//
// The budget used to cap which sources a manual run FETCHED, which rationed free work and bounded nothing:
// a 62-source watchlist checked 20 a press, left 42 unfetched, and still read whatever changed among the
// 20. Now the sweep fetches everything and stops once, at the one point where money is about to be spent,
// with the true count in hand.
@MainActor
@Suite("Asking before a scout spends (#1498)")
struct ScoutReadPromptTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ScoutReadPromptTests-\(UUID().uuidString)")!
    }

    @discardableResult
    private func source(_ ctx: ModelContext, _ id: String) -> WatchedSource {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)",
                              listingsURL: "https://\(id).example/events", kind: .html)
        s.lastContentHash = "old"          // every source below differs from the fetched page, so all changed
        ctx.insert(s)
        return s
    }

    private func sources(_ ctx: ModelContext, _ n: Int) -> [WatchedSource] {
        (1...n).map { source(ctx, "s\(String(format: "%03d", $0))") }
    }

    private let noEvents = StubSourceExtractor(listing: ExtractedListing(events: [],
                                                                        verdict: .upcomingListings))
    private func page(_ hash: String) -> (URL, String?, String?) async throws -> FetchedPage {
        { url, _, _ in FetchedPage(normalizedHTML: "<p>l</p>", finalURL: url.absoluteString, contentHash: hash) }
    }
    private let noPin: (FetchedPage, String) throws -> URL = { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // An ordinary press. Under the threshold there is nothing worth interrupting him for, so he is never
    // asked and every changed page is read, exactly as before this change.
    @Test func anOrdinaryPressIsNeverInterrupted() async throws {
        let ctx = try context()
        sources(ctx, 5)
        var asked = false
        var launched: [ScoutExtractQueueItem] = []

        _ = try await ScoutService.runScout(
            into: ctx, depth: .readChanged, extractor: noEvents, fetch: page("new"),
            pin: noPin, launch: { launched = $0 }, now: now, defaults: defaults(),
            askReadBudget: { _ in asked = true; return .all })

        #expect(asked == false)
        #expect(launched.count == 5)
    }

    // Over the threshold he IS asked, and the number he is asked about is the number the run would spend
    // on. A question quoting a different figure from the work is the failure this is built to avoid.
    @Test func aBigPressAsksWithTheRealCount() async throws {
        let ctx = try context()
        sources(ctx, 47)
        var askedAbout: Int? = nil

        _ = try await ScoutService.runScout(
            into: ctx, depth: .readChanged, extractor: noEvents, fetch: page("new"),
            pin: noPin, launch: { _ in }, now: now, defaults: defaults(),
            askReadBudget: { pending in askedAbout = pending; return .all })

        #expect(askedAbout == 47)
    }

    // Saying yes reads all of them in ONE run, which is the whole point: Dan was going to pay for these
    // reads either way, he simply had to press three times to get them.
    @Test func sayingYesReadsThemAllInOneRun() async throws {
        let ctx = try context()
        sources(ctx, 47)
        var launched: [ScoutExtractQueueItem] = []

        _ = try await ScoutService.runScout(
            into: ctx, depth: .readChanged, extractor: noEvents, fetch: page("new"),
            pin: noPin, launch: { launched = $0 }, now: now, defaults: defaults(),
            askReadBudget: { _ in .all })

        #expect(launched.count == 47)
    }

    // Taking the smaller batch reads exactly that many and leaves the rest as WAITING, not as silence. The
    // run reports them through the state a deferred source already had, so the end-of-scout count Dan reads
    // is the real backlog rather than a number that quietly omits what he declined.
    @Test func takingTheSmallerBatchReadsThatManyAndReportsTheRestAsWaiting() async throws {
        let ctx = try context()
        sources(ctx, 47)
        var launched: [ScoutExtractQueueItem] = []

        let outcome = try await ScoutService.runScout(
            into: ctx, depth: .readChanged, extractor: noEvents, fetch: page("new"),
            pin: noPin, launch: { launched = $0 }, now: now, defaults: defaults(),
            askReadBudget: { _ in .firstBatch })

        #expect(launched.count == ScoutReadBudget.askAbove)
        #expect(outcome.sources.filter { $0.state == .deferred }.count == 27)
    }

    // THE failure path, and the reason a dismissed prompt is safe rather than destructive: backing out
    // spends NOTHING. No read is launched at all, and every page is reported as waiting, so the next press
    // offers the same work again. The free half of the run (fetch, hash, health) still stands.
    @Test func backingOutSpendsNothingAndLosesNothing() async throws {
        let ctx = try context()
        let all = sources(ctx, 47)
        var launched = false

        let outcome = try await ScoutService.runScout(
            into: ctx, depth: .readChanged, extractor: noEvents, fetch: page("new"),
            pin: noPin, launch: { _ in launched = true }, now: now, defaults: defaults(),
            askReadBudget: { _ in .none })

        #expect(launched == false)
        #expect(outcome.sources.filter { $0.state == .deferred }.count == 47)
        #expect(all.allSatisfy { $0.hasUnreadChanges })        // still flagged, so nothing is lost
        #expect(all.allSatisfy { $0.lastCheckedAt == now })     // and the free half of the run still counted
    }

    // The free daily watch can never reach the prompt, however many pages changed. It reads nothing by
    // design, so there is nothing to ask about, and a question nobody is there to answer is the failure
    // that cost twenty shows in the detached runner.
    @Test func theFreeDailyWatchIsNeverAsked() async throws {
        let ctx = try context()
        sources(ctx, 47)
        var asked = false

        _ = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, extractor: noEvents, fetch: page("new"),
            pin: noPin, launch: { _ in }, now: now, defaults: defaults(),
            askReadBudget: { _ in asked = true; return .all })

        #expect(asked == false)
    }

    // A caller that does not answer at all (any path with nobody in front of it) reads everything rather
    // than hanging or silently reading nothing. The default is stated once, on the parameter, so no caller
    // has to remember to pass it.
    @Test func aCallerThatCannotAskStillReadsEverything() async throws {
        let ctx = try context()
        sources(ctx, 47)
        var launched: [ScoutExtractQueueItem] = []

        _ = try await ScoutService.runScout(
            into: ctx, depth: .readChanged, extractor: noEvents, fetch: page("new"),
            pin: noPin, launch: { launched = $0 }, now: now, defaults: defaults())

        #expect(launched.count == 47)
    }
}
