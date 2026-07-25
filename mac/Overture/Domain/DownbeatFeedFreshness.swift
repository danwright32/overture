import Foundation

// #1456: catching a Downbeat hand-off that is still running but has gone dry. `DownbeatExport.health` asks
// whether the export FILE exists, decodes, and is recent; `DaysOffAttention` asks whether there is ANY
// upcoming shoot. Neither catches the case Dan raised (2026-07-24): the file is refreshed daily and holds
// the SAME upcoming shoots it held weeks ago, so every signal reads normal while Overture's picture of his
// schedule has quietly stopped advancing.
//
// This tracks whether the feed is still MOVING: a booking id never seen before, dated today or later, is
// genuine new activity and resets a clock. When nothing new has appeared for a long while (28 days, #1456),
// the feed is stalled and the Days off mark says so. A soft nudge, not an alarm: it cannot tell a broken
// export from a genuinely quiet booking spell (both look like "fresh file, same bookings"), so it means
// "worth checking Downbeat is still feeding new shoots", which is exactly what Dan asked for.
enum DownbeatFeedFreshness {
    // The dry-spell window. Dan's call (2026-07-24), against his own sparse booking cadence.
    static let stalledAfter: TimeInterval = 28 * 86_400   // 4 weeks

    struct State: Codable, Equatable, Sendable {
        var seenBookingIds: [String] = []
        // timeIntervalSince1970 of when a genuinely new upcoming booking last appeared; 0 means no baseline
        // yet (the feed has never carried an upcoming booking while Overture was watching).
        var lastNewUpcomingBookingAt: Double = 0
    }

    // Fold the upcoming bookings seen right now into the tracking state. Any id not seen before is new
    // activity and resets the clock to `now` (which, on the very first observation, seeds the baseline from
    // whatever is already upcoming, so an old booking never reads as "stale forever").
    static func observe(_ state: State, upcomingBookingIds: [String], now: Date) -> State {
        var next = state
        let seen = Set(state.seenBookingIds)
        if upcomingBookingIds.contains(where: { !seen.contains($0) }) {
            next.lastNewUpcomingBookingAt = now.timeIntervalSince1970
        }
        next.seenBookingIds = Array(seen.union(upcomingBookingIds)).sorted()
        return next
    }

    // Has the feed gone dry: a baseline exists and no new upcoming booking has appeared within the window.
    // No baseline (never carried an upcoming booking) is NOT a stall; that is the existing "no upcoming
    // shoots" mark's concern, not this one's.
    static func isStalled(_ state: State, now: Date, stalledAfter: TimeInterval = stalledAfter) -> Bool {
        isStalled(lastNewAt: state.lastNewUpcomingBookingAt, now: now, stalledAfter: stalledAfter)
    }

    // The same verdict from just the timestamp, so a view can read it reactively from one @AppStorage Double
    // (the last-new key) without decoding the whole state.
    static func isStalled(lastNewAt: Double, now: Date, stalledAfter: TimeInterval = stalledAfter) -> Bool {
        guard lastNewAt > 0 else { return false }
        return now.timeIntervalSince1970 - lastNewAt > stalledAfter
    }
}

// Persistence for the tracker, in UserDefaults like DaysOffAttention's own snooze (it is not user data and
// not a cross-boundary hand-off, so it needs no JSON file or store table). The last-new timestamp lives in
// its own key so RootView can read it reactively with @AppStorage; the seen-id set is only the observer's.
enum DownbeatFeedFreshnessStore {
    static let lastNewAtKey = "downbeatFeedLastNewUpcomingBookingAt"
    static let seenIdsKey = "downbeatFeedSeenBookingIds"

    static func load(_ defaults: UserDefaults = .standard) -> DownbeatFeedFreshness.State {
        DownbeatFeedFreshness.State(
            seenBookingIds: (defaults.array(forKey: seenIdsKey) as? [String]) ?? [],
            lastNewUpcomingBookingAt: defaults.double(forKey: lastNewAtKey))
    }

    static func save(_ state: DownbeatFeedFreshness.State, into defaults: UserDefaults = .standard) {
        defaults.set(state.lastNewUpcomingBookingAt, forKey: lastNewAtKey)
        defaults.set(state.seenBookingIds, forKey: seenIdsKey)
    }

    // Observe the export's currently-upcoming bookings and persist. Called on the reconcile tick, so the
    // feed is watched daily whether or not Dan runs a scout. A shoot counts as upcoming until its END date
    // passes, matching BlockedCalendar's "today or later" notion.
    static func record(bookings: [OvertureBooking], today: String, now: Date,
                       into defaults: UserDefaults = .standard) {
        let upcoming = bookings.filter { $0.endDate >= today }.map(\.id)
        save(DownbeatFeedFreshness.observe(load(defaults), upcomingBookingIds: upcoming, now: now), into: defaults)
    }

    static func isStalled(now: Date, defaults: UserDefaults = .standard) -> Bool {
        DownbeatFeedFreshness.isStalled(load(defaults), now: now)
    }
}
