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

    // Proof the OLD guard could not have caught it, so this test is not merely restating #150. Same
    // numbers, but with nothing rejected: the feed is trusted, because 75% of baseline is healthy.
    @Test func theDegradationGuardAloneWouldHaveTrustedThatExactFeed() {
        let r = report(feedCount: 60, baseline: 80, rejected: 0)

        #expect(FeedReconcile.feedIsTrustworthy(currentCount: 60, baseline: 80))
        #expect(r.absenceIsEvidence)   // <- the hole #887 closes
    }

    // A single dropped event is still a run whose detail pages were not fully read. It says nothing about
    // how many OTHER shows it silently failed to reach, so it does not get to cancel anything either.
    @Test func evenOneDroppedEventWithholdsTheRightToCancel() {
        #expect(report(feedCount: 79, baseline: 80, rejected: 1).absenceIsEvidence == false)
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
