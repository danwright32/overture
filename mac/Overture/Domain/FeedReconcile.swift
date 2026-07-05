import Foundation

// Reconciles stored prospects against the latest scout feed (#133). The scout only ever
// inserts/updates, so a kept prospect that later gets cancelled or pulled would linger in
// the queue as if still happening. After a scout, this bumps a per-prospect "missed" counter
// for anything that came from a scouted source and is still in the future but was NOT in this
// run's feed; a prospect that reappears resets to 0. Two consecutive misses
// (`goneThreshold`) mark it gone, so a one-off partial feed never wrongly cancels a real show.
//
// Deliberately NEVER touches Dan's keep/dismiss/outcome state; `disappearedFromFeed` is an
// orthogonal scout-owned signal the queue reads to hide untouched ones and flag pursued ones.
enum FeedReconcile {
    // Consecutive misses before a prospect is treated as gone. Two, so a single partial/empty
    // feed (a transient Carnegie glitch) can't cancel a still-real show on its own.
    static let goneThreshold = 2

    // The hosts the scout actually covers today. Only prospects from these sources are
    // reconciled, so a Carnegie scout never flags a future prospect sourced elsewhere.
    static let scoutedHosts: Set<String> = ["carnegiehall.org"]

    // A run's feed must be at least this fraction of the last healthy run's size for its absences
    // to be trusted. Below it, the feed looks partial/degraded (a truncated page, a flaky fetch
    // that still returned 200), and trusting its absences would wrongly cancel real shows (#150).
    static let minHealthyFraction = 0.5

    // Whether this run's feed is large enough, relative to the last healthy run, to trust which
    // shows are MISSING from it. No baseline yet (first scout) trusts the feed.
    static func feedIsTrustworthy(currentCount: Int, baseline: Int, fraction: Double = minHealthyFraction) -> Bool {
        guard baseline > 0 else { return true }
        return Double(currentCount) >= Double(baseline) * fraction
    }

    // Persisted feed-health state across scouts (#152). `baseline` is the size the next run is
    // judged against (see feedIsTrustworthy). `degradedStreak`/`lastDegradedCount` track a run of
    // consecutive degraded feeds that have held at a stable smaller level, the signal that lets a
    // genuine, sustained calendar shrink self-heal without one bad fetch ratcheting the baseline down.
    struct FeedHealthState: Equatable, Sendable {
        var baseline: Int
        var degradedStreak: Int
        var lastDegradedCount: Int

        static let empty = FeedHealthState(baseline: 0, degradedStreak: 0, lastDegradedCount: 0)
    }

    // Consecutive degraded scouts at a stable smaller size before that smaller level is accepted as
    // the new normal (re-baselined). Three, so one or two anomalous fetches can't ratchet the
    // baseline down, but a calendar that genuinely shrank and stayed there stops being treated as a
    // permanent glitch and detection resumes (#152).
    static let selfHealThreshold = 3

    // Folds one scout's feed size into the health state.
    //   - A trustworthy (full) feed re-baselines immediately to its size and clears the streak.
    //   - A degraded feed extends the streak only while it stays at a stable level (each degraded
    //     run within the healthy fraction of the previous one, both ways). Once the streak reaches
    //     selfHealThreshold the stable smaller level becomes the new baseline, so detection resumes.
    //   - An empty feed is a broken fetch, not a smaller-but-real calendar, so it never builds toward
    //     (or resets) the streak; otherwise consecutive empties would re-baseline to zero.
    static func updatedHealth(_ state: FeedHealthState, currentCount: Int) -> FeedHealthState {
        if feedIsTrustworthy(currentCount: currentCount, baseline: state.baseline) {
            return FeedHealthState(baseline: currentCount, degradedStreak: 0, lastDegradedCount: 0)
        }
        guard currentCount > 0 else { return state }
        let stableWithPrior = state.degradedStreak > 0
            && feedIsTrustworthy(currentCount: currentCount, baseline: state.lastDegradedCount)
            && feedIsTrustworthy(currentCount: state.lastDegradedCount, baseline: currentCount)
        let streak = stableWithPrior ? state.degradedStreak + 1 : 1
        if streak >= selfHealThreshold {
            return FeedHealthState(baseline: currentCount, degradedStreak: 0, lastDegradedCount: 0)
        }
        return FeedHealthState(baseline: state.baseline, degradedStreak: streak, lastDegradedCount: currentCount)
    }

    // `seenSourceURLs` is the set of listing URLs in this run's RAW feed (before our own
    // blocked-date / DNC / unreachable filtering). A prospect is "still listed" if it was
    // upserted (seenKeys) OR any of its listing URLs is in the raw feed, so a show we merely
    // filtered out this run is NOT mistaken for one the venue cancelled.
    //
    // `currentFeedCount`/`baselineFeedCount` gate on feed health: a degraded (suspiciously small)
    // feed is skipped entirely, so its absences never accrue misses (#150). Defaults (0/0) mean
    // "no baseline" and trust the feed, preserving callers that don't pass them.
    static func reconcile(stored: [Prospect], seenKeys: Set<String>,
                          seenSourceURLs: Set<String> = [],
                          currentFeedCount: Int = 0, baselineFeedCount: Int = 0,
                          today: String,
                          scoutedHosts: Set<String> = scoutedHosts) {
        guard feedIsTrustworthy(currentCount: currentFeedCount, baseline: baselineFeedCount) else { return }
        for p in stored {
            if isStillListed(p, seenKeys: seenKeys, seenSourceURLs: seenSourceURLs) {
                p.missedScoutCount = 0                       // present this run: definitely live
            } else if isFromScoutedSource(p, hosts: scoutedHosts) && isFuture(p, today: today) {
                p.missedScoutCount += 1                       // gone from the venue's feed entirely
            }
            // Past performances and other-source prospects are left untouched: their absence is
            // not evidence of cancellation.
        }
    }

    private static func isStillListed(_ p: Prospect, seenKeys: Set<String>, seenSourceURLs: Set<String>) -> Bool {
        if seenKeys.contains(p.naturalKey) { return true }
        let urls = ([p.sourceListingURL].compactMap { $0 } + p.runSourceURLs)
        return urls.contains { seenSourceURLs.contains($0) }
    }

    private static func isFromScoutedSource(_ p: Prospect, hosts: Set<String>) -> Bool {
        guard let url = p.sourceListingURL else { return false }
        return hosts.contains { url.contains($0) }
    }

    // Future = any night of the (possibly multi-night) run is today or later. A run whose
    // opening night has passed but whose end date is still ahead is still a live show.
    private static func isFuture(_ p: Prospect, today: String) -> Bool {
        let last = p.runEndDate ?? p.performanceDate
        guard let last else { return false }
        return last >= today
    }
}
