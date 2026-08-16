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
    // #499: set when a context.save() failed during this tick, so whatever it found may not
    // have persisted. The most actionable outcome, so it takes precedence in message below.
    var saveFailed: Bool = false
    // #2718: this tick could not READ Gmail while looking for a reply to a hand-sent pitch.
    //
    // Its OWN field rather than folded into `saveFailed`, deliberately. That flag's message says
    // "Reconcile ran but couldn't save its results", and a read that failed is not a save that failed: a
    // message may claim only what its check measured (L11), and two independent checks sharing one
    // status field means a pass from either erases the other's failure (L53).
    var replySearchFailure: String?
    // #2741: this tick could not READ Gmail for the threads it watches, on EVERY thread it tried.
    //
    // Its own field for the same reason `replySearchFailure` is: a read that failed is not a save that
    // failed, and two independent checks sharing one status field means a pass from either erases the
    // other's failure (L53). It is also a different path from that one, which is about the search for a
    // reply to a hand-sent pitch; this is the watcher over threads Overture sent itself.
    //
    // Set on the RATE, never on a count: one unreadable thread is ordinary contention, and an alert that
    // fires on it is an alert Dan learns to ignore (L77). `GmailReplyChecker.Outcome` decides.
    var replyWatchUnreadable: Bool = false

    // #308: every new lead's key this tick (replies then bookings, aligned with the name arrays), so a
    // coalesced multi-lead away alert can carry the whole set and a tap can filter the queue to exactly
    // those leads. deepLinkKey is just the count==1 special case of this.
    var newLeadKeys: [String] { newReplyKeys + newBookingKeys }

    // #301: the deep-link target for the away alert: the sole new lead's key when exactly one lead is
    // new this tick (a reply OR a booking). nil when zero or several are new; the multi-lead case routes
    // to the filtered new-leads view via newLeadKeys instead (#308).
    var deepLinkKey: String? {
        newLeadKeys.count == 1 ? newLeadKeys.first : nil
    }

    var message: String {
        if saveFailed {
            return "Reconcile ran but couldn't save its results. Try again; if this keeps happening, something's wrong with the local store."
        }
        // #2718: below the save failure, which is the more actionable of the two, and above the ordinary
        // report, because a tick that could not read Gmail has not established that nothing arrived.
        // The reason comes from the search itself, so it names what actually went wrong rather than
        // being flattened into one apologetic line (L11).
        if let replySearchFailure { return replySearchFailure }
        // #2741: above the ordinary report for the same reason, and said in its own words. A tick that
        // could not read a single thread it watches has not established that nobody replied, and the
        // sentence has to say that rather than let silence stand for it.
        if replyWatchUnreadable {
            return "Reconcile ran but couldn't read Gmail for any of the conversations it watches, so it "
                + "can't tell whether anyone replied. Check the Gmail connection."
        }
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
        guard !parts.isEmpty else { return "Reconcile complete: nothing was due." }
        return "Reconcile complete: " + parts.joined(separator: ", ") + "."
    }
}
