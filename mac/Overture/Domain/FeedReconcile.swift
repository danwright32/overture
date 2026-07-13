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

    // #801: `scoutedHosts` (a substring match on "carnegiehall.org") is GONE. Provenance is
    // Prospect.sourceIds, recorded when the show was ingested, not guessed from its URL at reconcile
    // time. A host string could only ever answer "did this come from the one source we had".

    // A run's feed must be at least this fraction of the last healthy run's size for its absences
    // to be trusted. Below it, the feed looks partial/degraded (a truncated page, a flaky fetch
    // that still returned 200), and trusting its absences would wrongly cancel real shows (#150).
    static let minHealthyFraction = 0.5

    // #887: how much of a run's OWN output may have been thrown away (ExtractedEventGuard rejected it,
    // almost always because its detail page was never read) before that run's silence about a show stops
    // being worth anything.
    //
    // Dan's call (2026-07-13). This shipped as a strict zero, and strict zero was wrong in a way worth
    // recording: a "venue TBA" listing has no venue and never will, so a real calendar carrying one would
    // have been unable to mark ANYTHING cancelled, ever, with nothing anywhere saying the cancellation
    // check had switched itself off for that source. That is #888's "a rule that silently never fires",
    // deliberately built in.
    //
    // Five percent, so one stray listing among dozens is tolerated and the failure that started all this
    // (20 of 80 shows unread, 25%) is nowhere near it. A SMALL source stays effectively strict, and that
    // is right rather than a wart: on a six-show calendar, one unread detail page is a sixth of
    // everything we know about that source.
    static let maxRejectedFraction = 0.05

    // #887/#891: could this run READ enough of what it looked at for its silence about a show to mean
    // anything? A run that threw a large share of its own events away (no venue, so their detail page was
    // never read) does not know how many OTHERS it silently failed to reach.
    //
    // A free function, and the ONE place this line is drawn. The Sources sheet has to tell Dan when a
    // source has lost the ability to mark shows gone (#891), and a display that re-derived the tolerance
    // for itself would eventually disagree with the reconcile, telling him cancellation is working on a
    // source where it is switched off. Worse than saying nothing.
    //
    // A run that kept NOTHING is a broken run, not a fully-rejected sweep to be reasoned about, and never
    // gets the tolerance.
    static func rejectedIsWithinTolerance(readable: Int, unreadable: Int,
                                          fraction: Double = maxRejectedFraction) -> Bool {
        guard unreadable > 0 else { return true }
        guard readable > 0 else { return false }
        return Double(unreadable) / Double(readable + unreadable) <= fraction
    }

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

    // What ONE source reported about its OWN feed this run (#801).
    //
    // A report exists only for a source that was actually checked and returned something. A source that
    // failed, that was skipped because its page had not changed, or that was deferred over the run's
    // budget has no report at all, and so cannot cause anything to be marked gone. Silence from a
    // source nobody asked is not evidence.
    struct SourceReport: Equatable, Sendable {
        var sourceId: String
        // What this source listed: the natural keys we upserted from it, and the listing URLs in its
        // RAW feed (before our own blocked-date / do-not-contact / unreachable filtering, so a show we
        // merely filtered out this run is never mistaken for one the venue cancelled).
        var seenKeys: Set<String>
        var seenSourceURLs: Set<String>
        // Judged against THIS source's own baseline. A merged multi-source count must never feed a
        // shared baseline: one healthy source's big season would mask another's dead scraper, and both
        // of the failures Dan named live inside that one mistake.
        var feedCount: Int
        var baseline: Int
        var successfulCheckCount: Int
        var verdict: PageVerdict
        // #887: how many events this run THREW AWAY (ExtractedEventGuard rejected them, almost always
        // because their detail page was never read, so they carry no venue). Defaulted, because a caller
        // that does not know is a caller reporting a clean sweep, and every existing one is.
        var rejectedCount: Int = 0

        // #887/#891: was this run able to actually READ most of what it looked at? Delegated to the free
        // function above, which is the ONE place this line is drawn, because the Sources sheet has to tell
        // Dan the same thing (#891) and a second copy of the rule would eventually disagree with this one.
        var rejectedIsWithinTolerance: Bool {
            FeedReconcile.rejectedIsWithinTolerance(readable: feedCount, unreadable: rejectedCount)
        }

        // Whether this source's SILENCE about a show can be believed. That is a far higher bar than
        // whether it can be believed about what it CAN see (`seenKeys`, always believed). Five ways a
        // source that genuinely ran still has nothing to say about a show being absent:
        var absenceIsEvidence: Bool {
            // #887: this run threw events away. They were rejected for having no venue, which almost
            // always means their own detail page was never read, and a run that failed to read some
            // detail pages does not know how many OTHERS it silently failed to reach. Its silence about
            // a show is therefore worth nothing.
            //
            // The degradation guard below cannot cover this, and that is the whole point of a separate
            // check rather than trusting it: minHealthyFraction is 0.5, so a run that read only 60 of a
            // source's 80 shows still reports 75% of baseline and sails straight through. Losing one
            // quarter of a source is the single most likely partial failure and the one #150 cannot see.
            //
            // Tolerated up to maxRejectedFraction of everything this run produced, no further. See that
            // constant for why it is not zero: a strict zero disabled cancellation forever, and silently,
            // on any calendar carrying a permanent "venue TBA" listing.
            //
            // Measured against what the RUN returned (kept + thrown away), not against the baseline: this
            // asks "how much of what you just looked at could you not actually read", which is a question
            // about THIS run's reliability, and it stays right even on a source whose calendar genuinely
            // grew or shrank since the baseline was taken.
            guard rejectedIsWithinTolerance else { return false }
            // A quiet off-season, an unreadable page, or a page with no dated content tells us nothing
            // about whether any particular show was cancelled.
            guard verdict == .upcomingListings else { return false }
            // An empty feed is a broken fetch, not "every show cancelled".
            guard feedCount > 0 else { return false }
            // A brand-new source imports a whole season on its first check and may legitimately look
            // different on its second. It cannot mark anything gone before it has a history of its own.
            guard successfulCheckCount >= WatchedSource.warmupRuns else { return false }
            // A suspiciously small feed against this source's own baseline is a degraded fetch (#150).
            return feedIsTrustworthy(currentCount: feedCount, baseline: baseline)
        }
    }

    // Marks shows that have dropped out of every feed that ever carried them (#133, per-source #801).
    //
    // The rule, stated once: absence is evidence of cancellation ONLY when every source that ever
    // claimed this show was asked this run, and none of them has it.
    //
    // Presence and blame are deliberately different questions, judged against different sets. ANY
    // source that reported can prove a show is alive, even one too degraded to be trusted about what is
    // missing. Only a source whose silence is evidence can take one away.
    static func reconcile(stored: [Prospect], reports: [SourceReport], today: String) {
        let seenKeys = reports.reduce(into: Set<String>()) { $0.formUnion($1.seenKeys) }
        let seenSourceURLs = reports.reduce(into: Set<String>()) { $0.formUnion($1.seenSourceURLs) }
        let believable = Set(reports.filter(\.absenceIsEvidence).map(\.sourceId))

        for p in stored {
            if isStillListed(p, seenKeys: seenKeys, seenSourceURLs: seenSourceURLs) {
                p.missedScoutCount = 0                                  // listed somewhere: definitely live
            } else if isFuture(p, today: today), everyOwnerWasAskedAndNoneHasIt(p, believable: believable) {
                p.missedScoutCount += 1
            }
            // Everything else is left untouched. A past performance, a show whose sources were not all
            // checked, and a show nobody claims are all cases where absence proves nothing.
        }
    }

    private static func isStillListed(_ p: Prospect, seenKeys: Set<String>, seenSourceURLs: Set<String>) -> Bool {
        if seenKeys.contains(p.naturalKey) { return true }
        let urls = ([p.sourceListingURL].compactMap { $0 } + p.runSourceURLs)
        return urls.contains { seenSourceURLs.contains($0) }
    }

    // The conservative half of the rule, and the reason a show co-listed by a venue and a presenter
    // cannot be marked gone by the venue alone: the presenter might still be listing it, and we did not
    // ask. A show is gone only when everyone who ever claimed it has been asked and none of them has it.
    private static func everyOwnerWasAskedAndNoneHasIt(_ p: Prospect, believable: Set<String>) -> Bool {
        // A prospect nobody claims (created by Prep, or predating #800) can never be marked gone: no
        // source's silence is about it. This guard is load-bearing, not defensive: allSatisfy is
        // VACUOUSLY TRUE of an empty list, so without it every sourceless prospect would be blamed on
        // every run and marked gone, which is the exact class of bug this whole phase exists to prevent.
        guard !p.sourceIds.isEmpty else { return false }
        return p.sourceIds.allSatisfy(believable.contains)
    }

    // Future = any night of the (possibly multi-night) run is today or later. A run whose opening
    // night has passed but whose end date is still ahead is still a live show. #798: the same rule
    // the scout's import guard applies, so it is defined once (EasternDate.runIsLive) rather than
    // twice. An undated prospect is not live, so it never accrues misses on a date nobody has.
    private static func isFuture(_ p: Prospect, today: String) -> Bool {
        EasternDate.runIsLive(
            lastNight: EasternDate.runLastNight(runEndDate: p.runEndDate,
                                                performanceDate: p.performanceDate),
            today: today)
    }
}
