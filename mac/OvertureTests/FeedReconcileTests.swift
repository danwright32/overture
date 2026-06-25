import Testing
import Foundation
import SwiftData
@testable import Overture

@MainActor
@Suite("Feed reconcile (disappeared prospects, #133)")
struct FeedReconcileTests {
    private func prospect(key: String, date: String?, source: String?,
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
        return p
    }

    private let carnegie = "https://www.carnegiehall.org/Calendar/2026/08/01/x"
    private let today = "2026-06-25"

    @Test func futureCarnegieProspectAbsentFromFeedGetsAMiss() {
        let p = prospect(key: "gone", date: "2026-08-01", source: carnegie)
        FeedReconcile.reconcile(stored: [p], seenKeys: [], today: today)
        #expect(p.missedScoutCount == 1)
        #expect(p.disappearedFromFeed == false)   // one miss isn't gone yet
    }

    @Test func twoConsecutiveMissesMarkItGone() {
        let p = prospect(key: "gone", date: "2026-08-01", source: carnegie, missed: 1)
        FeedReconcile.reconcile(stored: [p], seenKeys: [], today: today)
        #expect(p.missedScoutCount == 2)
        #expect(p.disappearedFromFeed == true)
    }

    @Test func reappearingInTheFeedResetsTheCounter() {
        let p = prospect(key: "back", date: "2026-08-01", source: carnegie, missed: 2)
        FeedReconcile.reconcile(stored: [p], seenKeys: ["back"], today: today)
        #expect(p.missedScoutCount == 0)
        #expect(p.disappearedFromFeed == false)
    }

    @Test func pastPerformanceIsNeverFlaggedGone() {
        // It happened; absence from a forward-looking feed is expected, not a cancellation.
        let p = prospect(key: "past", date: "2026-06-01", source: carnegie, missed: 1)
        FeedReconcile.reconcile(stored: [p], seenKeys: [], today: today)
        #expect(p.missedScoutCount == 1)   // untouched, never incremented past the threshold
    }

    @Test func aRunStillRunningTodayCountsAsFuture() {
        // Opening night passed but the run end date is still ahead — still a live show.
        let p = prospect(key: "run", date: "2026-06-20", source: carnegie, runEnd: "2026-07-10")
        FeedReconcile.reconcile(stored: [p], seenKeys: [], today: today)
        #expect(p.missedScoutCount == 1)
    }

    @Test func queueItemCarriesTheDisappearedFlag() {
        // The queue reads disappearedFromFeed off the QueueItem, so the Prospect->QueueItem
        // mapping must carry it through (drives the hide/strike-through behavior).
        let p = prospect(key: "gone", date: "2026-08-01", source: carnegie, missed: 2)
        #expect(p.disappearedFromFeed == true)
        #expect(QueueItem(p).disappearedFromFeed == true)
    }

    @Test func prospectFromAnotherSourceIsNotReconciled() {
        // A Carnegie scout must not flag a future prospect that came from a different venue.
        let p = prospect(key: "other", date: "2026-08-01", source: "https://example.com/show")
        FeedReconcile.reconcile(stored: [p], seenKeys: [], today: today)
        #expect(p.missedScoutCount == 0)
    }
}
