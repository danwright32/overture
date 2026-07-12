import Testing
import Foundation
import SwiftData
@testable import Overture

// #133, rewritten per-source for #801.
//
// Reconcile is the one part of Overture that can REMOVE a show from Dan's view, so the whole of this
// suite is about the conditions under which it is allowed to. The rule it now enforces is:
//
//   absence is evidence of cancellation ONLY when every source that ever claimed this show was asked
//   this run, and none of them has it.
//
// The old rule was a substring match on carnegiehall.org against one global feed count. With a second
// source that is structurally unable to tell "source 7's scraper died" from "source 1 had a big
// season", and the cost of getting it wrong is a show Dan kept, drafted and emailed vanishing from his
// queue.
@MainActor
@Suite("Feed reconcile, per source (#133, #801)")
struct FeedReconcileTests {
    private func prospect(key: String, date: String?, source: String?,
                          sourceIds: [String] = ["carnegie"],
                          status: ReviewStatus = .new, missed: Int = 0,
                          runEnd: String? = nil) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Weill Recital Hall",
                         performanceDate: date, sourceListingURL: source, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        p.missedScoutCount = missed
        p.runEndDate = runEnd
        p.sourceIds = sourceIds
        return p
    }

    // A source that swept its feed and can be believed about what is missing from it: healthy count,
    // past its warmup, upcoming listings.
    private func report(_ sourceId: String, keys: Set<String> = [], urls: Set<String> = [],
                        count: Int = 40, baseline: Int = 40,
                        checks: Int = WatchedSource.warmupRuns,
                        verdict: PageVerdict = .upcomingListings) -> FeedReconcile.SourceReport {
        FeedReconcile.SourceReport(sourceId: sourceId, seenKeys: keys, seenSourceURLs: urls,
                                   feedCount: count, baseline: baseline,
                                   successfulCheckCount: checks, verdict: verdict)
    }

    private let carnegieURL = "https://www.carnegiehall.org/Calendar/2026/08/01/x"
    private let today = "2026-06-25"

    // MARK: - The base behaviour (#133), now expressed per source

    @Test func aFutureShowAbsentFromItsOwnSourcesFeedGetsAMiss() {
        let p = prospect(key: "gone", date: "2026-08-01", source: carnegieURL)
        FeedReconcile.reconcile(stored: [p], reports: [report("carnegie")], today: today)
        #expect(p.missedScoutCount == 1)
        #expect(p.disappearedFromFeed == false)   // one miss isn't gone yet
    }

    @Test func twoConsecutiveMissesMarkItGone() {
        let p = prospect(key: "gone", date: "2026-08-01", source: carnegieURL, missed: 1)
        FeedReconcile.reconcile(stored: [p], reports: [report("carnegie")], today: today)
        #expect(p.missedScoutCount == 2)
        #expect(p.disappearedFromFeed == true)
    }

    @Test func reappearingInTheFeedResetsTheCounter() {
        let p = prospect(key: "back", date: "2026-08-01", source: carnegieURL, missed: 2)
        FeedReconcile.reconcile(stored: [p], reports: [report("carnegie", keys: ["back"])], today: today)
        #expect(p.missedScoutCount == 0)
        #expect(p.disappearedFromFeed == false)
    }

    @Test func pastPerformanceIsNeverFlaggedGone() {
        // It happened. Absence from a forward-looking feed is expected, not a cancellation.
        let p = prospect(key: "past", date: "2026-06-01", source: carnegieURL, missed: 1)
        FeedReconcile.reconcile(stored: [p], reports: [report("carnegie")], today: today)
        #expect(p.missedScoutCount == 1)   // untouched, never pushed over the threshold
    }

    @Test func aRunStillRunningTodayCountsAsFuture() {
        let p = prospect(key: "run", date: "2026-06-20", source: carnegieURL, runEnd: "2026-07-10")
        FeedReconcile.reconcile(stored: [p], reports: [report("carnegie")], today: today)
        #expect(p.missedScoutCount == 1)
    }

    @Test func queueItemCarriesTheDisappearedFlag() {
        let p = prospect(key: "gone", date: "2026-08-01", source: carnegieURL, missed: 2)
        #expect(p.disappearedFromFeed == true)
        #expect(QueueItem(p).disappearedFromFeed == true)
    }

    @Test func stillListedButFilteredOutIsNotFlaggedGone() {
        // Present in the source's RAW feed but filtered out of the upsert this run (a newly blocked
        // date). Filtered is not cancelled.
        let p = prospect(key: "kept-but-filtered", date: "2026-08-01", source: carnegieURL, missed: 1)
        FeedReconcile.reconcile(stored: [p], reports: [report("carnegie", urls: [carnegieURL])], today: today)
        #expect(p.missedScoutCount == 0)
    }

    @Test func presenceByAnyRunMemberURLCountsAsListed() {
        let night1 = "https://www.carnegiehall.org/event/night1"
        let night2 = "https://www.carnegiehall.org/event/night2"
        let p = prospect(key: "run", date: "2026-08-01", source: night1, missed: 1)
        p.runSourceURLs = [night1, night2]
        FeedReconcile.reconcile(stored: [p], reports: [report("carnegie", urls: [night2])], today: today)
        #expect(p.missedScoutCount == 0)
    }

    // MARK: - Only a source that was asked, and can be believed, may blame

    // THE test this phase exists for. A show listed by a venue AND by the presenter dedupes to one row
    // carrying both ids. The venue drops it; the presenter still lists it. It is not cancelled, and
    // nothing may mark it gone.
    @Test func aShowStillListedByOneOfItsTwoSourcesAccruesNothing() {
        let p = prospect(key: "co-listed", date: "2026-08-01", source: carnegieURL,
                         sourceIds: ["venue-a", "presenter-b"])
        FeedReconcile.reconcile(
            stored: [p],
            reports: [report("venue-a"),                                   // dropped it
                      report("presenter-b", keys: ["co-listed"])],         // still lists it
            today: today)
        #expect(p.missedScoutCount == 0)
    }

    // The other half, and the conservative one. Both sources own the show, only one ran. Its silence
    // is not enough: the source that was never asked might still be listing it. A show is only gone
    // when everyone who ever claimed it has been asked and none of them has it.
    @Test func aSourceThatWasNotCheckedThisRunCannotHaveItsSilenceCountedAgainstIt() {
        let p = prospect(key: "co-listed", date: "2026-08-01", source: carnegieURL,
                         sourceIds: ["venue-a", "presenter-b"])
        FeedReconcile.reconcile(stored: [p], reports: [report("venue-a")], today: today)  // b never ran
        #expect(p.missedScoutCount == 0)
    }

    @Test func whenEverySourceRanAndNoneListsItTheShowIsGone() {
        let p = prospect(key: "really-gone", date: "2026-08-01", source: carnegieURL,
                         sourceIds: ["venue-a", "presenter-b"])
        FeedReconcile.reconcile(stored: [p], reports: [report("venue-a"), report("presenter-b")],
                                today: today)
        #expect(p.missedScoutCount == 1)
    }

    // A source that FAILED has no report, so it cannot blame anything. A dead scraper must never look
    // like a cancelled season.
    @Test func aSourceThatFailedItsCheckAccruesNothing() {
        let p = prospect(key: "safe", date: "2026-08-01", source: carnegieURL)
        FeedReconcile.reconcile(stored: [p], reports: [], today: today)
        #expect(p.missedScoutCount == 0)
    }

    // Same for a source skipped because its page had not changed, or deferred over budget: no report,
    // no blame. Deferred is not "fine" and it is not "failing"; it is "not asked".
    @Test func aSourceThatWasSkippedOrDeferredAccruesNothing() {
        let p = prospect(key: "safe", date: "2026-08-01", source: carnegieURL)
        FeedReconcile.reconcile(stored: [p], reports: [report("some-other-source")], today: today)
        #expect(p.missedScoutCount == 0)
    }

    // #150, now per source: a suspiciously small feed relative to THIS source's own baseline is a
    // degraded fetch, and its absences cannot be trusted.
    @Test func aDegradedFeedCannotBlameEvenThoughItRan() {
        let p = prospect(key: "real-show", date: "2026-08-01", source: carnegieURL)
        FeedReconcile.reconcile(stored: [p], reports: [report("carnegie", count: 4, baseline: 80)],
                                today: today)
        #expect(p.missedScoutCount == 0)
    }

    @Test func aHealthyFeedStillBlamesATrueAbsence() {
        let p = prospect(key: "real-show", date: "2026-08-01", source: carnegieURL)
        FeedReconcile.reconcile(stored: [p], reports: [report("carnegie", count: 79, baseline: 80)],
                                today: today)
        #expect(p.missedScoutCount == 1)
    }

    // Presence and blame are DIFFERENT questions. A source too degraded to be believed about what is
    // missing is still perfectly believable about what it can see: if it lists the show, the show is
    // alive, and the counter resets.
    @Test func aDegradedFeedCanStillProveAShowIsAlive() {
        let p = prospect(key: "listed", date: "2026-08-01", source: carnegieURL, missed: 1)
        FeedReconcile.reconcile(
            stored: [p],
            reports: [report("carnegie", keys: ["listed"], count: 4, baseline: 80)],
            today: today)
        #expect(p.missedScoutCount == 0)
    }

    // An empty feed is a broken fetch, not "every show cancelled".
    @Test func anEmptyFeedBlamesNothing() {
        let p = prospect(key: "safe", date: "2026-08-01", source: carnegieURL)
        FeedReconcile.reconcile(stored: [p], reports: [report("carnegie", count: 0)], today: today)
        #expect(p.missedScoutCount == 0)
    }

    // A quiet off-season, or a page we could not read, is not a cancellation either. Only a source that
    // actually returned upcoming listings has an opinion worth acting on.
    @Test func onlyAnUpcomingListingsVerdictMayBlame() {
        for verdict in [PageVerdict.allPast, .noDatedContent, .unreadable] {
            let p = prospect(key: "safe", date: "2026-08-01", source: carnegieURL)
            FeedReconcile.reconcile(stored: [p],
                                    reports: [report("carnegie", count: 40, verdict: verdict)],
                                    today: today)
            #expect(p.missedScoutCount == 0, "a \(verdict.rawValue) verdict must not blame anything")
        }
    }

    // A brand-new source imports a whole season on its first check and may legitimately look different
    // on its second. It cannot mark anything gone before it has a feed history of its own.
    @Test func aSourceInsideItsWarmupBlamesNothing() {
        let p = prospect(key: "safe", date: "2026-08-01", source: carnegieURL)
        FeedReconcile.reconcile(stored: [p],
                                reports: [report("carnegie", checks: WatchedSource.warmupRuns - 1)],
                                today: today)
        #expect(p.missedScoutCount == 0)
    }

    @Test func aSourcePastItsWarmupBlamesNormally() {
        let p = prospect(key: "gone", date: "2026-08-01", source: carnegieURL)
        FeedReconcile.reconcile(stored: [p],
                                reports: [report("carnegie", checks: WatchedSource.warmupRuns)],
                                today: today)
        #expect(p.missedScoutCount == 1)
    }

    // MARK: - The prospects nobody owns

    // A prospect with no recorded source (created by Prep, or predating #800) can never accrue a miss:
    // no source ever claimed it, so no source's silence is about it.
    //
    // Note the trap this guards. "Every source that owns it was asked" is VACUOUSLY TRUE of an empty
    // list, so a naive allSatisfy would blame every one of these on every run and mark them all gone.
    // That is the exact class of bug this phase exists to prevent, one layer down.
    @Test func aProspectWithNoRecordedSourceNeverAccruesAMiss() {
        let p = prospect(key: "prep-made", date: "2026-08-01", source: nil, sourceIds: [])
        FeedReconcile.reconcile(stored: [p], reports: [report("carnegie")], today: today)
        #expect(p.missedScoutCount == 0)
        #expect(p.disappearedFromFeed == false)
    }

    // A hand-added lead has no feed to be absent from, so it is permanently exempt without needing a
    // special case: "manual" is never a source that was checked, so it is never in the believable set.
    @Test func aHandAddedLeadIsNeverMarkedGone() {
        let p = prospect(key: "manual-lead", date: "2026-08-01", source: "https://org.example/show",
                         sourceIds: [WatchedSource.manualId])
        FeedReconcile.reconcile(stored: [p], reports: [report("carnegie")], today: today)
        #expect(p.missedScoutCount == 0)
    }

    // MARK: - Feed health (#150/#152), unchanged pure logic, now applied per source

    @Test func feedTrustworthinessGatesOnBaseline() {
        #expect(FeedReconcile.feedIsTrustworthy(currentCount: 3, baseline: 0) == true)    // first check
        #expect(FeedReconcile.feedIsTrustworthy(currentCount: 78, baseline: 80) == true)
        #expect(FeedReconcile.feedIsTrustworthy(currentCount: 5, baseline: 80) == false)
    }

    @Test func aSingleBadFetchDoesNotRatchetTheBaselineDown() {
        var state = FeedReconcile.FeedHealthState(baseline: 80, degradedStreak: 0, lastDegradedCount: 0)
        state = FeedReconcile.updatedHealth(state, currentCount: 4)
        #expect(state.baseline == 80)
        state = FeedReconcile.updatedHealth(state, currentCount: 79)
        #expect(state.baseline == 79)
        #expect(state.degradedStreak == 0)
    }

    @Test func aSustainedSmallerFeedReBaselinesAfterThreeScouts() {
        var state = FeedReconcile.FeedHealthState(baseline: 80, degradedStreak: 0, lastDegradedCount: 0)
        state = FeedReconcile.updatedHealth(state, currentCount: 38)
        #expect(state.baseline == 80)
        #expect(FeedReconcile.feedIsTrustworthy(currentCount: 38, baseline: state.baseline) == false)
        state = FeedReconcile.updatedHealth(state, currentCount: 37)
        #expect(state.baseline == 80)
        state = FeedReconcile.updatedHealth(state, currentCount: 39)
        #expect(state.baseline == 39)
        #expect(state.degradedStreak == 0)
        #expect(FeedReconcile.feedIsTrustworthy(currentCount: 38, baseline: state.baseline) == true)
    }

    @Test func anUnstableDegradedStreakNeverReBaselines() {
        var state = FeedReconcile.FeedHealthState(baseline: 80, degradedStreak: 0, lastDegradedCount: 0)
        state = FeedReconcile.updatedHealth(state, currentCount: 38)
        state = FeedReconcile.updatedHealth(state, currentCount: 4)
        #expect(state.degradedStreak == 1)
        state = FeedReconcile.updatedHealth(state, currentCount: 38)
        #expect(state.degradedStreak == 1)
        #expect(state.baseline == 80)
    }

    @Test func consecutiveEmptyFeedsNeverReBaselineToZero() {
        var state = FeedReconcile.FeedHealthState(baseline: 80, degradedStreak: 0, lastDegradedCount: 0)
        for _ in 0..<5 { state = FeedReconcile.updatedHealth(state, currentCount: 0) }
        #expect(state.baseline == 80)
    }

    // One source's big season must never re-baseline another source's feed. That merged singleton is
    // precisely what made the old design unable to tell a dead scraper from a quiet calendar.
    @Test func oneSourcesSeasonCannotReBaselineAnother() {
        let venue = FeedReconcile.FeedHealthState(baseline: 200, degradedStreak: 0, lastDegradedCount: 0)
        let presenter = FeedReconcile.FeedHealthState(baseline: 6, degradedStreak: 0, lastDegradedCount: 0)

        // The presenter's tiny but perfectly normal season is judged against the PRESENTER's baseline.
        #expect(FeedReconcile.feedIsTrustworthy(currentCount: 6, baseline: presenter.baseline) == true)
        // And against the venue's, it would have looked like a catastrophic outage.
        #expect(FeedReconcile.feedIsTrustworthy(currentCount: 6, baseline: venue.baseline) == false)
    }
}
