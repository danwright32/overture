import Testing
import Foundation
import SwiftData

// #800: the migration that turns the hardcoded Carnegie scout into row one of a watchlist. It runs at
// launch, against Dan's LIVE store, so every test here is about it doing no harm.
//
// The health seeding is the subtle part. #150/#152 built a self-heal machine that decides whether a
// smaller feed is a genuine seasonal shrink or a broken fetch, and it has months of Carnegie's own
// history tuned into three UserDefaults keys. Moving Carnegie onto a row and starting that history
// from zero would hand the tuned machine an empty baseline, and its first job would be to decide
// whether Carnegie's next feed is trustworthy with nothing to judge it against.
@MainActor
@Suite("Carnegie becomes row one (#800)")
struct WatchedSourceBackfillTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, WatchedSource.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "WatchedSourceBackfillTests-\(UUID().uuidString)")!
    }

    private func prospect(_ name: String, url: String?) -> Prospect {
        Prospect(naturalKey: name, groupName: name, discipline: "music", venue: "Somewhere",
                 performanceDate: "2026-09-19", sourceListingURL: url,
                 priorRelationship: "none", production: "concert", profile: "unknown",
                 coverage: "unknown", fitScore: 50, tier: "medium", fitReason: "test",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
    }

    private func sources(_ ctx: ModelContext) throws -> [WatchedSource] {
        try ctx.fetch(FetchDescriptor<WatchedSource>())
    }

    @Test func seedsCarnegieAsRowOneOnItsAlgoliaPath() throws {
        let ctx = try context()
        WatchedSourceBackfill.run(in: ctx, defaults: defaults())

        let all = try sources(ctx)
        #expect(all.count == 1)
        let carnegie = try #require(all.first)
        #expect(carnegie.sourceId == WatchedSource.carnegieId)
        #expect(carnegie.orgName == "Carnegie Hall")
        #expect(carnegie.isActive)

        // It keeps its Algolia extractor. Its index exposes 90 days; its rendered page exposes about
        // three. Forcing it through the generic HTML path to "remove the special case" would cost 87
        // days of lead time.
        #expect(carnegie.kind == .algolia)
        #expect(carnegie.usesNativeExtractor)
        #expect(carnegie.isGenericallyFetchable == false)
        // So the fields the html path uses stay empty. Nothing may fetch, hash or paginate this row.
        #expect(carnegie.lastContentHash == nil)
        #expect(carnegie.pageCount == 1)
    }

    // The #150/#152 machinery keeps its own tuned history rather than restarting from zero.
    @Test func carnegieInheritsItsFeedHealthHistory() throws {
        let ctx = try context()
        let d = defaults()
        ScoutService.recordFeedHealthState(
            FeedReconcile.FeedHealthState(baseline: 118, degradedStreak: 2, lastDegradedCount: 61), in: d)
        let lastScout = Date(timeIntervalSince1970: 1_780_000_000)
        ScoutService.recordScout(at: lastScout, in: d)

        WatchedSourceBackfill.run(in: ctx, defaults: d)

        let carnegie = try #require(try sources(ctx).first)
        #expect(carnegie.baselineFeedCount == 118)
        #expect(carnegie.degradedStreak == 2)
        #expect(carnegie.lastDegradedCount == 61)
        #expect(carnegie.lastCheckedAt == lastScout)
        #expect(carnegie.lastSucceededAt == lastScout)
        #expect(carnegie.health == .ok)                   // it has a baseline, so it has succeeded before

        // And it is not treated as a brand-new source serving out a warmup: a source inside warmup
        // accrues no misses (Phase 3), which would silently switch OFF the disappeared-show detection
        // that has been running against Carnegie for months.
        #expect(carnegie.successfulCheckCount >= WatchedSource.warmupRuns)
    }

    // A store that has never scouted has nothing to inherit, and says so rather than claiming health.
    @Test func aStoreThatNeverScoutedSeedsCarnegieAsNeverChecked() throws {
        let ctx = try context()
        WatchedSourceBackfill.run(in: ctx, defaults: defaults())

        let carnegie = try #require(try sources(ctx).first)
        #expect(carnegie.health == .neverChecked)
        #expect(carnegie.baselineFeedCount == 0)
        #expect(carnegie.lastCheckedAt == nil)
        #expect(carnegie.successfulCheckCount == 0)
    }

    // #771's backfill: every prospect in the store today DID come from Carnegie, so stamping them is
    // accurate rather than a guess. Anything else is left empty rather than guessed at.
    @Test func stampsCarnegiesIdOnEveryCarnegieProspectAndNothingElse() throws {
        let ctx = try context()
        let carnegieShow = prospect("A", url: "https://www.carnegiehall.org/calendar/2026/10/02/china-now")
        let handAdded = prospect("B", url: "https://bargemusic.org/events")
        let noURL = prospect("C", url: nil)
        [carnegieShow, handAdded, noURL].forEach { ctx.insert($0) }
        try ctx.save()

        WatchedSourceBackfill.run(in: ctx, defaults: defaults())

        #expect(carnegieShow.sourceIds == [WatchedSource.carnegieId])
        #expect(handAdded.sourceIds == [])
        #expect(noURL.sourceIds == [])
    }

    // It runs on EVERY launch. Twice must be indistinguishable from once, or Dan gets a second Carnegie
    // row and a prospect carrying the same id twice.
    @Test func runningTwiceChangesNothingTheSecondTime() throws {
        let ctx = try context()
        let d = defaults()
        let show = prospect("A", url: "https://www.carnegiehall.org/calendar/2026/10/02/china-now")
        ctx.insert(show)
        try ctx.save()

        WatchedSourceBackfill.run(in: ctx, defaults: d)
        WatchedSourceBackfill.run(in: ctx, defaults: d)
        WatchedSourceBackfill.run(in: ctx, defaults: d)

        #expect(try sources(ctx).count == 1)
        #expect(show.sourceIds == [WatchedSource.carnegieId])
    }

    // A later launch must not undo a decision Dan made in between. If he stops watching Carnegie, the
    // next launch does not helpfully switch it back on.
    @Test func aSourceDanStoppedIsNotResurrectedByTheNextLaunch() throws {
        let ctx = try context()
        let d = defaults()
        WatchedSourceBackfill.run(in: ctx, defaults: d)
        let carnegie = try #require(try sources(ctx).first)
        carnegie.isActive = false
        carnegie.inactiveReason = .orgRefusal
        try ctx.save()

        WatchedSourceBackfill.run(in: ctx, defaults: d)

        #expect(try sources(ctx).count == 1)
        #expect(carnegie.isActive == false)
        #expect(carnegie.inactiveReason == .orgRefusal)
    }

    // A prospect that arrives after the backfill has already run still gets stamped, by the scout, not
    // by the migration. The backfill is a one-time repair of history, not the mechanism.
    @Test func theBackfillDoesNotDropSourceIdsAProspectAlreadyCarries() throws {
        let ctx = try context()
        let d = defaults()
        let show = prospect("A", url: "https://www.carnegiehall.org/calendar/2026/10/02/china-now")
        show.sourceIds = ["presenter-b"]        // surfaced by a presenter's own site too
        ctx.insert(show)
        try ctx.save()

        WatchedSourceBackfill.run(in: ctx, defaults: d)

        #expect(show.sourceIds.sorted() == [WatchedSource.carnegieId, "presenter-b"].sorted())
    }

    // #1472: #1237 flipped National Opera Center from .html onto OPERA America's native feed and left its
    // July 18 AI page read behind. The native path writes none of that state, so none of it could ever
    // clear on its own: the row showed Dan a note describing an unrendered Vue.js shell (a page Overture no
    // longer fetches at all), offered "Read this one now" against a pinned hash that will never promote, and
    // was pushed to the front of every scout by SourceSchedule's changed-first ordering, permanently.
    //
    // Keyed on the STATE rather than on the conversion, because the conversion already happened on an
    // earlier launch: a hook at the flip site would never reach the live row this exists to repair.
    @Test func aNativeFeedRowIsStrippedOfItsLeftoverHtmlEraRead() throws {
        let ctx = try context()
        let opera = WatchedSource(sourceId: "opera-america", orgName: "National Opera Center",
                                  listingsURL: "https://operaamerica.org/calendar", kind: .operaAmericaFeed)
        ctx.insert(opera)
        opera.notes = "The pinned page is an unrendered Vue.js single-page app shell."
        opera.pendingContentHash = "july-18-hash"
        opera.pendingPageMonths = ["2026-07"]
        opera.hasUnreadChanges = true

        WatchedSourceBackfill.run(in: ctx, defaults: defaults())

        #expect(opera.notes == nil)
        #expect(opera.pendingContentHash == nil)
        #expect(opera.pendingPageMonths.isEmpty)
        #expect(opera.hasUnreadChanges == false)
    }

    // The contrast, and the reason the test above is not a licence to wipe pin state generally: on an .html
    // source that same state IS the paid read path (a changed page is hashed, pinned, and read on the next
    // manual scout), so it must be left exactly as it was found.
    @Test func anHtmlSourcesPendingReadIsLeftAlone() throws {
        let ctx = try context()
        let kaufman = WatchedSource(sourceId: "kaufman", orgName: "Kaufman Music Center",
                                    listingsURL: "https://kaufman.example/events", kind: .html)
        ctx.insert(kaufman)
        kaufman.notes = "Read 30 shows across four months."
        kaufman.pendingContentHash = "pending-hash"
        kaufman.pendingPageMonths = ["2026-07"]
        kaufman.hasUnreadChanges = true

        WatchedSourceBackfill.run(in: ctx, defaults: defaults())

        #expect(kaufman.notes == "Read 30 shows across four months.")
        #expect(kaufman.pendingContentHash == "pending-hash")
        #expect(kaufman.pendingPageMonths == ["2026-07"])
        #expect(kaufman.hasUnreadChanges)
    }
}
