import Testing
import Foundation

// #1456: catching a Downbeat hand-off that still runs daily but has gone dry (the same upcoming shoots for
// weeks). The existing checks ask about the FILE (health) or a single boolean (any upcoming shoot at all);
// this asks whether the feed is still MOVING. A booking id never seen before, dated today or later, is
// genuine new activity and resets the clock; when nothing new has appeared in the window, the feed is
// stalled. All pure, so the clock logic is tested without a live export.
@Suite("Downbeat feed freshness (#1456)")
struct DownbeatFeedFreshnessTests {
    private let epoch = Date(timeIntervalSince1970: 1_000_000)
    private func later(_ days: Double, than d: Date) -> Date { d.addingTimeInterval(days * 86_400) }

    // The first time Overture ever sees the feed, whatever is upcoming right now is the baseline: the clock
    // starts, so a booking that has sat there since before tracking began doesn't read as "stale forever".
    @Test func theFirstObservationSeedsTheClock() {
        let s = DownbeatFeedFreshness.observe(.init(), upcomingBookingIds: ["a", "b"], now: epoch)
        #expect(s.lastNewUpcomingBookingAt == epoch.timeIntervalSince1970)
        #expect(!DownbeatFeedFreshness.isStalled(s, now: epoch))
    }

    // The same shoots seen again do NOT advance the clock: that is exactly the dry-pipe case this catches.
    @Test func seeingTheSameBookingsAgainDoesNotAdvanceTheClock() {
        let first = DownbeatFeedFreshness.observe(.init(), upcomingBookingIds: ["a"], now: epoch)
        let again = DownbeatFeedFreshness.observe(first, upcomingBookingIds: ["a"], now: later(10, than: epoch))
        #expect(again.lastNewUpcomingBookingAt == epoch.timeIntervalSince1970)   // unchanged
    }

    // A booking id never seen before is new activity: the clock resets to when it appeared.
    @Test func aGenuinelyNewBookingResetsTheClock() {
        let first = DownbeatFeedFreshness.observe(.init(), upcomingBookingIds: ["a"], now: epoch)
        let t = later(10, than: epoch)
        let next = DownbeatFeedFreshness.observe(first, upcomingBookingIds: ["a", "b"], now: t)
        #expect(next.lastNewUpcomingBookingAt == t.timeIntervalSince1970)
        #expect(next.seenBookingIds.sorted() == ["a", "b"])
    }

    // The whole point: no new booking for longer than the window means the feed is stalled.
    @Test func aFeedThatHasNotAdvancedInTheWindowIsStalled() {
        let s = DownbeatFeedFreshness.observe(.init(), upcomingBookingIds: ["a"], now: epoch)
        #expect(!DownbeatFeedFreshness.isStalled(s, now: later(27, than: epoch)))   // still inside 4 weeks
        #expect(DownbeatFeedFreshness.isStalled(s, now: later(29, than: epoch)))    // past 4 weeks
    }

    // A new booking appearing right before the deadline pushes the stall back out: the feed moved.
    @Test func aNewBookingClearsAnApproachingStall() {
        let first = DownbeatFeedFreshness.observe(.init(), upcomingBookingIds: ["a"], now: epoch)
        let refreshed = DownbeatFeedFreshness.observe(first, upcomingBookingIds: ["a", "b"], now: later(20, than: epoch))
        #expect(!DownbeatFeedFreshness.isStalled(refreshed, now: later(40, than: epoch)))   // 20 days since new
        #expect(DownbeatFeedFreshness.isStalled(refreshed, now: later(50, than: epoch)))    // now 30 days since
    }

    // No upcoming bookings at all leaves NO baseline, so this never reports stalled: that state is the
    // existing "no upcoming shoots" mark's job, not this one's.
    @Test func noUpcomingBookingsIsNotAStall() {
        let s = DownbeatFeedFreshness.observe(.init(), upcomingBookingIds: [], now: epoch)
        #expect(s.lastNewUpcomingBookingAt == 0)
        #expect(!DownbeatFeedFreshness.isStalled(s, now: later(100, than: epoch)))
    }

    // MARK: - The store

    private func scratch() -> UserDefaults { UserDefaults(suiteName: "feed-freshness-\(UUID().uuidString)")! }
    private func booking(_ id: String, endDate: String) -> OvertureBooking {
        OvertureBooking(id: id, clientId: "c", clientDisplayName: "C", shootName: "S",
                        startDate: endDate, endDate: endDate, venueId: nil, venueName: "V")
    }

    // A shoot counts as upcoming until its END date passes, matching BlockedCalendar. A past-dated booking
    // never seeds the clock, so it can never make the feed look "fresh" on its own.
    @Test func theStoreRecordsOnlyUpcomingBookingsAndReadsBackStalled() {
        let defaults = scratch()
        let today = "2026-11-01"
        // A past shoot and an upcoming one: only the upcoming one seeds the clock.
        DownbeatFeedFreshnessStore.record(bookings: [booking("past", endDate: "2026-10-01"),
                                                     booking("up", endDate: "2026-11-20")],
                                          today: today, now: epoch, into: defaults)
        #expect(!DownbeatFeedFreshnessStore.isStalled(now: later(20, than: epoch), defaults: defaults))
        #expect(DownbeatFeedFreshnessStore.isStalled(now: later(30, than: epoch), defaults: defaults))
    }

    @Test func aRecordWithNoUpcomingBookingLeavesNoBaseline() {
        let defaults = scratch()
        DownbeatFeedFreshnessStore.record(bookings: [booking("past", endDate: "2026-10-01")],
                                          today: "2026-11-01", now: epoch, into: defaults)
        #expect(!DownbeatFeedFreshnessStore.isStalled(now: later(100, than: epoch), defaults: defaults))
    }
}

// The wire the pure logic cannot see: the reconcile tick must actually CALL the observer, or the clock
// never advances and the mark never lights. Guarded at the source (a guard and its wiring are two claims).
@Suite("The reconcile tick observes Downbeat feed freshness (#1456)")
struct FeedFreshnessWiringGuardTests {
    @Test func theSafeReconcileTickObservesTheFeed() {
        let sched = SourceGuardHelper.source("Overture/App/ReconcileScheduler.swift")
        // #2091: scoped to the function's balanced-brace BODY, not the first 1200 characters after its
        // name. That window was a proxy for "inside this function" and it expired the way a proxy does:
        // #2091 added a call plus its comment at the top of the tick, which pushed the guarded call past
        // the character count while the wiring it protects was untouched, so the guard failed for a
        // reason unrelated to what it asserts (L63). The body is the quantity it actually means, and it
        // now also covers the REST of the function, which the count never did.
        guard let body = SourceGuardHelper.bodyOfFunction(named: "runSafeReconcilesOnce", in: sched) else {
            Issue.record("runSafeReconcilesOnce not found"); return
        }
        #expect(body.contains("observeFeedFreshness(now: now)"),
                "the safe reconcile tick must advance the feed-freshness clock each tick")
    }

    // The Days off SHEET surfaces the stalled-feed nudge (its reassuring long-form sentence and its own
    // 'Hide this for a week' button), gated on the FACT the feed is stalled, never the snooze. Guarded at
    // the source because DaysOffView reads Dan's live export for its calendar and needs a SwiftData context
    // and environment to render, so it cannot be built in isolation (the #863 lesson). The DECISION behind
    // it (isStalled, reason precedence, the wording) is proven behaviourally above and in DaysOffAttentionTests.
    @Test func theDaysOffSheetShowsTheStalledFeedNudge() {
        let sheet = SourceGuardHelper.source("Overture/UI/DaysOffView.swift")
        #expect(sheet.contains("DownbeatFeedFreshness.isStalled(lastNewAt: feedLastNewAt, now: Date())"),
                "the sheet must gate the stalled notice on the fact the feed is stalled")
        #expect(sheet.contains("DaysOffAttention.feedStalledExplanation"),
                "the sheet must show the reassuring stalled-feed sentence")
        #expect(sheet.contains("DaysOffAttention.needsALook(calendar, feedStalled: true)"),
                "the sheet must offer the snooze for the stalled case too")
    }
}
