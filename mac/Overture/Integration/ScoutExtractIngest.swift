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
                       clients: [DownbeatClient], history: [HistoryRecord], blocked: BlockedCalendar,
                       today: String = QueueModel.easternToday(),
                       now: Date = Date(),
                       into context: ModelContext) -> ScoutService.Outcome {
        var outcome = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0, uncertain: 0)

        for result in results.results {
            // A source id the app never queued resolves to NOTHING. The results file is written by a
            // Claude run, and if it ever rebuilt an id instead of echoing it verbatim, the work must
            // vanish loudly rather than land on some other org's row. A silent mismatch has to read as
            // absence, never as the wrong show. #857: recorded, so "loudly" is true: the drop is
            // surfaced in the run's warning rather than being a bare `continue` nobody ever sees.
            guard let source = row(for: result.sourceId, in: context) else {
                outcome.unqueuedResultIds.append(result.sourceId)
                continue
            }

            // #875: the run's own explanation, kept rather than discarded. Written for EVERY result, on
            // the failure path and the healthy one alike, and overwritten each run so it always describes
            // the LAST thing that happened rather than accumulating a history nobody asked for. A source
            // that recovers must stop explaining a failure it no longer has.
            source.notes = result.note

            // #857: the run's own results are untrusted input. A verdict that disagrees with the events
            // it returned (it claimed the page was empty or unreadable and still handed back shows, or
            // claimed it found upcoming listings and handed back none) is the run ignoring its own
            // instructions, and its silence about a show is worth nothing. Its events are NOT ingested;
            // it is a named failure so the next scout reads the page again.
            //
            // Checked BEFORE the verdict branch below on purpose: a `no_dated_content`/`unreadable`
            // result that still carries events already fails there, but with the generic wrong-page
            // message; catching it here names the real problem (the run disagreed with itself) on the WHY
            // line Dan reads, and also catches the two contradictions that verdict branch cannot see
            // (`all_past` with events, which it would otherwise INGEST, and `upcoming_listings` with none,
            // which it would otherwise stamp as a healthy quiet read).
            if let reason = ScoutResultAudit.contradiction(in: result) {
                source.notes = reason
                fail(source, as: .inconsistentResult, now: now, outcome: &outcome)
                continue
            }

            // A page we could not read is a FAILURE, and its hash is not stamped. Stamping it would mean
            // never looking at this source again: it would report as unchanged forever, having never
            // once been read. `SourceFailure(verdict:)` is what decides which verdicts mean broken, and
            // a quiet off-season is deliberately not one of them.
            if let failure = SourceFailure(verdict: result.verdict) {
                // #1027: a page Dan confirmed as right-but-empty, read again at the same bytes, is not a
                // failure and does not nag. Checked with the hash just read (pendingContentHash), so the
                // instant the page changes it fails here as before. Only no_dated_content is ever
                // confirmable (isConfirmedQuiet gates on the verdict), so this cannot swallow a broken
                // fetch or a JS page.
                if SourceConfirmation.isConfirmedQuiet(verdict: result.verdict,
                                                       readHash: source.pendingContentHash,
                                                       confirmedEmptyHash: source.confirmedEmptyHash) {
                    recordConfirmedEmpty(on: source, now: now, outcome: &outcome)
                    continue
                }
                fail(source, as: failure, now: now, outcome: &outcome)
                continue
            }

            // #897: a stitched multi-month page (#858) is a trustworthy feed for reconcile ONLY once the
            // run read every month the app stitched into it. A run that covered fewer months read a SHORTER
            // page than the app fetched and hashed, and treating its silence about a show as evidence that
            // show was cancelled is the exact data loss #858 shipped pagination OFF to avoid. When the
            // sweep is short we DOWNGRADE the run's own verdict to incomplete_extraction: the shows it did
            // find still land as adds and updates, but the page is not marked finished (its hash is not
            // stamped, so the next scout re-reads it) and no feed health is recorded, exactly as a
            // partially read page already behaves (#1012). absenceIsEvidence can never fire for
            // incomplete_extraction, so a short sweep can never mark a live show gone.
            //
            // Inert on the single-month watchlist default (pendingPageMonths has 0 or 1 entry), so this
            // changes nothing until pagination is raised above one month on a reconciling path.
            let sweepComplete = SweepCoverage.isComplete(stitchedMonths: source.pendingPageMonths,
                                                         monthsCovered: result.monthsCovered)
            let effectiveVerdict = sweepComplete ? result.verdict : PageVerdict.incompleteExtraction

            // We read the page. It may have had nothing upcoming on it, which is the NORMAL state (5 of
            // the 7 sites in the #770 spike, in July) and is not a failure: we know what that page says,
            // and re-reading it daily until the season starts would be paying to be told so again.
            let events = results.events(for: result.sourceId)
            // #1032: the drops this run threw away, split by family (venue vs title), computed once and
            // used for BOTH the #887 tolerance gate (its total) and the Sources note (its title share).
            let rejection = results.rejectionCounts(for: result.sourceId)
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
                                             verdict: effectiveVerdict,
                                             rejectedCount: rejection.total),
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

            // #986: how many of the shows this run KEPT said where they are, by the SAME rule the native
            // path uses (SourcePlacement.placedCount), so the two ingest doors can never disagree on it.
            let placedCount = SourcePlacement.placedCount(locations: events.map(\.location))

            if effectiveVerdict == .incompleteExtraction {
                // #1012: real events, so they land, but the run only read PART of this page. Stamping the
                // hash or clearing the unread flag here would mean never going back for the rest of it:
                // the source would report healthy and unchanged forever, having been read exactly once.
                recordPartialCheck(on: source, events: events.count, now: now,
                                   unreadable: rejection.total, titleUnreadable: rejection.titleRelated,
                                   placed: placedCount)
            } else {
                recordSuccess(on: source, events: events.count, health: health, now: now,
                              // #891: recorded on the SAME branch as the run's success, so the count can
                              // never describe a run other than the one that produced it. A source that
                              // recovers overwrites this with a zero and stops complaining, which it must:
                              // a warning that never clears becomes furniture, and this is the one line
                              // Dan must not skim.
                              // #1032: the title share rides alongside the total, so the note names a
                              // titleless drop correctly instead of calling it "no venue".
                              unreadable: rejection.total, titleUnreadable: rejection.titleRelated,
                              placed: placedCount)
            }
            outcome.sources.append(ScoutService.SourceResult(
                sourceId: source.sourceId, orgName: source.orgName,
                state: .ingested(found: events.count), hadBaseline: health.baseline > 0,
                listingsURL: source.listingsURL))
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

    // The shared bookkeeping for a source that failed this run, whichever way it failed (a broken verdict
    // or a run that contradicted itself, #857). The hash is NOT stamped and the unread flag stays set, so
    // the next scout reads the page again rather than skipping it forever on the strength of a bad run.
    private static func fail(_ source: WatchedSource, as failure: SourceFailure, now: Date,
                             outcome: inout ScoutService.Outcome) {
        source.lastCheckedAt = now
        source.health = .failing
        source.lastFailure = failure
        source.hasUnreadChanges = true
        outcome.sources.append(ScoutService.SourceResult(
            sourceId: source.sourceId, orgName: source.orgName, state: .failed(failure),
            listingsURL: source.listingsURL))
    }

    // #1027: a no_dated_content page Dan already confirmed as right-but-empty, read again at the same
    // bytes. It is accepted, not failed: stamp the hash so the daily run sees no change and stops
    // re-reading it, clear the unread flag, and clear any prior failing display. Deliberately does NOT
    // touch baseline or successfulCheckCount (an empty page is not this source's real size, exactly as
    // recordPartialCheck avoids), and does NOT stamp lastSucceededAt: nothing was ingested.
    private static func recordConfirmedEmpty(on source: WatchedSource, now: Date,
                                             outcome: inout ScoutService.Outcome) {
        source.lastCheckedAt = now
        source.health = .ok
        source.lastFailure = nil
        source.lastContentHash = source.pendingContentHash ?? source.lastContentHash
        source.pendingContentHash = nil
        source.pendingPageMonths = []
        source.hasUnreadChanges = false
        outcome.sources.append(ScoutService.SourceResult(
            sourceId: source.sourceId, orgName: source.orgName, state: .confirmedEmpty,
            listingsURL: source.listingsURL))
    }

    // The page landed. Only now may its hash be promoted, and only now does this count as a check that
    // worked (the warmup that eventually lets this source mark a show as gone).
    //
    // #1001: the health fold, the #891 readable/unreadable counts and the #986 placement detector (all of
    // which the native ScoutService.recordCheck also does) live in ONE place now, on
    // WatchedSource.recordSuccessfulRead, so the two paths can never drift. That shared step writes every
    // count on this same success branch, so none can describe a run other than the one that produced it,
    // and captures the pre-run placement answer before this run overwrites it. Only the hash promotion is
    // this path's own: the native Algolia feed has no fetched page to hash.
    private static func recordSuccess(on source: WatchedSource, events: Int,
                                      health: FeedReconcile.FeedHealthState, now: Date,
                                      unreadable: Int = 0, titleUnreadable: Int = 0, placed: Int = 0) {
        source.recordSuccessfulRead(events: events, unreadable: unreadable,
                                    titleUnreadable: titleUnreadable, placed: placed,
                                    feedHealth: health, now: now)

        source.lastContentHash = source.pendingContentHash ?? source.lastContentHash
        source.pendingContentHash = nil
        // #897: the stitched-month expectation is spent once the run read the page in full. Cleared here on
        // the same success branch as the hash, so it can never carry stale months into a later comparison.
        source.pendingPageMonths = []
        source.hasUnreadChanges = false
    }

    // #1012: the run only read PART of this page, so this is neither a failure (real events came back
    // and were ingested above) nor a completed check. Deliberately does NOT do what recordSuccess does:
    //
    //   - lastContentHash / pendingContentHash / hasUnreadChanges are left untouched, so the next scout
    //     sees this source as still having unread changes and goes back for the rest of the page. Every
    //     other branch in this file that skips stamping the hash (fail(), the saveFailed path) is
    //     protecting the same invariant: only a run that read a page IN FULL may promote its hash.
    //   - baselineFeedCount / degradedStreak / successfulCheckCount are left untouched. A partial count
    //     is not this source's real size, and folding it into FeedReconcile.updatedHealth would let
    //     repeated partial reads ratchet the baseline down for no benefit: absenceIsEvidence already
    //     can never fire for this verdict (it gates on verdict == .upcomingListings), so there is nothing
    //     to protect by updating the baseline, only something to corrupt by doing so anyway.
    private static func recordPartialCheck(on source: WatchedSource, events: Int, now: Date,
                                           unreadable: Int = 0, titleUnreadable: Int = 0, placed: Int = 0) {
        source.lastReadableCount = events
        source.lastUnreadableCount = unreadable
        source.lastUnreadableTitleCount = titleUnreadable
        source.hadPlacedBeforeLastRun = source.hasEverPlaced
        source.lastPlacedCount = placed

        source.lastCheckedAt = now
        source.health = .ok
        source.lastFailure = nil
        // Deliberately NOT lastSucceededAt and NOT successfulCheckCount: this run did not finish reading
        // the page, so it should not count as the kind of check that starts the warmup clock.
    }

    private static func row(for sourceId: String, in context: ModelContext) -> WatchedSource? {
        let descriptor = FetchDescriptor<WatchedSource>(
            predicate: #Predicate { $0.sourceId == sourceId })
        return (try? context.fetch(descriptor))?.first
    }
}
