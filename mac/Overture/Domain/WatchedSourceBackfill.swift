import Foundation
import SwiftData

// #800 / #771: the migration that turns the hardcoded Carnegie scout into row one of a watchlist, and
// records on every prospect already in the store where it came from.
//
// Runs at launch, on Dan's live store, on every launch. So it is idempotent in both halves, and it
// takes nothing away: it never overwrites a decision he made after it first ran (a source he stopped
// watching stays stopped), and it never drops a source id a prospect already carries.
//
// Carnegie KEEPS its Algolia extractor. Its index answers for the whole window the scout asks of it
// ([[AlgoliaCalendar.windowDays]]); its rendered page exposes about three days. Forcing it down the
// generic HTML path to be rid of the special case would trade nearly all of that lead time for
// tidiness. #768 and #771 need Carnegie to have a ROW and a source id, not a shared
// extractor.
enum WatchedSourceBackfill {
    // Display only. Carnegie's real endpoint is a POST search API needing an app id, an api key and a
    // JSON body, so nothing may ever try to GET, hash or diff this URL: `usesNativeExtractor` on the
    // row is what enforces that. This is what Dan clicks in the Sources sheet.
    static let carnegieListingsURL = "https://www.carnegiehall.org/Calendar"

    static func run(in context: ModelContext, defaults: UserDefaults = .standard) {
        seedCarnegieRow(in: context, defaults: defaults)
        stampCarnegieProspects(in: context)
        migrateFeedAdapterKinds(in: context)
        clearHtmlEraReadState(in: context)
    }

    // #1472: a native-feed row must carry no leftover state from the paid html read path, and National Opera
    // Center proved that nothing was clearing it.
    //
    // #1237 flipped that source from .html onto OPERA America's feed and left its July 18 AI page read behind:
    // a note describing an unrendered Vue.js shell (a page Overture no longer reads at all), a pinned hash
    // whose `unreadable` verdict never promoted, and hasUnreadChanges still true. The native path writes none
    // of those three, so none of them could ever clear on their own. The row therefore showed Dan a
    // permanently false sentence, offered "Read this one now" on a page that is never fetched, and was
    // promoted to the front of every scout by SourceSchedule's changed-first ordering, forever.
    //
    // Keyed on the STATE and not on the flip, deliberately: the conversion already happened on an earlier
    // launch, so a hook at the flip site would never reach the live row. Idempotent (a cleared row has nothing
    // to clear), and it leaves every .html source's pin state completely alone, since that is how the paid read
    // path legitimately works.
    private static func clearHtmlEraReadState(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<WatchedSource>())) ?? []
        for source in all where source.kind.usesNativeExtractor {
            guard source.hasUnreadChanges || source.pendingContentHash != nil
                    || source.notes != nil || !source.pendingPageMonths.isEmpty
            else { continue }
            source.notes = nil
            source.pendingContentHash = nil
            source.pendingPageMonths = []
            source.hasUnreadChanges = false
        }
        try? context.save()
    }

    // #1237: an OPERA America or VenueTix source Dan already watches was added before those adapters could
    // ingest natively, so it still carries .html and keeps going to the paid AI read. Flip it onto its
    // native kind (SourceKind.forListingURL, the SAME rule the add path uses) so it ingests for free on
    // every run, expanding free daily coverage on venues he already watches with no new scraping.
    //
    // Idempotent and forward-only: it moves a matching .html row to its native kind and nothing else, so a
    // second launch, or a row already native, is a no-op. It touches ONLY the routing kind, leaving the
    // row's feed history, health, and id untouched, so the source keeps everything it earned.
    private static func migrateFeedAdapterKinds(in context: ModelContext) {
        let all = (try? context.fetch(FetchDescriptor<WatchedSource>())) ?? []
        for source in all where source.kind == .html {
            guard let s = source.listingsURL, let url = URL(string: s) else { continue }
            let native = SourceKind.forListingURL(url)
            if native != .html { source.kind = native }
        }
        try? context.save()
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
