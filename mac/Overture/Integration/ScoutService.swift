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

        // The single warning to show after a run, if any. A save failure takes precedence over
        // everything else: the run may have found and processed events that never persisted, the
        // most actionable problem. Zero events here means the feed was reached and parsed but
        // nothing matched, distinct from a connection failure (the thrown-error path, see
        // ScoutFailure). For a 90-day window that's unusual and usually means the feed's data
        // format changed. Takes precedence over a client-list warning (with no events there is
        // nothing to match) (#27, #126).
        var warning: String? {
            if saveFailed {
                return "The scout ran but couldn't save its results. Run it again; if this keeps happening, something's wrong with the local store."
            }
            if found == 0 {
                return "The scout reached the calendar feed but found no upcoming events. That's unusual for a 90-day window. The feed's data format may have changed."
            }
            return clientListWarning
        }
    }

    // #799: the source is now injected rather than named here. It still defaults to Carnegie, which is
    // the only source that exists until Phase 2 gives the watchlist its rows, but the seam is what
    // lets the scout iterate sources later without this function knowing any of their names.
    // `defaults` is injected for the same reason the extractor is: this function records the last-scout
    // time and the feed-health baseline, and under the test host `UserDefaults.standard` is the LIVE
    // app's own preference domain. So the scout's entry point had no success-path test, not because it
    // was unimportant but because testing it would have written into Dan's real app. A scratch domain
    // fixes that, which matters before Phase 4 turns this into the loop over every watched source.
    static func runScout(into context: ModelContext,
                         extractor: any SourceExtractor = CarnegieExtractor(),
                         defaults: UserDefaults = .standard) async throws -> Outcome {
        let events = try await extractor.extract().events
        let loaded = DownbeatBridge.loadWithHealth(now: Date())
        // History the matcher sees = any one-time legacy import + Overture's own activity,
        // so repeat-client recognition stays current as Dan sends and books (#19).
        let existing = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let history = LocalHistory.forMatching(existing: existing)
        let blocked = mergedBlockedDates(exportBlocked: loaded.blockedDates, localOverride: loadBlockedDates())

        // #801: Carnegie's feed health lives on ITS OWN ROW now, not in three global UserDefaults keys.
        // The keys could only ever describe "the feed" (singular): the moment a second source exists, a
        // shared baseline is structurally unable to tell one source's dead scraper from another's big
        // season, and both of the failures Dan named live inside that one flaw. The row was seeded from
        // those keys by WatchedSourceBackfill (#800), so the #150/#152 self-heal machinery carries on
        // with its own tuned history rather than restarting from zero.
        let source = carnegieRow(in: context)
        let health = FeedReconcile.FeedHealthState(
            baseline: source?.baselineFeedCount ?? 0,
            degradedStreak: source?.degradedStreak ?? 0,
            lastDegradedCount: source?.lastDegradedCount ?? 0)

        var outcome = apply(
            events: events, clients: loaded.clients, history: history, blocked: blocked,
            feed: FeedCheck(sourceId: WatchedSource.carnegieId,
                            baseline: health.baseline,
                            // A store whose backfill has not run yet has no row and therefore no
                            // history. It is treated as still in its warmup, so it can find and rank
                            // shows but cannot mark any of them gone: exactly what "we have no feed
                            // history to judge an absence against" should mean.
                            successfulCheckCount: source?.successfulCheckCount ?? 0),
            sourceIds: [WatchedSource.carnegieId], into: context)
        outcome.clientListWarning = DownbeatBridge.warningText(for: loaded.health)

        // Fold this run into the source's feed-health state: a full feed re-baselines immediately, and a
        // feed that stays degraded at a stable smaller level across selfHealThreshold scouts re-baselines
        // too, so a genuine sustained calendar shrink self-heals without one bad fetch ratcheting the
        // baseline down (#150/#152).
        recordCheck(on: source, events: events.count, health: health, now: Date())

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
    }

    // Application of already-extracted events with injected data, so the full
    // classify -> match -> assemble -> upsert chain is testable without network/WebKit.
    @discardableResult
    static func apply(
        events: [ExtractedEvent],
        clients: [DownbeatClient],
        history: [HistoryRecord],
        blocked: Set<String>,
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
            switch ProspectAssembler.decide(event: e, classification: c, verdict: verdict, blocked: blocked) {
            case .skip:
                skipped += 1
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
        if let feed {
            let allStored = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
            let report = FeedReconcile.SourceReport(
                sourceId: feed.sourceId,
                seenKeys: seenKeys,
                // Presence is judged against the RAW feed's listing URLs, not just what we upserted, so
                // a show we filtered out this run (newly blocked date, do-not-contact) isn't mistaken
                // for one the venue cancelled (#133).
                seenSourceURLs: Set(events.compactMap { $0.sourceUrl }),
                feedCount: events.count,
                baseline: feed.baseline,
                successfulCheckCount: feed.successfulCheckCount,
                verdict: feed.verdict)
            FeedReconcile.reconcile(stored: allStored, reports: [report], today: today)
        }
        do {
            try context.save()
        } catch {
            // #499: everything above was classified/upserted in memory but never persisted.
            return Outcome(found: events.count, inserted: inserted, updated: updated,
                           skipped: skipped, uncertain: uncertain,
                           collapsedIntoRun: collapsedIntoRun, saveFailed: true)
        }
        return Outcome(found: events.count, inserted: inserted, updated: updated, skipped: skipped,
                       uncertain: uncertain, collapsedIntoRun: collapsedIntoRun)
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
        prospect.classificationConfidence = p.confidence
        prospect.downbeatClientId = p.downbeatClientId
        prospect.passedOnThisShow = p.passedOnThisShow
        prospect.sourceIds = p.sourceIds        // #771
        return prospect
    }

    // Refresh scout-owned fields; never touch status/dismissReason (Dan owns those).
    private static func apply(_ p: AssembledProspect, to existing: Prospect) {
        existing.groupName = p.groupName
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

    // The days the scout suppresses: Downbeat's exported blockedDates (the canonical source,
    // #156) unioned with the optional local override file, deduplicated. Pure for testing.
    static func mergedBlockedDates(exportBlocked: [String], localOverride: Set<String>) -> Set<String> {
        Set(exportBlocked).union(localOverride)
    }

    private static func loadBlockedDates() -> Set<String> {
        let url = appSupport("overture-blocked-dates.json")
        guard let data = try? Data(contentsOf: url),
              let dates = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return Set(dates)
    }

    private static func appSupport(_ name: String) -> URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent(name)
    }
}
