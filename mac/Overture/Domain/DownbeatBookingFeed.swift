import Foundation

// #2478: a Downbeat export that has lost every shoot at once, while still listing clients.
//
// On 2026-08-10 Downbeat refreshed this file carrying 30 clients, 4 venues, and no bookings at all, while
// Dan had fifteen shoots on the books (its exporter had started omitting every booking that was not in the
// committed state, danwright/downbeat#147, and both of its error paths swallowed the failure, #148).
// Overture read it as a true picture of the world, because every signal it checked said healthy: current
// timestamp, supported version, populated client list. Three features then silently did nothing at all:
// booking detection had nothing to match a pitched show against, the blocked calendar got no dates to keep
// clear of, and the planned booking prompt could never fire. An empty collection inside a fresh, well
// formed file is indistinguishable from a quiet week, which is why none of it was visible (L90).
//
// WHAT THIS ASSERTS, and why it cannot expire (L68). Not "the export has no bookings", which is a fact
// that will one day be legitimately true and would then cry wolf for as long as the lull lasted. What it
// asserts is a DISAPPEARANCE: every shoot this feed was carrying is gone in one step, and not one of them
// had happened yet. Shoots leave this export one at a time, as their dates pass, so the whole list going
// while its dates are still ahead cannot be produced by the calendar advancing. Both halves of the
// comparison age on their own: as those nights pass, the evidence stops being evidence, and once the last
// one has gone by, an empty export is a diary that has genuinely run out and Overture says nothing about
// it, however long that lasts. Nothing has to remember to switch the check off.
//
// TWO shoots, not one. A single shoot going is exactly what one cancellation in Downbeat looks like, and
// nothing in the export tells the two apart, so this declines to claim rather than guessing (L11). It is
// the LIST going at once that is the signature, and that is also the shape the real failure has: an
// exporter that drops a whole category takes every row in it.
//
// Separate from DownbeatBridge.Health (is the FILE there, decodable, recent) and from
// DownbeatFeedFreshness (has anything NEW arrived lately). Three independent questions with three
// verdicts, so a pass on one can never erase a failure on another (L53).
enum DownbeatBookingFeed {
    // The smallest list whose total loss is a signature rather than an ordinary cancellation.
    static let vanishedFloor = 2

    // What went, and how far ahead it ran. Carried so the message can state the evidence it measured
    // rather than asserting a conclusion Dan has to take on trust.
    struct Vanished: Equatable, Sendable {
        var bookingCount: Int
        var lastEndDate: String     // yyyy-MM-dd, the furthest night any of them ran to
    }

    // The verdict, from the facts one observation records. Every argument is a plain stored value, so the
    // masthead can read them straight out of @AppStorage and re-derive this on every render: the verdict
    // is never itself stored, which is what lets it retire itself the day `lastCarriedEndDate` passes.
    static func vanished(clientCount: Int, upcomingBookingCount: Int,
                         lastCarriedCount: Int, lastCarriedEndDate: String,
                         today: String) -> Vanished? {
        // A file that is missing, unreadable or empty reaches here with no clients either, and that has
        // its own message from DownbeatBridge.health. Reporting it again in different words would be one
        // fault arriving as two.
        guard clientCount > 0 else { return nil }
        guard upcomingBookingCount == 0 else { return nil }
        guard lastCarriedCount >= vanishedFloor else { return nil }
        // The half that makes this age out by itself: a night still to come cannot have left the export
        // by happening.
        guard lastCarriedEndDate >= today else { return nil }
        return Vanished(bookingCount: lastCarriedCount, lastEndDate: lastCarriedEndDate)
    }

    // The evidence to keep after seeing this export. Written ONLY from an export that carried shoots, so a
    // broken one cannot erase the record that convicts it (L5): overwriting on every observation would
    // mean the first empty file destroyed the only thing that could tell it apart from a quiet week.
    //
    // Shoots already past are not evidence: a file left carrying nothing but last year's work would
    // otherwise keep this armed on dates that cannot come back.
    static func carried(lastCarriedCount: Int, lastCarriedEndDate: String,
                        bookings: [OvertureBooking], today: String) -> (count: Int, endDate: String) {
        let upcoming = bookings.filter { $0.endDate >= today }
        guard let furthest = upcoming.map(\.endDate).max() else {
            return (lastCarriedCount, lastCarriedEndDate)
        }
        return (upcoming.count, furthest)
    }
}

// Persistence for the check, in UserDefaults beside DownbeatFeedFreshness's own tracking (it is not user
// data and not a cross-boundary hand-off). Each fact lives in its own key so the masthead can read them
// reactively with @AppStorage, and so this check's state can never be confused with the stall clock's.
enum DownbeatBookingFeedStore {
    static let clientCountKey = "downbeatFeedClientCount"
    static let upcomingBookingCountKey = "downbeatFeedUpcomingBookingCount"
    static let lastCarriedCountKey = "downbeatFeedLastCarriedCount"
    static let lastCarriedEndDateKey = "downbeatFeedLastCarriedEndDate"

    // Record one observation. The tick passes what it has already loaded; `observe` below reads the file
    // for a caller that has not. Both land here, so the two can never judge the same export differently.
    static func record(clientCount: Int, bookings: [OvertureBooking], today: String,
                       into defaults: UserDefaults = .standard) {
        let carried = DownbeatBookingFeed.carried(
            lastCarriedCount: defaults.integer(forKey: lastCarriedCountKey),
            lastCarriedEndDate: defaults.string(forKey: lastCarriedEndDateKey) ?? "",
            bookings: bookings, today: today)
        defaults.set(clientCount, forKey: clientCountKey)
        defaults.set(bookings.filter { $0.endDate >= today }.count, forKey: upcomingBookingCountKey)
        defaults.set(carried.count, forKey: lastCarriedCountKey)
        defaults.set(carried.endDate, forKey: lastCarriedEndDateKey)
    }

    // Read the export and record what it carried. A missing or unreadable file yields no clients, which
    // this check leaves to DownbeatBridge.health, and leaves the evidence untouched on the way past.
    static func observe(from url: URL = DownbeatBridge.defaultURL, now: Date,
                        into defaults: UserDefaults = .standard) {
        let loaded = DownbeatBridge.loadWithHealth(from: url, now: now)
        record(clientCount: loaded.clients.count, bookings: loaded.bookings,
               today: EasternDate.today(now), into: defaults)
    }

    static func vanished(today: String, defaults: UserDefaults = .standard) -> DownbeatBookingFeed.Vanished? {
        DownbeatBookingFeed.vanished(clientCount: defaults.integer(forKey: clientCountKey),
                                     upcomingBookingCount: defaults.integer(forKey: upcomingBookingCountKey),
                                     lastCarriedCount: defaults.integer(forKey: lastCarriedCountKey),
                                     lastCarriedEndDate: defaults.string(forKey: lastCarriedEndDateKey) ?? "",
                                     today: today)
    }
}
