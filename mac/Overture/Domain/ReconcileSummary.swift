import Foundation

// #285 (no silent no-op): what one reconcile pass changed, so a MANUAL "Run reconcile now" can
// acknowledge itself even when nothing was due. The automatic timer/watcher passes ignore this (they
// would otherwise notify every tick); only the on-demand menu action surfaces the message.
struct ReconcileSummary: Equatable, Sendable {
    var bookingsMarked: Int
    var omniFocusChanged: Int
    // #269: names of leads that became replied / booked THIS tick, for the while-away notification.
    var newReplies: [String] = []
    var newBookings: [String] = []

    var message: String {
        var parts: [String] = []
        if bookingsMarked > 0 {
            parts.append("\(bookingsMarked) newly booked")
        }
        if omniFocusChanged > 0 {
            parts.append("\(omniFocusChanged) follow-up\(omniFocusChanged == 1 ? "" : "s") updated")
        }
        guard !parts.isEmpty else { return "Reconcile complete — nothing was due." }
        return "Reconcile complete — " + parts.joined(separator: ", ") + "."
    }
}
