import Testing
import Foundation
import SwiftData

// #4325: a scout landing's closing FeedReconcile writes are SAVED before the landing returns, on both paths.
//
// WHAT WAS WRONG. `ScoutExtractIngest.ingest` reconciled once after every source had landed and saved, and
// nothing saved after it; the native sweep reconciled after each source's own save, so the LAST source's
// reconcile was unsaved too. Its writes (`missedScoutCount`, `survivedMergeAt`, `mergeSurvivorUnseenAt`) were
// left to autosave or the next unrelated save, so a quit or crash first lost a feed miss (L12), and the
// #4275 probe's rounds read the previous round's reconcile as their own writes (#4327 step 0.5).
//
// HOW IT IS READ. Autosave is switched OFF on the landing's context, so nothing can flush the writes by
// chance, and the store is read through a FRESH context on the same container, which sees only what was
// saved. The miss is asserted on the landing's own row too, so a zero in the store is a write that was lost
// rather than one the reconcile never made (L159).
//
// AND THE FAILURE PATH. `missedScoutCount += 1` is not idempotent, so a closing save that fails puts the
// reconcile's writes back, or a retried landing would add a second miss on top of the pending first and the
// next save would record two. A write an earlier save already carried is never put back.
@MainActor
@Suite("A scout landing saves its closing reconcile (#4325)")
struct ScoutLandingSavesItsReconcileTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory(AppSchema.models)
    }

    private func committedMisses(_ key: String, in c: ModelContainer) throws -> Int? {
        try ModelContext(c).fetch(FetchDescriptor<Prospect>()).first { $0.naturalKey == key }?.missedScoutCount
    }

    // A future show owned by `owner` alone, which the landing below will not list. Invented names (L155).
    private func ownedShow(_ ctx: ModelContext, owner: String, date: String) -> Prospect {
        let p = Prospect(naturalKey: "gone-show", groupName: "Wrenfield Players", discipline: "theatre",
                         venue: "Callowmere Hall", performanceDate: date,
                         sourceListingURL: "https://\(owner).example/wrenfield",
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .queued)
        p.sourceIds = [owner]
        ctx.insert(p)
        return p
    }

    // A source whose silence counts: past its warmup, and at its full size for the run below.
    private func establishedSource(_ ctx: ModelContext, _ id: String, kind: SourceKind, baseline: Int) {
        let s = WatchedSource(sourceId: id, orgName: "Org \(id)", listingsURL: "https://\(id).example/events",
                              kind: kind)
        s.pendingContentHash = "new-hash-\(id)"
        s.hasUnreadChanges = true
        s.successfulCheckCount = WatchedSource.warmupRuns
        s.baselineFeedCount = baseline
        ctx.insert(s)
    }

    @Test func theIngestSavesItsReconcileBeforeItReturns() async throws {
        let c = try container()
        let ctx = c.mainContext
        ctx.autosaveEnabled = false
        establishedSource(ctx, "kaufman", kind: .html, baseline: 1)
        let show = ownedShow(ctx, owner: "kaufman", date: "2099-09-19")
        try ctx.save()

        let results = ScoutExtractResults(version: 1, generatedAt: "2026-07-13T00:00:00Z", results: [
            ScoutExtractResult(sourceId: "kaufman", verdict: .upcomingListings, events: [
                ScoutExtractEvent(title: "Something Else", presenter: "Something Else", venue: "Callowmere Hall",
                                  performanceDate: "2099-10-01", sourceUrl: "https://kaufman.example/else")],
                               note: nil)])
        let outcome = await ScoutExtractIngest.ingest(results, clients: [], history: [], blocked: .empty,
                                                      today: ScoutTestClock.beforeAllFixtures, now: now, into: ctx)

        #expect(show.missedScoutCount == 1, "the reconcile never counted the miss, so the store proves nothing")
        #expect(!outcome.saveFailed)
        #expect(!ctx.hasChanges, "the ingest returned with writes still pending: \(ctx.changedModelsArray.count) rows")
        #expect(try committedMisses("gone-show", in: c) == 1, Comment(rawValue:
            "the ingest's reconcile counted a miss the store does not hold, so a quit now loses it (#4325)"))
    }

    private struct ListedFeed: SourceExtractor {
        let events: [ExtractedEvent]
        func extract() async throws -> ExtractedListing { ExtractedListing(events: events, verdict: .upcomingListings) }
    }

    private static func night(_ n: Int) -> String {
        EasternDate.dayString(from: Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: Date())!)
    }

    @Test func theNativeSweepSavesItsLastReconcileBeforeItReturns() async throws {
        let c = try container()
        let ctx = c.mainContext
        ctx.autosaveEnabled = false
        let events = (0..<4).map { k in
            ExtractedEvent(title: "Tessaly Quartet \(k)", presenter: "Tessaly Quartet \(k) Presents",
                           venue: "Venue \(k) Hall", performanceDate: Self.night(k),
                           sourceUrl: "https://feed-0.example/e\(k)", location: "New York, NY")
        }
        establishedSource(ctx, "feed-0", kind: .algolia, baseline: events.count)
        let show = ownedShow(ctx, owner: "feed-0", date: Self.night(30))
        try ctx.save()

        let outcome = try await ScoutService.runScout(
            into: ctx, depth: .watchOnly, only: ["feed-0"],
            extractorRegistry: { $0?.sourceId == "feed-0" ? ListedFeed(events: events) : nil },
            fetch: { url, _, _ in FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "same") },
            pin: { _, id in URL(fileURLWithPath: "/tmp/\(id).html") }, launch: { _ in },
            defaults: ScratchDefaults.make("ScoutLandingSavesItsReconcileTests"))

        #expect(show.missedScoutCount == 1, "the sweep never counted the miss, so the store proves nothing")
        #expect(!outcome.saveFailed)
        #expect(!ctx.hasChanges, "the sweep returned with writes still pending: \(ctx.changedModelsArray.count) rows")
        #expect(try committedMisses("gone-show", in: c) == 1, Comment(rawValue:
            "the sweep's last reconcile counted a miss the store does not hold, so a quit now loses it (#4325)"))
    }

    private func report(_ id: String) -> FeedReconcile.SourceReport {
        FeedReconcile.SourceReport(sourceId: id, seenKeys: [], seenSourceURLs: [], feedCount: 40, baseline: 40,
                                   successfulCheckCount: WatchedSource.warmupRuns, verdict: .upcomingListings)
    }

    private struct SaveRefused: Error {}

    // A failed closing save puts the reconcile's miss back and says it failed, and the retry then counts the
    // miss ONCE.
    @Test func aFailedClosingSavePutsTheMissBackSoARetryCountsItOnce() throws {
        let c = try container()
        let ctx = c.mainContext
        ctx.autosaveEnabled = false
        let show = ownedShow(ctx, owner: "kaufman", date: "2099-09-19")
        try ctx.save()

        let first = ScoutLandingStore(context: ctx)
        first.noteReconcile(FeedReconcile.reconcile(stored: [show], reports: [report("kaufman")], today: "2026-10-01"))
        #expect(show.missedScoutCount == 1, "the reconcile never counted the miss, so there is nothing to put back")
        #expect(!ScoutService.saveLanding(first, into: ctx, save: { _ in throw SaveRefused() }),
                "a closing save that failed reported the landing's writes as saved")
        #expect(show.missedScoutCount == 0, "a failed closing save left the miss pending for a retry to count again")

        let retry = ScoutLandingStore(context: ctx)
        retry.noteReconcile(FeedReconcile.reconcile(stored: [show], reports: [report("kaufman")], today: "2026-10-01"))
        #expect(ScoutService.saveLanding(retry, into: ctx))
        #expect(try committedMisses("gone-show", in: c) == 1, "the retried landing did not record exactly one miss")
    }

    // The other direction, which is the one that would lose data: a write an earlier save already carried is
    // committed, and a failed closing save must not put it back over the store.
    @Test func aFailedClosingSaveLeavesAWriteAnEarlierSaveCarried() throws {
        let c = try container()
        let ctx = c.mainContext
        ctx.autosaveEnabled = false
        let show = ownedShow(ctx, owner: "kaufman", date: "2099-09-19")
        try ctx.save()

        let landing = ScoutLandingStore(context: ctx)
        landing.noteReconcile(FeedReconcile.reconcile(stored: [show], reports: [report("kaufman")], today: "2026-10-01"))
        try ctx.save()   // the next source's own save, which carries the reconcile above
        show.fitReason = "an unrelated pending edit, so the closing save has something to carry"
        #expect(!ScoutService.saveLanding(landing, into: ctx, save: { _ in throw SaveRefused() }))
        #expect(show.missedScoutCount == 1, Comment(rawValue:
            "a failed closing save put back a miss an earlier save had already committed"))
    }
}
