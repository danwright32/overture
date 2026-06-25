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
        // Set when the Downbeat past-client export was missing, unreadable, or stale, so
        // warm/repeat matching ran degraded and Dan should be told (#22/#23).
        var clientListWarning: String? = nil

        // The single warning to show after a run, if any. Zero events here means the feed was
        // reached and parsed but nothing matched — distinct from a connection failure (the
        // thrown-error path, see ScoutFailure). For a 90-day window that's unusual and usually
        // means the feed's data format changed. Takes precedence over a client-list warning
        // (with no events there is nothing to match) (#27, #126).
        var warning: String? {
            if found == 0 {
                return "The scout reached the calendar feed but found no upcoming events. That's unusual for a 90-day window — the feed's data format may have changed."
            }
            return clientListWarning
        }
    }

    static func runScout(into context: ModelContext) async throws -> Outcome {
        let events = try await CarnegieExtractor().extract()
        let loaded = DownbeatBridge.loadWithHealth(now: Date())
        // History the matcher sees = any one-time legacy import + Overture's own activity,
        // so repeat-client recognition stays current as Dan sends and books (#19).
        let existing = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let history = loadLocalHistory() + LocalHistory.records(from: existing)
        let baseline = lastHealthyFeedCount()
        let blocked = mergedBlockedDates(exportBlocked: loaded.blockedDates, localOverride: loadBlockedDates())
        var outcome = apply(events: events, clients: loaded.clients, history: history,
                            blocked: blocked, baselineFeedCount: baseline, into: context)
        outcome.clientListWarning = DownbeatBridge.warningText(for: loaded.health)
        // Update the health baseline only after a trustworthy (full-sized) feed, so a degraded
        // run can't lower the bar for the next one (#150).
        if FeedReconcile.feedIsTrustworthy(currentCount: events.count, baseline: baseline) {
            recordHealthyFeedCount(events.count)
        }
        // Reconcile bookings from Downbeat: a contacted prospect that's now a Downbeat
        // client gets outcome booked automatically (#41).
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        if DownbeatBooking.reconcileBooked(prospects: all, clients: loaded.clients, bookings: loaded.bookings, health: loaded.health, now: Date()) > 0 {
            try? context.save()
        }
        // Record that a scout completed, so the masthead can show freshness (#35).
        recordScout(at: Date())
        return outcome
    }

    static let lastScoutKey = "scoutLastRunAt"
    // Store/read injectable so the persistence is testable without polluting the global
    // defaults (test side effects stay in a transient suite).
    static func recordScout(at date: Date, in defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastScoutKey)
    }
    static func lastScoutedAt(in defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastScoutKey) as? Date
    }

    // The size of the last HEALTHY (trustworthy) feed, the baseline a later run is judged against
    // to spot a degraded/partial feed (#150). Only updated after a trustworthy run, so one bad
    // fetch can't ratchet the baseline down. Injectable defaults keep test side effects contained.
    static let lastHealthyFeedCountKey = "scoutLastHealthyFeedCount"
    static func recordHealthyFeedCount(_ count: Int, in defaults: UserDefaults = .standard) {
        defaults.set(count, forKey: lastHealthyFeedCountKey)
    }
    static func lastHealthyFeedCount(in defaults: UserDefaults = .standard) -> Int {
        defaults.integer(forKey: lastHealthyFeedCountKey)   // 0 when unset = no baseline yet
    }

    // Application of already-extracted events with injected data, so the full
    // classify -> match -> assemble -> upsert chain is testable without network/WebKit.
    @discardableResult
    static func apply(
        events: [ExtractedEvent],
        clients: [DownbeatClient],
        history: [HistoryRecord],
        blocked: Set<String>,
        baselineFeedCount: Int = 0,
        into context: ModelContext
    ) -> Outcome {
        var inserted = 0, updated = 0, skipped = 0, uncertain = 0
        // Natural keys actually present in this run's feed, so the post-upsert reconcile can
        // tell which stored prospects dropped out (#133).
        var seenKeys = Set<String>()

        // Phase 1: classify each event and collect prospect decisions (no upserts yet).
        var prospects: [AssembledProspect] = []
        for e in events {
            let c = EventClassifier.classify(e)
            if c.confidence == .uncertain { uncertain += 1 }
            let verdict = HistoryMatch.matchRelationship(name: e.title, clients: clients, history: history)
            switch ProspectAssembler.decide(event: e, classification: c, verdict: verdict, blocked: blocked) {
            case .skip:
                skipped += 1
            case .prospect(let p):
                prospects.append(p)
            }
        }

        // Phase 2: collapse multi-night runs so only the opening night is upserted.
        let rows = prospects.map { p in
            RunGrouping.RunRow(
                groupName: p.groupName,
                venue: p.venue,
                performanceDate: p.performanceDate,
                sourceListingURL: p.sourceListingURL
            )
        }
        let grouped = RunGrouping.group(rows)

        // Build a lookup from sourceListingURL to AssembledProspect so we can find the
        // prospect that corresponds to each grouped run's opening night.
        var prospectByURL: [String: AssembledProspect] = [:]
        var prospectsWithoutURL: [AssembledProspect] = []
        for p in prospects {
            if let url = p.sourceListingURL {
                prospectByURL[url] = p
            } else {
                prospectsWithoutURL.append(p)
            }
        }

        // Phase 3: upsert one prospect per grouped run (opening night only).
        // We iterate grouped runs (already one per run) rather than per-night prospects.
        for gr in grouped {
            guard let openingURL = gr.row.sourceListingURL,
                  let p = prospectByURL[openingURL] else {
                continue
            }

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
            } else if let anyMatch = matchByAnyRunURL(enriched.runSourceURLs, in: context) {
                // No exact key match, but a stored record shares one of this run's member
                // URLs: re-key to the new opening-night key and update in place so Dan's
                // keep/dismiss decision survives across run-window shifts (#132).
                anyMatch.naturalKey = key
                apply(enriched, to: anyMatch)
                updated += 1
            } else if let drifted = matchByStableSource(url: enriched.sourceListingURL, date: enriched.performanceDate, in: context) {
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

        // Handle the rare case of a prospect with no source URL (cannot be grouped).
        for p in prospectsWithoutURL {
            let key = Prospect.makeNaturalKey(groupName: p.groupName, performanceDate: p.performanceDate, venue: p.venue)
            seenKeys.insert(key)
            let descriptor = FetchDescriptor<Prospect>(predicate: #Predicate { $0.naturalKey == key })
            if let existing = (try? context.fetch(descriptor))?.first {
                apply(p, to: existing)
                updated += 1
            } else {
                context.insert(make(p, key: key))
                inserted += 1
            }
        }
        // Reconcile stored prospects against this run's feed: mark ones that dropped out (#133).
        // Only when the feed actually returned events — an empty feed is a broken/glitching feed,
        // not "every show cancelled", so it must never accrue misses.
        if !events.isEmpty {
            let allStored = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
            // Presence is judged against the RAW feed's listing URLs, not just what we upserted,
            // so a show we filtered out this run (newly blocked date / DNC) isn't mistaken for
            // one the venue cancelled (#133).
            let seenSourceURLs = Set(events.compactMap { $0.sourceUrl })
            FeedReconcile.reconcile(stored: allStored, seenKeys: seenKeys,
                                    seenSourceURLs: seenSourceURLs,
                                    currentFeedCount: events.count, baselineFeedCount: baselineFeedCount,
                                    today: QueueModel.easternToday())
        }
        try? context.save()
        return Outcome(found: events.count, inserted: inserted, updated: updated, skipped: skipped, uncertain: uncertain)
    }

    // Matches an existing prospect that shares ANY of the given run member URLs, checking
    // both the stored sourceListingURL and the stored runSourceURLs (#132). Used when the
    // run's opening night has shifted between scouts so no exact natural key matches.
    private static func matchByAnyRunURL(_ urls: [String], in context: ModelContext) -> Prospect? {
        let candidates = Set(urls)
        guard !candidates.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return all.first { p in
            if let u = p.sourceListingURL, candidates.contains(u) { return true }
            return !Set(p.runSourceURLs).isDisjoint(with: candidates)
        }
    }

    // A prospect identified by its stable source listing (URL + date), used to recognize
    // the same event when its display title has drifted (#29). Fetch-all + filter is fine
    // for the local store's size and avoids optional-predicate gymnastics.
    private static func matchByStableSource(url: String?, date: String?, in context: ModelContext) -> Prospect? {
        guard let url, !url.isEmpty else { return nil }
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return all.first { $0.sourceListingURL == url && $0.performanceDate == date }
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
        return prospect
    }

    // Refresh scout-owned fields; never touch status/dismissReason (Dan owns those).
    private static func apply(_ p: AssembledProspect, to existing: Prospect) {
        existing.groupName = p.groupName
        existing.venue = p.venue
        existing.performanceDate = p.performanceDate
        existing.sourceListingURL = p.sourceListingURL
        existing.priorRelationship = p.priorRelationship
        existing.profile = p.profile
        existing.coverage = p.coverage
        existing.fitReason = p.fitReason
        existing.matchedClientName = p.matchedClientName
        existing.downbeatClientId = p.downbeatClientId
        existing.possibleMatchSource = p.possibleMatchSource
        existing.possibleMatchName = p.possibleMatchName
        existing.classificationConfidence = p.confidence  // scout-owned; refreshed each run
        // NOTE: never touch confidenceReviewedByDan here — Dan owns that acknowledgement.
        // NOTE: never touch classificationOverriddenByDan here — Dan owns that flag.
        if existing.classificationOverriddenByDan {
            // Dan corrected the classification: keep his discipline/production values and
            // re-score from them (plus the freshly-updated profile/coverage/priorRelationship)
            // so fit stays meaningful without reverting his correction.
            let refit = ClassificationOverride.rescored(existing, discipline: nil, production: nil)
            existing.fitScore = refit.score
            existing.tier = refit.tier.rawValue
        } else {
            existing.discipline = p.discipline
            existing.production = p.production
            existing.fitScore = p.fitScore
            existing.tier = p.tier
        }
        existing.runEndDate = p.runEndDate
        existing.partOfRelatedRun = p.partOfRelatedRun
        existing.runSourceURLs = p.runSourceURLs
        existing.ingestedAt = Date()
    }

    // Local booking history the matcher reads (group name + status), produced from
    // Downbeat/Supabase by scripts/export-history.ts. Absent file = no history yet.
    private static func loadLocalHistory() -> [HistoryRecord] {
        let url = appSupport("overture-history.json")
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode([HistoryRecord].self, from: data) else { return [] }
        return history
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
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Overture", isDirectory: true)
            .appendingPathComponent(name)
    }
}
