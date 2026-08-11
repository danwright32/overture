import Foundation

// #2478: a Downbeat export that has lost every shoot at once, while still listing clients.
//
// On 2026-08-10 Downbeat refreshed this file carrying 30 clients, 4 venues, and no bookings at all, while
// Dan had fifteen shoots on the books (its exporter had started omitting every booking that was not in the
// committed state, danwright32/downbeat#147, and both of its error paths swallowed the failure, #148).
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

    // How long evidence that carries NO dates can still be leaned on. See `Evidence` below.
    static let undatedEvidenceLastsFor: TimeInterval = DownbeatFeedFreshness.stalledAfter

    // What went, and how far ahead it ran. Carried so the message can state the evidence it measured
    // rather than asserting a conclusion Dan has to take on trust.
    struct Vanished: Equatable, Sendable {
        var bookingCount: Int
        var evidence: Evidence

        // Two kinds of evidence, kept apart in the TYPE rather than by a convention, because they support
        // different claims and the message must not make the stronger one from the weaker (L11).
        enum Evidence: Equatable, Sendable {
            // The export itself carried these shoots, all at once, and this is the furthest night any of
            // them ran to. Dated, so it retires itself when that night passes.
            case theExportCarriedThemUntil(String)
            // Booking ids Overture had already seen before it began keeping their dates: how many came
            // through this feed, and when the last new one appeared. It cannot say which have already
            // happened, so it can only be leaned on for a bounded time after that last arrival.
            case seenBeforeTheirDatesWereKept(lastNewAt: Double)
        }
    }

    // The verdict, from the facts one observation records. Every argument is a plain stored value, so the
    // masthead can read them straight out of @AppStorage and re-derive this on every render: the verdict
    // is never itself stored, which is what lets it retire itself the day its evidence stops holding.
    static func vanished(clientCount: Int, upcomingBookingCount: Int,
                         lastCarriedCount: Int, lastCarriedEndDate: String, lastCarriedAt: Double,
                         today: String, now: Date) -> Vanished? {
        // A file that is missing, unreadable or empty reaches here with no clients either, and that has
        // its own message from DownbeatBridge.health. Reporting it again in different words would be one
        // fault arriving as two.
        guard clientCount > 0 else { return nil }
        guard upcomingBookingCount == 0 else { return nil }
        guard lastCarriedCount >= vanishedFloor else { return nil }

        // Each kind of evidence retires itself in the only currency it has.
        if lastCarriedEndDate.isEmpty {
            // Dateless: booking ids Overture had already seen before it began keeping their dates
            // (#1456's set, migrated once by DownbeatBookingFeedStore.bootstrapFromSeenIds). Nothing in
            // it can say which of those shoots have happened, so the dated guard below cannot be
            // evaluated at all and must not be faked. What the record DOES fix is an instant: a new
            // upcoming shoot arrived then, so as of then this feed was carrying at least one shoot that
            // had not happened yet. That is worth leaning on for a bounded time and no longer, which is
            // what keeps this from becoming a claim that can never expire.
            guard lastCarriedAt > 0 else { return nil }
            guard now.timeIntervalSince1970 - lastCarriedAt <= undatedEvidenceLastsFor else { return nil }
            return Vanished(bookingCount: lastCarriedCount,
                            evidence: .seenBeforeTheirDatesWereKept(lastNewAt: lastCarriedAt))
        }
        // The half that makes this age out by itself: a night still to come cannot have left the export
        // by happening.
        guard lastCarriedEndDate >= today else { return nil }
        return Vanished(bookingCount: lastCarriedCount,
                        evidence: .theExportCarriedThemUntil(lastCarriedEndDate))
    }

    // What this export is worth as evidence: how many shoots it carried that have not happened yet, and
    // the furthest night among them. Nil when it carries none, which means KEEP whatever is already on
    // file rather than overwrite it, so a broken export cannot erase the record that convicts it (L5).
    //
    // Shoots already past are not evidence either: a file left carrying nothing but last year's work
    // would otherwise keep this armed on dates that cannot come back.
    static func carried(bookings: [OvertureBooking], today: String) -> (count: Int, endDate: String)? {
        let upcoming = bookings.filter { $0.endDate >= today }
        guard let furthest = upcoming.map(\.endDate).max() else { return nil }
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
    static let lastCarriedAtKey = "downbeatFeedLastCarriedAt"

    // Arm the check from what the app already remembers, ONCE.
    //
    // These keys are new, so on the one Mac this check was written for they read empty, and the export
    // there had already stopped carrying bookings: the check would have stayed silent until a good export
    // arrived, which is precisely when nobody needs it. What Overture does already hold is #1456's
    // seen-booking-id set (17 ids on Dan's live release domain) and the instant a new upcoming booking
    // last appeared in it.
    //
    // A ONE-WAY migration, not a second source of truth (L83). It writes only into a store with no
    // history of its own, and the first export that actually carries shoots overwrites all three keys
    // with dated evidence, so the two can never sit side by side disagreeing: the export always wins.
    //
    // The end date is written EMPTY on purpose. It is the one honest value: those ids carry no dates, and
    // an invented one would let the dated wording claim something no evidence supports (L48, L11).
    static func bootstrapFromSeenIds(into defaults: UserDefaults = .standard) {
        // Real history wins, so this can only ever fill a vacuum.
        guard defaults.integer(forKey: lastCarriedCountKey) == 0 else { return }
        // Somebody else's value at that key is not evidence. Read defensively and treat it as absent.
        guard let ids = defaults.array(forKey: DownbeatFeedFreshnessStore.seenIdsKey) as? [String]
        else { return }
        let distinct = Set(ids).count
        // Below the floor for the same reason one vanished shoot is: it cannot be told apart from a
        // single cancellation, so nothing is migrated rather than migrating what the verdict would refuse.
        guard distinct >= DownbeatBookingFeed.vanishedFloor else { return }
        // Without the instant there is no bound on the claim, and an unbounded claim from dateless
        // evidence is exactly what this must not become.
        let lastNewAt = defaults.double(forKey: DownbeatFeedFreshnessStore.lastNewAtKey)
        guard lastNewAt > 0 else { return }

        defaults.set(distinct, forKey: lastCarriedCountKey)
        defaults.set("", forKey: lastCarriedEndDateKey)
        defaults.set(lastNewAt, forKey: lastCarriedAtKey)
    }

    // Record one observation. The tick passes what it has already loaded; `observe` below reads the file
    // for a caller that has not. Both land here, so the two can never judge the same export differently.
    static func record(clientCount: Int, bookings: [OvertureBooking], today: String, now: Date,
                       into defaults: UserDefaults = .standard) {
        bootstrapFromSeenIds(into: defaults)
        defaults.set(clientCount, forKey: clientCountKey)
        defaults.set(bookings.filter { $0.endDate >= today }.count, forKey: upcomingBookingCountKey)
        guard let carried = DownbeatBookingFeed.carried(bookings: bookings, today: today) else { return }
        defaults.set(carried.count, forKey: lastCarriedCountKey)
        defaults.set(carried.endDate, forKey: lastCarriedEndDateKey)
        defaults.set(now.timeIntervalSince1970, forKey: lastCarriedAtKey)
    }

    // Read the export and record what it carried. A missing or unreadable file yields no clients, which
    // this check leaves to DownbeatBridge.health, and leaves the evidence untouched on the way past.
    static func observe(from url: URL = DownbeatBridge.defaultURL, now: Date,
                        into defaults: UserDefaults = .standard) {
        let loaded = DownbeatBridge.loadWithHealth(from: url, now: now)
        record(clientCount: loaded.clients.count, bookings: loaded.bookings,
               today: EasternDate.today(now), now: now, into: defaults)
    }

    static func vanished(today: String, now: Date,
                         defaults: UserDefaults = .standard) -> DownbeatBookingFeed.Vanished? {
        DownbeatBookingFeed.vanished(clientCount: defaults.integer(forKey: clientCountKey),
                                     upcomingBookingCount: defaults.integer(forKey: upcomingBookingCountKey),
                                     lastCarriedCount: defaults.integer(forKey: lastCarriedCountKey),
                                     lastCarriedEndDate: defaults.string(forKey: lastCarriedEndDateKey) ?? "",
                                     lastCarriedAt: defaults.double(forKey: lastCarriedAtKey),
                                     today: today, now: now)
    }
}
