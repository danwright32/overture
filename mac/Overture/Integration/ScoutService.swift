import Foundation
import SwiftData

// The in-app scout: extract the live calendar (hidden WebKit) -> classify (rules) ->
// match repeat clients -> assemble/rank -> upsert into the local store. Fully native
// and silent; no separate runner, no cloud. Upsert preserves Dan's keep/dismiss.

@MainActor
enum ScoutService {
    struct Outcome: Equatable, Sendable {
        var found: Int
        var inserted: Int
        var updated: Int
        var skipped: Int
        var uncertain: Int
        // #797: nights folded into a multi-night run rather than upserted on their own. Deliberately
        // NOT counted as `skipped`, which means "decided not to pursue" (a blocked date, a
        // do-not-contact org); a collapsed night was pursued, as part of its run. Kept separate so
        // every event the scout found is accounted for exactly once:
        //     found == inserted + updated + skipped + collapsedIntoRun
        // That identity is what makes a silently vanished show impossible to miss (it was the bug
        // this counter was added to catch), so it is asserted directly in the tests.
        var collapsedIntoRun: Int = 0
        // Set when the Downbeat past-client export was missing, unreadable, or stale, so
        // warm/repeat matching ran degraded and Dan should be told (#22/#23).
        var clientListWarning: String? = nil
        // #499: set when a context.save() failed during this run, so some or all of what the
        // scout found or reconciled may not have persisted.
        var saveFailed: Bool = false

        // #802: what happened to each watched source this run. A run is no longer one number, and it
        // must never report a total that silently omits half of what it was supposed to check.
        var sources: [SourceResult] = []

        // #857: results that came back under a sourceId we never queued. The run rebuilt a key instead of
        // echoing it, so its work resolves to nothing and cannot be landed on the right row. Recorded so
        // it vanishes LOUDLY: the queued source it should have belonged to shows up separately as
        // never-read (the shell guard fills it), but only this names WHY (the id was rewritten).
        var unqueuedResultIds: [String] = []

        // #802, Dan's 3rd decision: the orgs that asked him to stop whose shows still turned up on a
        // calendar he watches. The #769 guard suppressed them, silently, and silent is the problem: on
        // the one mistake that cannot be taken back he would rather SEE the guard working than trust it.
        // This is a receipt, not a warning: nothing is wrong and nothing needs doing.
        var suppressedOrgs: [SuppressedOrg] = []

        // #802: the run found changed pages and could not hand them off to be read (the runner is not
        // configured, or a previous run is still going). NOT a per-source failure: those calendars are
        // healthy and it is the app that cannot read them. Marking them failing would send Dan to debug
        // twelve working websites.
        var extractLaunchFailure: String? = nil

        // #888 part B: what THIS source swept, carried home so the caller can reconcile every source it
        // landed in ONE pass. Nil when this apply had no feed to report on (the lead path), which is
        // what keeps a pasted lead structurally unable to mark anything gone (#826).
        var report: FeedReconcile.SourceReport? = nil

        // Every source's report from a merged run. `merge` collects them (see below), so a caller that
        // landed six sources can hand all six to one reconcile and finally satisfy "every owner was
        // asked", which a single-report reconcile never could.
        var reports: [FeedReconcile.SourceReport] = []

        var allReports: [FeedReconcile.SourceReport] { reports + [report].compactMap { $0 } }

        var failedSources: [SourceResult] { sources.filter { $0.state.isFailure } }

        // The single warning to show after a run, if any. A save failure takes precedence over
        // everything else: the run may have found and processed events that never persisted, the
        // most actionable problem (#499).
        //
        // #802: `found == 0` STOPS being a global warning. Under a watchlist, zero is the NORMAL
        // off-season answer (5 of the 7 sites in the #770 spike, in July) and is also exactly what a
        // fully hash-skipped run legitimately returns. Firing "the feed's data format may have changed"
        // on every quiet week would train Dan to ignore the one warning that matters. It now fires only
        // for a source that HAS a healthy baseline and still came back with nothing, which for
        // Carnegie's 90-day window is the same unusual event it always was (#27, #126).
        var warning: String? {
            if saveFailed {
                return "The scout ran but couldn't save its results. Run it again; if this keeps happening, something's wrong with the local store."
            }
            // The run found new listings and could not read them. It outranks a per-source failure
            // because it is the app that is broken, not a calendar, and because it has a one-step fix.
            if let extractLaunchFailure { return extractLaunchFailure }
            // A source that could not be checked is the most actionable thing after that, and it is
            // named, every run, for as long as it keeps failing. A dead source and a quiet season must
            // never look alike. #857: a run that rebuilt an id (returned work under a source we never
            // queued) is shown alongside, not masked by, the failures, because both can happen in one run.
            let parts = [failureWarning, unqueuedWarning].compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: "\n\n") }
            if silentlyEmptyFeed {
                return "The scout reached the calendar feed but found no upcoming events. That's unusual for a 90-day window. The feed's data format may have changed."
            }
            return clientListWarning
        }

        // #857: the run rebuilt one or more sourceIds, so its work for them cannot be landed. Named, so
        // the drop is loud rather than silent. The id itself is what the run wrote, and is the actionable
        // clue for whoever debugs why a source keeps coming back never-read.
        private var unqueuedWarning: String? {
            guard !unqueuedResultIds.isEmpty else { return nil }
            let ids = unqueuedResultIds.joined(separator: ", ")
            return unqueuedResultIds.count == 1
                ? "The run returned results under a source it was never asked about (\(ids)), so it rebuilt an id and that work was ignored. The source it should have belonged to will be read again."
                : "The run returned results under \(unqueuedResultIds.count) sources it was never asked about (\(ids)), so it rebuilt those ids and that work was ignored. The sources they should have belonged to will be read again."
        }

        private var failureWarning: String? {
            let failed = failedSources
            guard !failed.isEmpty else { return nil }
            let lines = failed.map { "\($0.orgName): \($0.state.failureMessage ?? "couldn't be checked")" }
            return failed.count == 1
                ? "One source couldn't be checked. \(lines[0])"
                : "\(failed.count) sources couldn't be checked.\n\n" + lines.joined(separator: "\n")
        }

        // A source that has succeeded before (so it has a baseline to be judged against) and came back
        // empty anyway. A brand-new source with no history has nothing unusual about an empty first
        // check, and a quiet off-season is not a defect.
        private var silentlyEmptyFeed: Bool {
            sources.contains { $0.state == .ingested(found: 0) && $0.hadBaseline }
        }

        // Folds one source's ingest into the run's totals. The counts stay additive so the #797 identity
        // (found == inserted + updated + skipped + collapsedIntoRun) still holds across the whole run,
        // which is what makes a silently vanished show impossible to miss.
        mutating func merge(_ other: Outcome) {
            found += other.found
            inserted += other.inserted
            updated += other.updated
            skipped += other.skipped
            uncertain += other.uncertain
            collapsedIntoRun += other.collapsedIntoRun
            saveFailed = saveFailed || other.saveFailed
            sources.append(contentsOf: other.sources)
            unqueuedResultIds.append(contentsOf: other.unqueuedResultIds)
            suppressedOrgs.append(contentsOf: other.suppressedOrgs)
            // #888 part B: reports ACCUMULATE across a merge rather than the last one winning. That is
            // the whole point: a caller that landed six sources must be able to hand all six to one
            // reconcile, or "every owner was asked" can never be true of a co-listed show.
            reports.append(contentsOf: other.allReports)
        }
    }

    // An org Dan told Overture to stop contacting, whose shows a watched calendar is still listing.
    struct SuppressedOrg: Equatable, Sendable {
        var orgName: String
        var showCount: Int
    }

    // What one watched source did this run. Every source that was supposed to be checked appears here,
    // including the ones that were not checked, because "not checked today" reporting as silence is the
    // failure this whole feature exists to prevent.
    struct SourceResult: Equatable, Sendable {
        var sourceId: String
        var orgName: String
        var state: State
        // Whether this source had a feed history before this run, which is what makes an empty result
        // from it unusual rather than merely quiet.
        var hadBaseline: Bool = false

        enum State: Equatable, Sendable {
            case ingested(found: Int)     // ran natively and its shows are in the store (Carnegie)
            case unchanged               // its page has not changed since we last read it: nothing to do
            case queuedForReading        // its page changed and Dan started this run: it is being read
            case changedNotRead          // its page changed, but this was the free daily run
            case deferred                // over this run's budget. NOT checked. Not fine, not failing.
            case failed(SourceFailure)   // named, recorded on the row, and never fatal to the source

            var isFailure: Bool { if case .failed = self { return true }; return false }

            var failureMessage: String? {
                if case .failed(let f) = self { return f.message }
                return nil
            }
        }
    }

    // #802: the loop. `runScout` walks every ACTIVE watched source rather than opening with one
    // hardcoded call to Carnegie.
    //
    // Two rules govern it, and both are the opposite of what the old single-source version did:
    //
    // 1. ONE SOURCE'S FAILURE NEVER KILLS THE RUN. It used to throw on the first fetch error, which was
    //    correct when there was exactly one source and its failure meant the run had nothing to do. With
    //    a watchlist, throwing means source 9 being down silently costs Dan sources 10 through 20. Every
    //    per-source failure is now caught, typed, written onto that source's row, counted into the
    //    outcome, and reported by name. The run continues.
    // 2. THE RUN NEVER REPORTS A NUMBER THAT OMITS HALF OF ITSELF. Every source appears in
    //    `outcome.sources`, including the ones that were deferred or that failed, because "not checked
    //    today" quietly reporting as silence is the exact failure this feature exists to prevent.
    //
    // `depth` carries Dan's 4th decision: the automatic daily run WATCHES (fetch, hash, health) and
    // spends nothing, and only a scout he started READS the pages that changed. Carnegie ingests fully
    // on both, because its Algolia path is native and free.
    //
    // Everything is injected (the extractor, the fetch, the defaults) so the whole loop is a real unit
    // test with no network: under the test host `UserDefaults.standard` is the LIVE app's own preference
    // domain, so a test that used the real one would scribble on Dan's app.
    static func runScout(into context: ModelContext,
                         depth: ScoutDepth = .readChanged,
                         extractor: any SourceExtractor = CarnegieExtractor(),
                         fetch: (URL) async throws -> FetchedPage = { try await SourceFetcher.fetch($0) },
                         // Injected for the same reason the fetch is: pinning writes a file to the
                         // handoff directory and launching starts a real Claude run, so a test that used
                         // the real ones would litter Dan's store and spend his tokens.
                         pin: (FetchedPage, String) throws -> URL = { try ScoutPagePin.write($0, forSourceId: $1) },
                         launch: ([ScoutExtractQueueItem]) throws -> Void = {
                             _ = try ScoutExtractService.startExtract(items: $0, now: Date())
                         },
                         budget: Int = SourceSchedule.defaultBudget,
                         now: Date = Date(),
                         defaults: UserDefaults = .standard) async throws -> Outcome {
        let loaded = DownbeatBridge.loadWithHealth(now: now)
        // History the matcher sees = any one-time legacy import + Overture's own activity,
        // so repeat-client recognition stays current as Dan sends and books (#19).
        let existing = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let history = LocalHistory.forMatching(existing: existing)
        let blocked = blockedCalendar(export: (loaded.bookings, loaded.blockedDates), context: context)

        let watchlist = (try? context.fetch(FetchDescriptor<WatchedSource>())) ?? []
        let plan = SourceSchedule.plan(sources: watchlist, depth: depth, budget: budget, now: now)

        var outcome = Outcome(found: 0, inserted: 0, updated: 0, skipped: 0, uncertain: 0)

        // The native sources (Carnegie, and only Carnegie). Free, synchronous, and fully ingested on
        // every run including the automatic one, so today's behavior is preserved exactly.
        //
        // A store whose #800 backfill has not run yet has no rows at all. It still scouts Carnegie, from
        // the injected extractor, so the app is never dead in the window between upgrading and the first
        // launch migration.
        let nativeSources: [WatchedSource?] = plan.native.isEmpty && watchlist.isEmpty ? [nil] : plan.native
        for source in nativeSources {
            outcome.merge(await runNative(source, extractor: extractor, clients: loaded.clients,
                                          history: history, blocked: blocked, now: now, into: context))
        }

        // The html sources: fetch, hash, and decide. Nothing is READ here: this loop is free, and it runs
        // identically on the daily automatic scout and on one Dan started.
        var toRead: [(source: WatchedSource, page: FetchedPage)] = []
        for source in plan.fetch {
            let (result, page) = await check(source, fetch: fetch, depth: depth, now: now)
            outcome.sources.append(result)
            if let page { toRead.append((source, page)) }
        }

        // ONE batched detached run for every page that changed, never N subprocesses: one hung source
        // must not be able to block the marker guard or leave a bare indefinite spinner. Only reachable
        // at `.readChanged`, because `check` only ever hands back a page to read on a run Dan started.
        //
        // A failure to LAUNCH is not swallowed, and it is deliberately NOT recorded as a failure of the
        // sources. The runner not being configured is the first thing Dan will hit, and those twelve
        // calendars are perfectly healthy: it is the app that cannot read them. Marking them "failing"
        // would send him to debug twelve working websites. It is a run-level problem, named as one, and
        // every source keeps its pending hash and its unread flag so the next run reads them all once
        // the runner is fixed. What must never happen is silence: a watchlist that quietly never reads
        // anything is indistinguishable from one where every calendar happens to be quiet.
        if !toRead.isEmpty {
            do {
                try queueForReading(toRead, pin: pin, launch: launch)
            } catch {
                outcome.extractLaunchFailure = extractLaunchMessage(error)
            }
        }

        // Deferred is a visible state, never silence. A source over budget was NOT checked, and Dan has
        // to be able to see that, or it could go unchecked for weeks while reporting as healthy.
        for source in plan.deferred {
            outcome.sources.append(SourceResult(sourceId: source.sourceId, orgName: source.orgName,
                                                state: .deferred))
        }

        outcome.clientListWarning = DownbeatBridge.warningText(for: loaded.health)

        // Reconcile bookings from Downbeat: a contacted prospect that's now a Downbeat
        // client gets outcome booked automatically (#41).
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        if DownbeatBooking.reconcileBooked(prospects: all, clients: loaded.clients, bookings: loaded.bookings, health: loaded.health, now: Date()) > 0 {
            do {
                try context.save()
            } catch {
                // #499: the booking reconcile mutated prospects in memory but couldn't persist them.
                outcome.saveFailed = true
            }
        }
        // Record that a scout completed, so the masthead can show freshness (#35).
        recordScout(at: Date(), in: defaults)
        return outcome
    }

    // One native source: extract, classify, upsert, reconcile. Its failure is recorded and reported,
    // never thrown, so a source that is down cannot cost Dan the rest of his watchlist.
    private static func runNative(_ source: WatchedSource?, extractor: any SourceExtractor,
                                  clients: [DownbeatClient], history: [HistoryRecord],
                                  blocked: BlockedCalendar, now: Date,
                                  into context: ModelContext) async -> Outcome {
        let sourceId = source?.sourceId ?? WatchedSource.carnegieId
        let orgName = source?.orgName ?? "Carnegie Hall"

        let events: [ExtractedEvent]
        do {
            events = try await extractor.extract().events
        } catch {
            // Typed, named, on the row, and the loop carries on. `ScoutFailure` used to present this as
            // the death of the whole scout, because with one source it was.
            let failure = SourceFailure.fetch(fetchError(from: error))
            source?.lastCheckedAt = now
            source?.health = .failing
            source?.lastFailure = failure
            var outcome = Outcome(found: 0, inserted: 0, updated: 0, skipped: 0, uncertain: 0)
            outcome.sources = [SourceResult(sourceId: sourceId, orgName: orgName, state: .failed(failure))]
            return outcome
        }

        // #801: this source's feed health lives on its own row, seeded from the three old global keys by
        // WatchedSourceBackfill. A merged baseline could never tell one source's dead scraper from
        // another's big season.
        let health = FeedReconcile.FeedHealthState(
            baseline: source?.baselineFeedCount ?? 0,
            degradedStreak: source?.degradedStreak ?? 0,
            lastDegradedCount: source?.lastDegradedCount ?? 0)
        let hadBaseline = health.baseline > 0

        // #888 part B: applySweep, because this IS a single-source sweep and it must still reconcile its
        // own report. `apply` alone no longer reconciles, and using it here would make Carnegie silently
        // stop marking anything gone: nothing would fail, shows would just quietly linger forever.
        var outcome = applySweep(
            events: events, clients: clients, history: history, blocked: blocked,
            feed: FeedCheck(sourceId: sourceId,
                            baseline: health.baseline,
                            // No row yet means no history, so it is treated as still in its warmup: it
                            // can find and rank shows but cannot mark any of them gone, which is exactly
                            // what "we have no feed history to judge an absence against" should mean.
                            successfulCheckCount: source?.successfulCheckCount ?? 0),
            sourceIds: [sourceId], into: context)

        // Fold this run into the source's own feed-health state: a full feed re-baselines immediately,
        // and a feed that stays degraded at a stable smaller level across selfHealThreshold scouts
        // re-baselines too, so a genuine sustained calendar shrink self-heals without one bad fetch
        // ratcheting the baseline down (#150/#152).
        recordCheck(on: source, events: events.count, health: health, now: now)

        outcome.sources = [SourceResult(sourceId: sourceId, orgName: orgName,
                                        state: .ingested(found: events.count),
                                        hadBaseline: hadBaseline)]
        return outcome
    }

    // One html source: fetch it, hash it, and decide. Never throws. Returns the page ONLY when this run
    // is going to read it, so the caller cannot accidentally spend a token on a run Dan did not start.
    private static func check(_ source: WatchedSource,
                              fetch: (URL) async throws -> FetchedPage,
                              depth: ScoutDepth, now: Date) async -> (SourceResult, FetchedPage?) {
        func result(_ state: SourceResult.State) -> SourceResult {
            SourceResult(sourceId: source.sourceId, orgName: source.orgName, state: state,
                         hadBaseline: source.baselineFeedCount > 0)
        }

        guard let listings = source.listingsURL, let url = URL(string: listings) else {
            // A watched source with no usable address cannot be checked, and saying so is the whole
            // point: silence here would be a source Dan believes is being watched and is not.
            let failure = SourceFailure.verdict(.unreadable)
            source.lastCheckedAt = now
            source.health = .failing
            source.lastFailure = failure
            return (result(.failed(failure)), nil)
        }

        let fetched: Result<FetchedPage, SourceFetchError>
        do {
            fetched = .success(try await fetch(url))
        } catch {
            fetched = .failure(fetchError(from: error))
        }

        switch SourceCheck.decide(source: source, result: fetched, depth: depth, now: now) {
        case .unchanged:
            return (result(.unchanged), nil)
        case .changedButNotRead:
            return (result(.changedNotRead), nil)
        case .failed(let f):
            return (result(.failed(f)), nil)
        case .read(let page):
            // Remember the hash of the bytes we are about to hand to the run. It cannot be recomputed at
            // ingest: that happens minutes later in another process, by which time the live page may have
            // moved on, and re-hashing would stamp a hash for bytes nobody ever read.
            source.pendingContentHash = page.contentHash
            return (result(.queuedForReading), page)
        }
    }

    // Pin each changed page to disk and hand the batch to ONE detached run.
    //
    // The app fetched and hashed these bytes itself, and the run is pointed at exactly those bytes on
    // disk. That is what keeps the listing SET (which shows exist, which are gone: the thing that
    // re-keys prospects and drives the reconcile) determined by what the app hashed, rather than by
    // whatever a website happened to serve an agent a second later.
    private static func queueForReading(_ pages: [(source: WatchedSource, page: FetchedPage)],
                                        pin: (FetchedPage, String) throws -> URL,
                                        launch: ([ScoutExtractQueueItem]) throws -> Void) throws {
        let items: [ScoutExtractQueueItem] = try pages.map { source, page in
            let pinned = try pin(page, source.sourceId)
            return ScoutExtractQueueItem(sourceId: source.sourceId,
                                         orgName: source.orgName,
                                         listingsURL: source.listingsURL,
                                         pagePath: pinned.path)
        }
        try launch(items)
    }

    // Named, actionable, and never a stack trace. "Runner not configured" is the first thing Dan will
    // hit and it has a one-step fix, so it must not surface as a Swift error description.
    private static func extractLaunchMessage(_ error: Error) -> String {
        switch error {
        case ScoutExtractService.ExtractLaunchError.runnerUnavailable:
            return "The reader that pulls listings off a page isn't set up yet, so the pages that changed couldn't be read. See docs/scout-extract-runbook.md. Nothing was lost: they'll be read on the next scout once it's configured."
        case ScoutExtractService.ExtractLaunchError.alreadyRunning:
            return "A previous run is still reading pages. The pages that changed will be read on the next scout."
        default:
            return "The pages that changed couldn't be handed off to be read (\(error)). They'll be tried again on the next scout."
        }
    }

    // Anything a source's extractor or fetcher throws that is not already typed is a connectivity
    // problem as far as the row is concerned. Named, not swallowed.
    private static func fetchError(from error: Error) -> SourceFetchError {
        (error as? SourceFetchError) ?? .unreachable
    }

    // Carnegie's watchlist row, or nil on a store whose #800 backfill has not run yet (and in a test
    // container that does not declare the model at all).
    private static func carnegieRow(in context: ModelContext) -> WatchedSource? {
        let id = WatchedSource.carnegieId
        let descriptor = FetchDescriptor<WatchedSource>(predicate: #Predicate { $0.sourceId == id })
        return (try? context.fetch(descriptor))?.first
    }

    // Records that this source was checked, and folds the run into its own feed-health history. Not
    // saved here: apply() already saved, and the caller's own save covers this (a lost health update is
    // recoverable, unlike a lost prospect).
    private static func recordCheck(on source: WatchedSource?, events: Int,
                                    health: FeedReconcile.FeedHealthState, now: Date) {
        guard let source else { return }
        let updated = FeedReconcile.updatedHealth(health, currentCount: events)
        source.baselineFeedCount = updated.baseline
        source.degradedStreak = updated.degradedStreak
        source.lastDegradedCount = updated.lastDegradedCount
        source.lastCheckedAt = now
        source.lastSucceededAt = now
        source.health = .ok
        source.lastFailure = nil
        // The warmup counter (#801). A source cannot mark anything gone until it has this many checks of
        // its own, so a brand-new source's first big import cannot look like a mass cancellation on its
        // second run.
        source.successfulCheckCount += 1
    }

    // #800: the accessors below are `nonisolated`. They touch nothing but UserDefaults, which is
    // thread-safe, and they were main-actor-isolated only by inheritance from this enum. The launch-time
    // WatchedSourceBackfill has to read this state to seed it onto Carnegie's row, and it runs outside
    // the main actor like every other migration in LaunchMigrations. Reading these keys through their
    // own accessors is the point: the alternative is the backfill hardcoding the same key strings, which
    // is exactly how two copies of a name drift apart.
    //
    // #801: the scout no longer WRITES the three feed-health keys; Carnegie's row owns that state now.
    // They are kept, read-only, for exactly one reason: WatchedSourceBackfill reads them to seed the row
    // on a store that has not migrated yet, and a store can migrate at any future launch. Deleting them
    // would silently reset Carnegie's tuned #150/#152 history to zero for anyone who upgrades late.

    nonisolated static let lastScoutKey = "scoutLastRunAt"
    // Store/read injectable so the persistence is testable without polluting the global
    // defaults (test side effects stay in a transient suite).
    nonisolated static func recordScout(at date: Date, in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastScoutKey)
    }
    nonisolated static func lastScoutedAt(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastScoutKey) as? Date
    }

    // The baseline a later run is judged against to spot a degraded/partial feed (#150), the
    // `baseline` field of the persisted feed-health state. runScout updates it through
    // recordFeedHealthState (a degraded run can't ratchet it down, but a sustained shrink re-baselines
    // it, #152). These two accessors remain for direct baseline reads/writes and tests. Injectable
    // defaults keep test side effects contained.
    nonisolated static let lastHealthyFeedCountKey = "scoutLastHealthyFeedCount"
    nonisolated static func recordHealthyFeedCount(_ count: Int, in defaults: UserDefaults = .standard) {
        defaults.set(count, forKey: lastHealthyFeedCountKey)
    }
    nonisolated static func lastHealthyFeedCount(in defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: lastHealthyFeedCountKey)   // 0 when unset = no baseline yet
    }

    // The degraded-streak half of the feed-health state (#152): how many consecutive degraded feeds
    // have held at a stable smaller level, and the size of the most recent one. Stored beside the
    // baseline (which keeps reusing lastHealthyFeedCountKey) so the self-heal decision survives
    // between scouts. Injectable defaults keep test side effects contained.
    nonisolated static let degradedStreakKey = "scoutDegradedStreakCount"
    nonisolated static let lastDegradedFeedCountKey = "scoutLastDegradedFeedCount"

    nonisolated static func feedHealthState(in defaults: UserDefaults = .standard) -> FeedReconcile.FeedHealthState {
        FeedReconcile.FeedHealthState(
            baseline: defaults.integer(forKey: lastHealthyFeedCountKey),
            degradedStreak: defaults.integer(forKey: degradedStreakKey),
            lastDegradedCount: defaults.integer(forKey: lastDegradedFeedCountKey))
    }

    nonisolated static func recordFeedHealthState(_ state: FeedReconcile.FeedHealthState, in defaults: UserDefaults = .standard) {
        defaults.set(state.baseline, forKey: lastHealthyFeedCountKey)
        defaults.set(state.degradedStreak, forKey: degradedStreakKey)
        defaults.set(state.lastDegradedCount, forKey: lastDegradedFeedCountKey)
    }

    // What the source whose events these are knows about its OWN feed, which is the only thing that
    // licenses the reconcile to read a stored show's absence as a cancellation (#801).
    //
    // nil means "these events are not a sweep of anybody's feed": a hand-added lead (#799) reports on
    // the one page Dan pasted and says nothing whatever about what Carnegie is still listing. With no
    // feed check there are no reports, so nothing can be marked gone. That makes #826 (two leads in a
    // row marking Dan's live Carnegie shows as disappeared) structurally impossible rather than
    // guarded by a flag a future caller could forget.
    struct FeedCheck: Equatable, Sendable {
        var sourceId: String
        var baseline: Int
        var successfulCheckCount: Int
        var verdict: PageVerdict = .upcomingListings
        // #887: events this run threw away (no venue, so their detail page was never read). A run that
        // dropped shows may still ADD and UPDATE, but its silence about a show is not evidence the show
        // was cancelled. Defaulted to a clean sweep, so a caller that does not know cannot accidentally
        // claim one.
        var rejectedCount: Int = 0
    }

    // #888 part B: one source sweeping its own feed, applied AND reconciled.
    //
    // `apply` is an UPSERT: it lands events and hands back what this source swept. Reconciling is a
    // whole-run decision, because "every owner of this show was asked and none has it" cannot be judged
    // one source at a time (that is the bug: with a single-element report list, `believable` was never
    // larger than one source, so a co-listed show could never be marked gone by anybody).
    //
    // A caller with SEVERAL sources (ScoutExtractIngest) therefore applies each, then reconciles once
    // with all their reports. A caller with exactly ONE (the native Carnegie sweep) uses this, so the
    // pairing lives in production code rather than being re-assembled by every call site, where it could
    // drift or simply be forgotten. Forgetting it is silent: shows would just quietly stop being marked
    // gone, and nothing would fail.
    @discardableResult
    static func applySweep(
        events: [ExtractedEvent],
        clients: [DownbeatClient],
        history: [HistoryRecord],
        blocked: BlockedCalendar,
        feed: FeedCheck,
        today: String = QueueModel.easternToday(),
        sourceIds: [String] = [],
        into context: ModelContext
    ) -> Outcome {
        let outcome = apply(events: events, clients: clients, history: history, blocked: blocked,
                            feed: feed, today: today, sourceIds: sourceIds, into: context)
        if let report = outcome.report {
            let allStored = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
            FeedReconcile.reconcile(stored: allStored, reports: [report], today: today)
        }
        return outcome
    }

    // Application of already-extracted events with injected data, so the full
    // classify -> match -> assemble -> upsert chain is testable without network/WebKit.
    //
    // #888 part B: this UPSERTS and hands back what the source swept (`Outcome.report`). It does NOT
    // reconcile: see applySweep above for why that is now the caller's decision.
    @discardableResult
    static func apply(
        events: [ExtractedEvent],
        clients: [DownbeatClient],
        history: [HistoryRecord],
        blocked: BlockedCalendar,
        feed: FeedCheck? = nil,
        // #798: injected so the upcoming-only guard below is testable against a pinned day instead of
        // the wall clock. The reconcile already needed today's date; now one value serves both.
        today: String = QueueModel.easternToday(),
        // #771: the source(s) this run's events came from, stamped onto every prospect it inserts and
        // UNIONED onto every one it updates. Empty means "we did not record it", which is what every
        // prospect predating #800 carries, and what a Prep-created one carries. An empty list can never
        // satisfy the reconcile's "every source that owns this show was asked", so it never accrues a
        // miss. That is exactly today's behavior for a non-Carnegie URL.
        sourceIds: [String] = [],
        into context: ModelContext
    ) -> Outcome {
        var inserted = 0, updated = 0, skipped = 0, uncertain = 0, collapsedIntoRun = 0
        var suppressedShows: [String] = []      // #802: by org name, folded into one line each below
        // Natural keys actually present in this run's feed, so the post-upsert reconcile can
        // tell which stored prospects dropped out (#133).
        var seenKeys = Set<String>()

        // Phase 1: classify each event and collect prospect decisions (no upserts yet).
        var prospects: [AssembledProspect] = []
        for e in events {
            let c = EventClassifier.classify(e)
            if c.confidence == .uncertain { uncertain += 1 }
            // #384: the venue is what aims a "don't want to shoot this" pass at ONE show rather than
            // at the whole org.
            let verdict = HistoryMatch.matchRelationship(name: e.title, venue: e.venue,
                                                         clients: clients, history: history)
            switch ProspectAssembler.decide(event: e, classification: c, verdict: verdict) {
            case .skip(let reason):
                skipped += 1
                // Only a REFUSAL is reported. The other skip (unreachable) means something entirely
                // different; a report where the lines do not all mean "somebody asked you to stop" is a
                // report that has to be read carefully, which means it will not be read at all.
                //
                // #901: a blocked date is no longer a skip of any kind. It is imported and flagged, so it
                // cannot reach this report by any route.
                if reason == .suppressed {
                    suppressedShows.append(Prospect.decodeHTMLEntities(e.title))
                }
            case .prospect(var p):
                p.sourceIds = sourceIds        // #771: stamped here; `decide` stays pure and clockless
                prospects.append(p)
            }
        }

        // Phase 2: collapse multi-night runs so only the representative night is upserted. Each row
        // carries its INDEX into `prospects` as its identity (#797), which is how a grouped run finds
        // its way back to the prospect it came from.
        let rows = prospects.enumerated().map { i, p in
            RunGrouping.RunRow(
                id: i,
                groupName: p.groupName,
                venue: p.venue,
                performanceDate: p.performanceDate,
                sourceListingURL: p.sourceListingURL
            )
        }
        let grouped = RunGrouping.group(rows)

        // Phase 3: upsert one prospect per grouped run. Every prospect is in exactly one run
        // (RunGrouping emits a group for every row, dated or not), so identity resolves all of them
        // and there is no leftover case to handle separately.
        //
        // #797: this used to resolve through a [sourceListingURL: AssembledProspect] dictionary, and
        // lost shows two ways. A listing URL is not unique, so an org publishing its whole season on
        // ONE page collapsed into a single prospect, last write wins, the rest gone and not even
        // counted. And a run whose representative row had no URL (representativeRow picks the
        // SHORTEST title, which can be the unlinked night) failed the URL guard and the whole run was
        // dropped, member nights included.
        for gr in grouped {
            guard prospects.indices.contains(gr.row.id) else { continue }
            let p = prospects[gr.row.id]

            // #798: the upcoming-only guard, and it lives HERE, at the run, on purpose.
            //
            // Carnegie's feed only ever returned a forward 90-day window, so nothing ever needed
            // this. An arbitrary org's page is the opposite: the #770 spike found 5 of 7 real sites
            // still displaying LAST season's dates, and one listing 11 concerts under a "Previous
            // Concerts This Season" heading. Without this, the first check of a new source floods the
            // queue with shows that already happened.
            //
            // Judged on the run's LAST night (`runEndDate ?? performanceDate`), so a run already
            // underway survives. Putting the same rule at the EVENT (inside ProspectAssembler.decide)
            // would look equivalent and would corrupt the store: past nights would be dropped BEFORE
            // grouping, so a live run would lose its opening night, its natural key would shift to
            // the next remaining night on every scout, and each run would re-key or duplicate the
            // same show. Dan's call (2026-07-11): a run underway keeps its OPENING-night date; the
            // queue already renders it as a run ("Jul 9 to 12"), so it reads as still running.
            //
            // An undated listing cannot be judged past, and "date to be confirmed" is a normal state
            // on an org's season page, so it is kept rather than silently dropped.
            let lastNight = EasternDate.runLastNight(runEndDate: gr.runEndDate,
                                                     performanceDate: gr.row.performanceDate)
            if EasternDate.runHasPassed(lastNight: lastNight, today: today) {
                skipped += gr.memberIds.count      // every night accounted for, none silently vanished
                continue
            }

            // Every night of the run beyond the one being upserted is folded into it, not lost:
            // counted so `found` always reconciles against what actually happened to each event.
            collapsedIntoRun += max(0, gr.memberIds.count - 1)

            // Fold run metadata onto the assembled prospect.
            var enriched = p
            enriched.runEndDate = gr.runEndDate
            enriched.partOfRelatedRun = gr.partOfRelatedRun
            enriched.runSourceURLs = gr.runSourceURLs

            // #901: the date conflict, and it lives HERE, at the run, for the same reason the guard above
            // does. `runEndDate` does not exist until the nights have been grouped, so a check on the
            // event (where the old blocked-date drop lived) can only ever see opening night: a four-night
            // run whose third night sits on a booked shoot passed clean, and Dan would have pitched a
            // show he could not finish.
            //
            // It FLAGS, it does not drop (Dan's call, 2026-07-13). A dropped show is a decision the app
            // made for him, silently, and he would rather see the clash and decide himself.
            enriched.conflictKey = blocked.conflict(performanceDate: enriched.performanceDate,
                                                    runEndDate: enriched.runEndDate)?.key

            let key = Prospect.makeNaturalKey(groupName: enriched.groupName, performanceDate: enriched.performanceDate, venue: enriched.venue)
            seenKeys.insert(key)
            let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })
            if let existing = (try? context.fetch(descriptor))?.first {
                // Exact natural-key match: update in place.
                apply(enriched, to: existing)
                updated += 1
            } else if let anyMatch = matchByAnyRunURL(enriched.runSourceURLs, groupName: enriched.groupName,
                                                      venue: enriched.venue, in: context) {
                // No exact key match, but a stored record shares one of this run's member
                // URLs: re-key to the new opening-night key and update in place so Dan's
                // keep/dismiss decision survives across run-window shifts (#132).
                anyMatch.naturalKey = key
                apply(enriched, to: anyMatch)
                updated += 1
            } else if let drifted = matchByStableSource(url: enriched.sourceListingURL,
                                                       date: enriched.performanceDate,
                                                       venue: enriched.venue, in: context) {
                // No exact key match, but the same source listing + date already exists:
                // the venue tweaked the title between runs. Re-key to the new title and
                // update in place so Dan's keep/dismiss decision survives (#29).
                drifted.naturalKey = key
                apply(enriched, to: drifted)
                updated += 1
            } else {
                context.insert(make(enriched, key: key))
                inserted += 1
            }
        }

        // Reconcile stored prospects against this run's feed: mark ones that dropped out (#133).
        //
        // #801: this now happens only when a SOURCE swept its own feed and said so (`feed`). A
        // hand-added lead (#799) comes through this same function on purpose, so that blocked dates,
        // the #769 do-not-contact suppression and the #798 upcoming-only guard all apply to it exactly
        // as they do to a scouted show. But it sweeps nobody's feed, so it produces no report, and with
        // no report nothing can be marked gone. That is what makes #826 impossible rather than merely
        // guarded: there is no flag left for a future caller to forget to set.
        //
        // Every remaining judgement (is this feed big enough to be believed, is this source past its
        // warmup, does a verdict of "quiet off-season" count as evidence) lives in SourceReport, judged
        // against THIS source's own baseline.
        // #888 part B: the report is RETURNED, and the caller reconciles. It used to be reconciled right
        // here, one source at a time, with a single-element list. So `believable` was never larger than
        // one source, and a show owned by TWO could never satisfy the rule's "every owner was asked",
        // whatever either source said. The careful, conservative half of this design was dead code that
        // read as working.
        //
        // A caller that has several sources' reports (ScoutExtractIngest, which lands a whole batched
        // extract run) now reconciles ONCE with all of them, so a co-listed show can finally be judged.
        //
        // A caller with NO feed (the lead path, #799) gets no report and so cannot reconcile at all.
        // That is still what makes #826 structurally impossible rather than guarded by a flag somebody
        // could forget: there is nothing to forget, because there is nothing to pass.
        let report: FeedReconcile.SourceReport? = feed.map { feed in
            FeedReconcile.SourceReport(
                sourceId: feed.sourceId,
                seenKeys: seenKeys,
                // Presence is judged against the RAW feed's listing URLs, not just what we upserted, so
                // a show we filtered out this run (newly blocked date, do-not-contact) isn't mistaken
                // for one the venue cancelled (#133).
                seenSourceURLs: Set(events.compactMap { $0.sourceUrl }),
                feedCount: events.count,
                baseline: feed.baseline,
                successfulCheckCount: feed.successfulCheckCount,
                verdict: feed.verdict,
                rejectedCount: feed.rejectedCount)
        }
        // Several shows by the same org become ONE line with a count. Four separate lines saying the
        // same thing is how a report becomes wallpaper.
        let suppressed = Dictionary(grouping: suppressedShows, by: { $0 })
            .map { SuppressedOrg(orgName: $0.key, showCount: $0.value.count) }
            .sorted { ($0.showCount, $1.orgName) > ($1.showCount, $0.orgName) }

        do {
            try context.save()
        } catch {
            // #499: everything above was classified/upserted in memory but never persisted.
            //
            // #888 part B: and so it carries NO report. A run whose writes did not land has not swept
            // anything, and letting it reconcile would judge a show absent from a feed that was never
            // actually recorded. Deliberately not merely "safe": there is nothing to reconcile against.
            var outcome = Outcome(found: events.count, inserted: inserted, updated: updated,
                                  skipped: skipped, uncertain: uncertain,
                                  collapsedIntoRun: collapsedIntoRun, saveFailed: true)
            outcome.suppressedOrgs = suppressed
            return outcome
        }
        var outcome = Outcome(found: events.count, inserted: inserted, updated: updated, skipped: skipped,
                              uncertain: uncertain, collapsedIntoRun: collapsedIntoRun)
        outcome.suppressedOrgs = suppressed
        outcome.report = report
        return outcome
    }

    // Matches an existing prospect that shares ANY of the given run member URLs, checking
    // both the stored sourceListingURL and the stored runSourceURLs (#132). Used when the
    // run's opening night has shifted between scouts so no exact natural key matches: the caller
    // then RE-KEYS that stored record, which is why this must be certain it is the same show.
    //
    // #797: a shared URL alone is not that certainty. An org that publishes its whole season on ONE
    // page gives every show the same listing URL, so URL-only matching handed back an UNRELATED act
    // and the caller re-keyed it, mutating one stored row over and over: twenty shows in, one row
    // out, and Dan's keep/dismiss on it silently transplanted onto a different act.
    //
    // The act and the venue must agree too. That is exactly what a genuine #132 run-window shift
    // preserves (the same act, at the same venue, on moved dates), so the case this exists for still
    // matches, while a season page full of strangers no longer does.
    private static func matchByAnyRunURL(_ urls: [String], groupName: String, venue: String?,
                                         in context: ModelContext) -> Prospect? {
        let candidates = Set(urls)
        guard !candidates.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return all.first { p in
            let sharesURL = (p.sourceListingURL.map { candidates.contains($0) } ?? false)
                || !Set(p.runSourceURLs).isDisjoint(with: candidates)
            guard sharesURL else { return false }
            return sameVenue(p.venue, venue) && GroupNameMatch.isConfident(p.groupName, groupName)
        }
    }

    // Venue equality for the re-key guards: a missing venue on both sides still counts as "the same
    // venue" (it is the same absence of information, which is the pre-#797 behavior for that case).
    private static func sameVenue(_ a: String?, _ b: String?) -> Bool {
        let canon: (String?) -> String = { ($0 ?? "").lowercased().trimmingCharacters(in: .whitespaces) }
        return canon(a) == canon(b)
    }

    // A prospect identified by its stable source listing (URL + date), used to recognize
    // the same event when its display title has drifted (#29). Fetch-all + filter is fine
    // for the local store's size and avoids optional-predicate gymnastics.
    //
    // #797: the venue must agree as well. On a season page every show shares one listing URL, so URL
    // + date alone would re-key one show onto a DIFFERENT act that happens to play the same night.
    // The title is deliberately NOT checked here: recognizing a drifted title is this matcher's
    // entire purpose, so the act name is the one thing it cannot rely on.
    private static func matchByStableSource(url: String?, date: String?, venue: String?,
                                            in context: ModelContext) -> Prospect? {
        guard let url, !url.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return all.first {
            $0.sourceListingURL == url && $0.performanceDate == date && sameVenue($0.venue, venue)
        }
    }

    private static func make(_ p: AssembledProspect, key: String) -> Prospect {
        let prospect = Prospect(
            naturalKey: key, groupName: p.groupName, discipline: p.discipline, venue: p.venue,
            performanceDate: p.performanceDate, sourceListingURL: p.sourceListingURL, websiteURL: p.websiteURL,
            priorRelationship: p.priorRelationship, production: p.production, profile: p.profile,
            coverage: p.coverage, fitScore: p.fitScore, tier: p.tier, fitReason: p.fitReason,
            matchedClientName: p.matchedClientName, possibleMatchSource: p.possibleMatchSource,
            possibleMatchName: p.possibleMatchName,
            runEndDate: p.runEndDate, partOfRelatedRun: p.partOfRelatedRun, runSourceURLs: p.runSourceURLs)
        prospect.presenter = p.presenter
        prospect.classificationConfidence = p.confidence
        prospect.downbeatClientId = p.downbeatClientId
        prospect.passedOnThisShow = p.passedOnThisShow
        prospect.sourceIds = p.sourceIds        // #771
        prospect.setScoutConflict(p.conflictKey)    // #901
        return prospect
    }

    // Refresh scout-owned fields; never touch status/dismissReason (Dan owns those).
    private static func apply(_ p: AssembledProspect, to existing: Prospect) {
        existing.groupName = p.groupName
        existing.presenter = p.presenter
        existing.venue = p.venue
        existing.performanceDate = p.performanceDate
        existing.sourceListingURL = p.sourceListingURL
        existing.profile = p.profile
        existing.coverage = p.coverage
        existing.fitReason = p.fitReason
        existing.possibleMatchSource = p.possibleMatchSource
        existing.possibleMatchName = p.possibleMatchName
        // #384: scout-owned, refreshed every run like the other scoring inputs. Read by Step B below
        // (via ClassificationOverride.rescored) and by the fresh score in p.
        existing.passedOnThisShow = p.passedOnThisShow
        existing.classificationConfidence = p.confidence  // scout-owned; refreshed each run
        // #901: scout-owned too, and refreshed to whatever is true NOW: a vacation Dan cancelled stops
        // flagging the show, and a shoot booked over a week he was merely away re-flags it under a new
        // key, which is a fact he has not seen and so is not covered by anything he cleared.
        existing.setScoutConflict(p.conflictKey)
        // NOTE: never touch conflictClearedKey here; Dan owns that decision (#901).
        // NOTE: never touch confidenceReviewedByDan here; Dan owns that acknowledgement.
        // NOTE: never touch classificationOverriddenByDan here; Dan owns that flag.

        // Two guards run over this prospect, and they are ORTHOGONAL: Dan can correct a prospect's
        // discipline at any time, unrelated to whether a performer match separately corrected its
        // relationship, and nothing stops both being true at once. So the two field groups resolve
        // INDEPENDENTLY, in order, rather than as nested branches. Checking classificationOverriddenByDan
        // first as an outer short-circuit would send a doubly-flagged prospect down the recompute-from-
        // the-fresh-org-match path and silently revert the performer correction, which is the exact
        // failure this guard exists to prevent, just triggered by an unrelated Dan action (#750).

        // Step A: the relationship identity. Gated only by the performer-match lock and this run's org
        // match; classificationOverriddenByDan has no say here.
        if p.orgMatchConfident {
            // A fresh, confident ORG match outranks a standing performer guess, so it wins and clears
            // the correction. The lock is a guard against silent reversion, never a permanent one-way
            // override.
            existing.priorRelationship = p.priorRelationship
            existing.matchedClientName = p.matchedClientName
            existing.downbeatClientId = p.downbeatClientId
            if existing.relationshipCorrectedByPerformerMatch { existing.clearPerformerMatch() }
        } else if existing.hasActivePerformerMatch {
            // The org name still matches nothing (it never did, which is why Prep had to look at the
            // performer at all). Leave Prep's correction exactly as it stands.
        } else {
            existing.priorRelationship = p.priorRelationship
            existing.matchedClientName = p.matchedClientName
            existing.downbeatClientId = p.downbeatClientId
        }

        // Step B: the score. Runs AFTER Step A, so `existing.priorRelationship` already holds whichever
        // value won above, and every branch below scores against the truth rather than a stale org guess.
        if existing.classificationOverriddenByDan {
            // Dan corrected the classification: keep his discipline/production values and re-score from
            // them (plus the freshly-updated profile/coverage and the Step A relationship) so fit stays
            // meaningful without reverting his correction. Because rescored() reads priorRelationship
            // straight off `existing`, this one call already reflects a protected performer match, with
            // no combined-rule branch needed. That is what makes the two guards compose.
            let refit = ClassificationOverride.rescored(existing, discipline: nil, production: nil)
            existing.fitScore = refit.score
            existing.tier = refit.tier.rawValue
        } else if existing.hasActivePerformerMatch && !p.orgMatchConfident {
            // Protect the score Prep computed from the performer match; the scout's own fresh score was
            // derived from an org match that found nothing, so copying it would undo the correction by
            // the back door while Step A left the relationship looking corrected.
            existing.discipline = p.discipline
            existing.production = p.production
        } else {
            existing.discipline = p.discipline
            existing.production = p.production
            existing.fitScore = p.fitScore
            existing.tier = p.tier
        }
        existing.runEndDate = p.runEndDate
        existing.partOfRelatedRun = p.partOfRelatedRun
        existing.runSourceURLs = p.runSourceURLs

        // #771: UNION, never replace, and this is the only correct home for it. The chain above
        // deliberately merges the same show arriving from a venue's calendar and from the presenter's
        // own site into this one row. Assigning p.sourceIds here would make the row remember only
        // whichever source ran last, and Phase 3's per-source reconcile would then find the show absent
        // from the forgotten source's feed and accrue misses toward disappearedFromFeed on a live show
        // Dan may already have drafted and emailed. Sorted so the stored order is stable rather than
        // whatever the Set happened to hash to.
        existing.sourceIds = Array(Set(existing.sourceIds).union(p.sourceIds)).sorted()

        existing.ingestedAt = Date()
    }

    // The days Dan cannot work, from BOTH sources at once (#901): Downbeat's booked shoots, and the days
    // off he types into Overture himself.
    //
    // This replaces `mergedBlockedDates`, which unioned Downbeat's exported dates with a local override
    // file, `overture-blocked-dates.json`. That file was read here and written NOWHERE: no editor, no
    // settings screen, no writer anywhere in the app, and it does not exist on Dan's Mac. Downbeat's
    // half, meanwhile, has always exported an empty list. So the guard has never once fired in the app's
    // life, and both halves of it looked exactly like a guard that worked.
    //
    // The days off now live in the store (DayOff), where the sheet that edits them and the scout that
    // reads them are looking at the same rows, instead of at a file only one of them knew about.
    static func blockedCalendar(export: (bookings: [OvertureBooking], blockedDates: [String]),
                                context: ModelContext) -> BlockedCalendar {
        BlockedCalendar.build(bookings: export.bookings,
                              exportedBlockedDates: export.blockedDates,
                              daysOff: DayOffEditing.ranges(in: context))
    }
}
