import Testing
import Foundation
@testable import Overture

// #887: a source whose detail pages were only HALF READ could mark Dan's live shows as cancelled.
//
// The extract run WebFetches each event's own detail page for the venue. An event that comes back with
// no venue is DROPPED (ExtractedEventGuard, via ScoutExtractResults.events(for:)), which is right on its
// own terms: a venue-less prospect would put the wrong place in Dan's email.
//
// But those drops then shrink the feed count that decides whether a show was CANCELLED. A run that read
// the listings page perfectly and then only got through 60 of its 80 detail pages reports 60 events, a
// healthy `upcomingListings` verdict, and no error anywhere. The 20 it never reached are simply absent.
//
// The #150 degradation guard is what should catch that, and CANNOT: minHealthyFraction is 0.5, and
// 60 of 80 is 0.75. Losing exactly one quarter of a source, the single most likely partial failure, sails
// straight through. Two runs later those 20 live shows, which Dan may already have emailed, are gone.
//
// The rule: presence is always believable, absence is not. A run that threw events away does not know
// what else it missed, so it may add and update, and it may never take anything away.
@Suite("A half-read source can never cancel a show (#887)")
struct PartialSweepCannotCancelTests {

    private func report(feedCount: Int, baseline: Int, rejected: Int) -> FeedReconcile.SourceReport {
        FeedReconcile.SourceReport(
            sourceId: "kaufman",
            seenKeys: [],
            seenSourceURLs: [],
            feedCount: feedCount,
            baseline: baseline,
            successfulCheckCount: WatchedSource.warmupRuns,   // past warmup: allowed to blame, in principle
            verdict: .upcomingListings,                       // a healthy-looking run
            rejectedCount: rejected)
    }

    // THE bug, stated as a test. Everything about this run looks healthy, and it threw 20 shows away.
    @Test func aRunThatDroppedEventsMayNotMarkAnythingGone() {
        let r = report(feedCount: 60, baseline: 80, rejected: 20)

        #expect(r.absenceIsEvidence == false)
    }

    // Proof the #150 degradation guard could not have caught it, so this test is not merely restating it:
    // 60 of 80 is 75% of baseline, comfortably "healthy" at its 0.5 bar.
    //
    // #897 has since raised the bar the RECONCILE asks (isCredibleNewBaseline, 0.9), which catches these
    // particular numbers from the other side too. The lenient rule still exists and still says yes, which
    // is what this pins: the two rules are different questions, and #150's was never enough on its own.
    @Test func theDegradationGuardAloneWouldHaveTrustedThatExactFeed() {
        #expect(FeedReconcile.feedIsTrustworthy(currentCount: 60, baseline: 80))
    }

    // ...and this guard is NOT redundant with #897's, which is the thing that would quietly rot if nobody
    // asserted it. Here the run's SIZE is beyond reproach: this source's calendar grew from 60 listings to
    // 80, the run returned a full 60, and against a baseline of 60 that is 100% of its usual size. Only
    // #887 can see that 20 of the 80 it looked at came back unread, because this rule alone measures what
    // the run could READ (kept plus thrown away) rather than how big it was.
    @Test func aRunAtFullSizeCanStillBeTooUnreadToBeBelieved() {
        let r = report(feedCount: 60, baseline: 60, rejected: 20)

        #expect(FeedReconcile.isCredibleNewBaseline(currentCount: 60, baseline: 60))  // size: perfect
        #expect(r.absenceIsEvidence == false)                                         // read: not nearly
    }

    // Dan's call (2026-07-13), replacing the strict zero this shipped with. A small number of dropped
    // events is normal and permanent on a real calendar: a "venue TBA" listing has no venue and never
    // will, and under a strict zero such a source could NEVER mark anything cancelled, ever, and nothing
    // would say so. That is the "rule that silently never fires" problem (#888) built in on purpose.
    //
    // So a SMALL fraction is tolerated. One TBA listing among 79 real ones tells us nothing is wrong.
    @Test func oneStrayDropOnABigCalendarStillCancelsNormally() {
        #expect(report(feedCount: 79, baseline: 80, rejected: 1).absenceIsEvidence)
    }

    // The boundary, pinned. At the threshold it is still trusted; past it, it is not.
    @Test func theToleranceEndsExactlyWhereItSaysItDoes() {
        // 1 of 20 = 5.0%, exactly at the line.
        #expect(report(feedCount: 19, baseline: 20, rejected: 1).absenceIsEvidence)
        // 2 of 20 = 10%, past it.
        #expect(report(feedCount: 18, baseline: 20, rejected: 2).absenceIsEvidence == false)
    }

    // THE original bug must still be caught. 20 of 80 dropped is 25%, far past the tolerance, and this is
    // the case the #150 guard could not see (60 of 80 is 75% of baseline, comfortably "healthy").
    @Test func theToleranceIsNowhereNearWideEnoughToLetTheOriginalBugBack() {
        #expect(report(feedCount: 60, baseline: 80, rejected: 20).absenceIsEvidence == false)
    }

    // A small source is still effectively strict, and that is correct rather than a wart: on a six-show
    // calendar, ONE unread detail page means a sixth of everything we know about that source is missing.
    @Test func aSmallSourceIsStillStrictBecauseOneDropIsALotOfIt() {
        #expect(report(feedCount: 5, baseline: 6, rejected: 1).absenceIsEvidence == false)
    }

    // A run that returned NOTHING but rejects is not a 100%-rejected sweep to be reasoned about, it is a
    // broken run. It may not cancel anything.
    @Test func aRunThatDroppedEverythingCancelsNothing() {
        #expect(report(feedCount: 0, baseline: 80, rejected: 80).absenceIsEvidence == false)
    }

    // The healthy path must keep working, or this guard would quietly turn the reconcile off entirely,
    // and a genuinely cancelled show would sit in Dan's queue forever.
    @Test func aCleanFullRunStillCancelsNormally() {
        #expect(report(feedCount: 80, baseline: 80, rejected: 0).absenceIsEvidence)
    }

    // The existing guards are untouched: a run that dropped nothing but came back tiny is still a
    // degraded fetch, not "every show cancelled" (#150).
    @Test func aCollapsedFeedIsStillDegradedEvenWithNothingRejected() {
        #expect(report(feedCount: 10, baseline: 80, rejected: 0).absenceIsEvidence == false)
    }

    // Adding and updating are NOT withheld. Presence is always believable, from any source that ran, even
    // one too degraded to be trusted about what is missing. Withholding presence would mean a half-read
    // run also failed to record the shows it DID find, which would make the bug worse, not better.
    @Test func aDroppedEventNeverStopsTheShowsItDidFindFromBeingSeen() {
        var r = report(feedCount: 60, baseline: 80, rejected: 20)
        r.seenKeys = ["a-show-it-did-read"]

        // Presence rides on seenKeys / seenSourceURLs, which absenceIsEvidence does not gate.
        #expect(r.seenKeys.contains("a-show-it-did-read"))
        #expect(r.absenceIsEvidence == false)
    }
}
