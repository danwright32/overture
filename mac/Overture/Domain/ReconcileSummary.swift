import Foundation

// #285 (no silent no-op): what one reconcile pass changed, so a MANUAL "Run reconcile now" can
// acknowledge itself even when nothing was due. The automatic timer/watcher passes ignore this (they
// would otherwise notify every tick); only the on-demand menu action surfaces the message.
struct ReconcileSummary: Equatable, Sendable {
    var omniFocusChanged: Int
    // #269: names of leads that became replied / booked THIS tick, for the while-away notification.
    var newReplies: [String] = []
    var newBookings: [String] = []
    // #301: the natural keys of those same leads (aligned with the name arrays), so the away alert can
    // deep-link to one when exactly one lead is new.
    var newReplyKeys: [String] = []
    var newBookingKeys: [String] = []

    // #301: the deep-link target for the away alert — the sole new lead's key when exactly one lead is
    // new this tick (a reply OR a booking). nil when zero or several are new, so a coalesced multi-lead
    // alert opens the window instead of arbitrarily jumping to one (Dan's #301 decision).
    var deepLinkKey: String? {
        let keys = newReplyKeys + newBookingKeys
        return keys.count == 1 ? keys.first : nil
    }

    var message: String {
        var parts: [String] = []
        // #287 / #297: a reply or booking found this pass is the headline event, so lead with it and name
        // the org (Dan works by name). Both go through OutreachEventPhrasing so the manual ack and the
        // while-away alert phrase the same event identically; without this a reply/booking-only run
        // wrongly reads as "nothing was due".
        if let reply = OutreachEventPhrasing.replyPhrase(newReplies) {
            parts.append(reply)
        }
        if let booking = OutreachEventPhrasing.bookingPhrase(newBookings) {
            parts.append(booking)
        }
        if omniFocusChanged > 0 {
            parts.append("\(omniFocusChanged) follow-up\(omniFocusChanged == 1 ? "" : "s") updated")
        }
        guard !parts.isEmpty else { return "Reconcile complete — nothing was due." }
        return "Reconcile complete — " + parts.joined(separator: ", ") + "."
    }
}
