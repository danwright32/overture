import Foundation
import SwiftData

// #802 slice 3: what the app does with what the extract run read.
//
// This is where the watchlist finally writes to Dan's store, and it is where the feature's two most
// dangerous mistakes live:
//
//   Stamping a content hash for a page we did not actually ingest. The source would then report as
//   healthy and unchanged forever, having never once been read, and Dan would have no way to know that
//   a calendar he is counting on stopped being looked at months ago.
//
//   Letting a broken page read as a quiet one. A calendar drawn by JavaScript returns exactly what a
//   healthy off-season returns: nothing. Only the verdict tells them apart, and telling them apart is
//   the single thing Dan said must never fail.
@MainActor
enum ScoutExtractIngest {
    // Reads the results file the detached run wrote, and lands it, source by source.
    //
    // Each source is independent: a run that died at source nine keeps sources one through eight, and
    // a source it never reached keeps its pending hash and its unread flag so the next run picks it up
    // again rather than skipping it forever.
    @discardableResult
    static func ingest(_ results: ScoutExtractResults,
                       clients: [DownbeatClient], history: [HistoryRecord], blocked: Set<String>,
                       today: String = QueueModel.easternToday(),
                       now: Date = Date(),
                       into context: ModelContext) -> ScoutService.Outcome {
        var outcome = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0, uncertain: 0)

        for result in results.results {
            // A source id the app never queued resolves to NOTHING. The results file is written by a
            // Claude run, and if it ever rebuilt an id instead of echoing it verbatim, the work must
            // vanish loudly rather than land on some other org's row. A silent mismatch has to read as
            // absence, never as the wrong show.
            guard let source = row(for: result.sourceId, in: context) else { continue }

            // A page we could not read is a FAILURE, and its hash is not stamped. Stamping it would mean
            // never looking at this source again: it would report as unchanged forever, having never
            // once been read. `SourceFailure(verdict:)` is what decides which verdicts mean broken, and
            // a quiet off-season is deliberately not one of them.
            if let failure = SourceFailure(verdict: result.verdict) {
                source.lastCheckedAt = now
                source.health = .failing
                source.lastFailure = failure
                // Deliberately NOT cleared: there is still something on that page we have not read, and
                // the next run must try again rather than skip it.
                source.hasUnreadChanges = true
                outcome.sources.append(ScoutService.SourceResult(
                    sourceId: source.sourceId, orgName: source.orgName, state: .failed(failure)))
                continue
            }

            // We read the page. It may have had nothing upcoming on it, which is the NORMAL state (5 of
            // the 7 sites in the #770 spike, in July) and is not a failure: we know what that page says,
            // and re-reading it daily until the season starts would be paying to be told so again.
            let events = results.events(for: result.sourceId)
            let health = FeedReconcile.FeedHealthState(
                baseline: source.baselineFeedCount,
                degradedStreak: source.degradedStreak,
                lastDegradedCount: source.lastDegradedCount)

            // The SAME pipeline every other show goes through. That is load-bearing, not tidiness: it is
            // what makes the blocked-date skip, the #769 do-not-contact suppression and the #798
            // upcoming-only guard apply to a watched source exactly as they do to everything else. A
            // watchlist that could smuggle a refused org back in by a side door would be worse than no
            // watchlist at all.
            let applied = ScoutService.apply(
                events: events, clients: clients, history: history, blocked: blocked,
                // #887: the events this run THREW AWAY are handed over with the ones it kept. They were
                // rejected for having no venue, which almost always means their own detail page was never
                // read, so this run does not know what else it failed to reach. It may add and update; it
                // may not conclude that anything was cancelled. Available here all along
                // (rejectedEvents(for:) existed for exactly this) and consumed only by the lead sheet,
                // which is why the scout could quietly mark Dan's live shows gone.
                feed: ScoutService.FeedCheck(sourceId: source.sourceId,
                                             baseline: health.baseline,
                                             successfulCheckCount: source.successfulCheckCount,
                                             verdict: result.verdict,
                                             rejectedCount: results.rejectedEvents(for: source.sourceId).count),
                today: today, sourceIds: [source.sourceId], into: context)
            outcome.merge(applied)

            if applied.saveFailed {
                // #499: everything above was classified and upserted in memory and never persisted. The
                // hash stays UNSTAMPED and the unread flag stays set, so the next run reads this page
                // again. Stamp it here instead and the source would fetch fine, report fine, and have
                // silently ingested nothing since the day the save failed.
                outcome.sources.append(ScoutService.SourceResult(
                    sourceId: source.sourceId, orgName: source.orgName,
                    state: .ingested(found: events.count), hadBaseline: health.baseline > 0))
                continue
            }

            recordSuccess(on: source, events: events.count, health: health, now: now,
                          // #891: recorded on the SAME branch as the run's success, so the count can never
                          // describe a run other than the one that produced it. A source that recovers
                          // overwrites this with a zero and stops complaining, which it must: a warning
                          // that never clears becomes furniture, and this is the one line Dan must not skim.
                          unreadable: results.rejectedEvents(for: source.sourceId).count)
            outcome.sources.append(ScoutService.SourceResult(
                sourceId: source.sourceId, orgName: source.orgName,
                state: .ingested(found: events.count), hadBaseline: health.baseline > 0))
        }

        // #888 part B: ONE reconcile, with EVERY source this run landed.
        //
        // This used to happen inside `apply`, once per source, with a single-element report list. So
        // `believable` was never larger than one source, and a show co-listed by two could never satisfy
        // "every owner was asked and none has it" on any run, whatever either source said. The careful,
        // conservative half of FeedReconcile was dead code that read as working.
        //
        // Batched here, so a show that both Kaufman and Merkin have dropped can finally be seen as gone,
        // while a show whose second owner was NOT in this run stays untouched, because that source might
        // still be listing it and nobody asked.
        //
        // Deliberately AFTER the whole loop and not inside it: a partial batch would arm exactly the
        // half-informed conclusion this rule exists to prevent.
        //
        // KNOWN LIMIT, stated rather than hidden: the native (Carnegie) sweep reconciles separately, in
        // runScout, minutes before this file even exists. So a show co-listed by Carnegie AND a watched
        // HTML calendar is still never marked gone. That is the SAFE direction and no worse than before,
        // but it is not the whole rule, and somebody should know that before assuming it is.
        let reports = outcome.allReports
        if !reports.isEmpty {
            let allStored = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
            FeedReconcile.reconcile(stored: allStored, reports: reports, today: today)
        }

        return outcome
    }

    // The page landed. Only now may its hash be promoted, and only now does this count as a check that
    // worked (the warmup that eventually lets this source mark a show as gone).
    private static func recordSuccess(on source: WatchedSource, events: Int,
                                      health: FeedReconcile.FeedHealthState, now: Date,
                                      unreadable: Int = 0) {
        source.lastReadableCount = events
        source.lastUnreadableCount = unreadable

        let updated = FeedReconcile.updatedHealth(health, currentCount: events)
        source.baselineFeedCount = updated.baseline
        source.degradedStreak = updated.degradedStreak
        source.lastDegradedCount = updated.lastDegradedCount

        source.lastCheckedAt = now
        source.lastSucceededAt = now
        source.health = .ok
        source.lastFailure = nil
        source.successfulCheckCount += 1

        source.lastContentHash = source.pendingContentHash ?? source.lastContentHash
        source.pendingContentHash = nil
        source.hasUnreadChanges = false
    }

    private static func row(for sourceId: String, in context: ModelContext) -> WatchedSource? {
        let descriptor = FetchDescriptor<WatchedSource>(
            predicate: #Predicate { $0.sourceId == sourceId })
        return (try? context.fetch(descriptor))?.first
    }
}
