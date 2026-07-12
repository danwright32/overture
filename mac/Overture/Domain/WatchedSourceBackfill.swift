import Foundation
import SwiftData

// #800 / #771: the migration that turns the hardcoded Carnegie scout into row one of a watchlist, and
// records on every prospect already in the store where it came from.
//
// Runs at launch, on Dan's live store, on every launch. So it is idempotent in both halves, and it
// takes nothing away: it never overwrites a decision he made after it first ran (a source he stopped
// watching stays stopped), and it never drops a source id a prospect already carries.
//
// Carnegie KEEPS its Algolia extractor. Its index exposes 90 days; its rendered page exposes about
// three. Forcing it down the generic HTML path to be rid of the special case would trade 87 days of
// lead time for tidiness. #768 and #771 need Carnegie to have a ROW and a source id, not a shared
// extractor.
enum WatchedSourceBackfill {
    // Display only. Carnegie's real endpoint is a POST search API needing an app id, an api key and a
    // JSON body, so nothing may ever try to GET, hash or diff this URL: `usesNativeExtractor` on the
    // row is what enforces that. This is what Dan clicks in the Sources sheet.
    static let carnegieListingsURL = "https://www.carnegiehall.org/Calendar"

    static func run(in context: ModelContext, defaults: UserDefaults = .standard) {
        seedCarnegieRow(in: context, defaults: defaults)
        stampCarnegieProspects(in: context)
    }

    // Idempotent on "is there a Carnegie row yet". Deliberately NOT on "is it active": a source Dan
    // stopped watching must not be helpfully switched back on by the next launch.
    private static func seedCarnegieRow(in context: ModelContext, defaults: UserDefaults) {
        let carnegieId = WatchedSource.carnegieId
        let existing = FetchDescriptor<WatchedSource>(
            predicate: #Predicate { $0.sourceId == carnegieId })
        guard ((try? context.fetch(existing))?.first) == nil else { return }

        let row = WatchedSource(sourceId: carnegieId, orgName: "Carnegie Hall",
                                listingsURL: carnegieListingsURL, kind: .algolia)

        // Carry over the #150/#152 self-heal history rather than restarting it. That machinery decides
        // whether a smaller feed is a real seasonal shrink or a broken fetch, and it has been tuning
        // itself against Carnegie for months in three UserDefaults keys. Starting it from zero would
        // hand a tuned machine an empty baseline and ask it to judge the next feed against nothing.
        let health = ScoutService.feedHealthState(in: defaults)
        row.baselineFeedCount = health.baseline
        row.degradedStreak = health.degradedStreak
        row.lastDegradedCount = health.lastDegradedCount

        if let lastScout = ScoutService.lastScoutedAt(in: defaults) {
            row.lastCheckedAt = lastScout
            row.lastSucceededAt = lastScout
        }

        // A baseline exists only because scouts have succeeded, so Carnegie is neither unchecked nor
        // serving out a warmup. Seeding it inside the warmup would mean Phase 3 accrues no misses for
        // it, which would silently switch OFF the disappeared-show detection that has been protecting
        // Dan's queue since #133.
        if health.baseline > 0 {
            row.health = .ok
            row.successfulCheckCount = WatchedSource.warmupRuns
        }

        context.insert(row)
    }

    // #771: every prospect in the store today came from Carnegie's feed, so this is a record of fact,
    // not a guess. A prospect with any other listing URL, or none, is left with an empty list rather
    // than being assigned a source it may not have come from: an empty list simply never accrues a
    // miss, which is exactly what a non-Carnegie URL does today.
    private static func stampCarnegieProspects(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        for p in all {
            guard let url = p.sourceListingURL, url.contains("carnegiehall.org") else { continue }
            guard !p.sourceIds.contains(WatchedSource.carnegieId) else { continue }
            p.sourceIds = (p.sourceIds + [WatchedSource.carnegieId]).sorted()
        }
    }
}
