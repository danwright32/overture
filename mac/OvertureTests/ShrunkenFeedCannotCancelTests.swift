import Testing
import Foundation

// #897: a run that came back far SMALLER than its source normally does could still cancel every show it
// failed to return.
//
// #910 fixed half of this. It stopped a shrunken run being accepted, there and then, as the source's new
// size (isCredibleNewBaseline, 0.9), so a 30 show calendar read as 16 no longer becomes a 16 show source
// in one run and an 8 show source in the next.
//
// The other half stayed open, and it is the half that reaches Dan's queue. absenceIsEvidence asked
// feedIsTrustworthy, whose bar is 0.5, so the app held two contradictory beliefs about one single run: "I
// do not believe this is really how big this source is" and, in the same breath, "I believe every show
// missing from it was cancelled". With real Kaufman numbers, a run returning 16 of 30 cleared every gate,
// and two runs later 14 live October concerts were struck through and filtered out of the queue, with no
// error anywhere. It needs no pagination to fire: any half loaded page does it.
//
// The rule, now asked with ONE bar instead of two: a run may only take a show away if its size is credible
// as what this source currently is. A feed we do not believe cannot be evidence of what is missing from it.
@Suite("A shrunken feed can never cancel a show (#897)")
struct ShrunkenFeedCannotCancelTests {

    private func report(feedCount: Int, baseline: Int) -> FeedReconcile.SourceReport {
        FeedReconcile.SourceReport(
            sourceId: "kaufman",
            seenKeys: [],
            seenSourceURLs: [],
            feedCount: feedCount,
            baseline: baseline,
            successfulCheckCount: WatchedSource.warmupRuns,   // past warmup: allowed to blame, in principle
            verdict: .upcomingListings,                       // a healthy looking run
            rejectedCount: 0)                                 // and nothing rejected, so #887 cannot catch it
    }

    // THE bug, stated as a test. Kaufman's real numbers: 30 shows across four months, a run that misses
    // October and returns 16. Nothing failed and nothing was rejected, so every other guard is satisfied.
    @Test func theRunThatWouldHaveCancelledFourteenLiveShowsCannotCancelAnything() {
        #expect(report(feedCount: 16, baseline: 30).absenceIsEvidence == false)
    }

    // Proof this is a real hole and not a restatement of #150: the old bar SAID YES to that exact feed.
    // Both rules still exist and still mean different things, they are simply no longer asked the same
    // question. "Is this feed obviously broken" stays lenient; "may this feed take a show away" is strict.
    @Test func theOldFiftyPercentBarWouldHaveTrustedThatExactFeed() {
        #expect(FeedReconcile.feedIsTrustworthy(currentCount: 16, baseline: 30))
        #expect(FeedReconcile.isCredibleNewBaseline(currentCount: 16, baseline: 30) == false)
    }

    // The guard and its WIRING are two separate claims, and only this one is about Dan's queue. Cutting
    // the wire between absenceIsEvidence and the reconcile has left a full suite green here before (#887),
    // so the rule is also asserted where it actually bites: a live show, owned by that source, sitting in
    // the queue, must not accrue a miss on a run that came back half size.
    @Test func aLiveShowOwnedByAShrunkenSourceNeverAccruesAMiss() {
        let p = prospect(key: "oct-concert", sourceIds: ["kaufman"])

        FeedReconcile.reconcile(stored: [p], reports: [report(feedCount: 16, baseline: 30)], today: "2026-07-14")

        #expect(p.missedScoutCount == 0)
    }

    // The whole point of the reconcile must keep working. A calendar at its normal size that has genuinely
    // dropped one show still cancels it, in the same two runs as before.
    @Test func aNormalSizedRunStillCancelsAShowThatIsGenuinelyGone() {
        let p = prospect(key: "cancelled-concert", sourceIds: ["kaufman"])
        let healthy = report(feedCount: 29, baseline: 30)

        FeedReconcile.reconcile(stored: [p], reports: [healthy], today: "2026-07-14")
        FeedReconcile.reconcile(stored: [p], reports: [healthy], today: "2026-07-14")

        #expect(p.missedScoutCount == FeedReconcile.goneThreshold)
        #expect(p.disappearedFromFeed)
    }

    // A grown feed is never suspicious. Only shrinking is.
    @Test func aBiggerFeedThanUsualIsAlwaysCredible() {
        #expect(report(feedCount: 40, baseline: 30).absenceIsEvidence)
    }

    // The boundary, pinned, so the bar cannot drift without a test saying so.
    @Test func theBarSitsExactlyWhereItSaysItDoes() {
        #expect(report(feedCount: 27, baseline: 30).absenceIsEvidence)          // 90%, exactly at the line
        #expect(report(feedCount: 26, baseline: 30).absenceIsEvidence == false) // just under it
    }

    // Dan's call (2026-07-14). On a six show calendar ONE genuine cancellation is a 17% drop, which is
    // indistinguishable from a page that half loaded, so Overture waits rather than guessing. The cost is
    // that a dead show sits in the queue for a few more reads; the Sources sheet says why while it waits.
    @Test func aSmallCalendarWaitsRatherThanGuessing() {
        #expect(report(feedCount: 5, baseline: 6).absenceIsEvidence == false)
    }

    // ...and the wait is the ONLY cost, because the block is temporary. A guard that fails closed forever
    // is still a bug (#887, #888): a permanent invisible safety block looks exactly like a working one.
    //
    // The self heal machinery is the escape hatch, and this proves it is actually reachable from behind the
    // stricter bar. A calendar that genuinely shrank to five shows and STAYS there is believed after
    // selfHealThreshold reads, its smaller size becomes the new baseline, and it can mark shows gone again.
    @Test func aGenuineShrinkThatHoldsGetsItsCancellingBack() {
        var health = FeedReconcile.FeedHealthState(baseline: 6, degradedStreak: 0, lastDegradedCount: 0)

        // Every read while the smaller size is still in doubt: cancellation is off.
        for _ in 0..<(FeedReconcile.selfHealThreshold - 1) {
            #expect(report(feedCount: 5, baseline: health.baseline).absenceIsEvidence == false)
            health = FeedReconcile.updatedHealth(health, currentCount: 5)
        }
        health = FeedReconcile.updatedHealth(health, currentCount: 5)

        // The smaller calendar is now believed, and the source is trusted about absences again.
        #expect(health.baseline == 5)
        #expect(report(feedCount: 5, baseline: health.baseline).absenceIsEvidence)
    }

    // Presence is never withheld. A shrunken run may not take a show away, but the shows it DID list are
    // still proof those shows are alive: a miss already on the counter is reset by any source that ran.
    // Withholding that would make a half read run also forget the shows it found, which is worse.
    @Test func aShrunkenRunCanStillProveAShowIsAlive() {
        let p = prospect(key: "still-listed", sourceIds: ["kaufman"], missed: 1)
        var shrunken = report(feedCount: 16, baseline: 30)
        shrunken.seenKeys = ["still-listed"]

        FeedReconcile.reconcile(stored: [p], reports: [shrunken], today: "2026-07-14")

        #expect(p.missedScoutCount == 0)
    }

    private func prospect(key: String, sourceIds: [String], missed: Int = 0) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "Kaufman Music Center",
                         performanceDate: "2026-10-14", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: .new)
        p.missedScoutCount = missed
        p.sourceIds = sourceIds
        return p
    }
}
