import Foundation

// #269 / Phase 5: the while-away notification. When an automatic reconcile detects new replies or
// bookings, it posts ONE coalesced message naming them (Dan's #263 decision: notify on replies and
// bookings, not just errors). Pure: the diff that finds what's new this tick and the message it builds.
enum AwayAlert {
    // The shows present after the reconcile whose IDENTITY was not present before, i.e. detected THIS tick.
    // The caller snapshots the identities before mutating, so each item is reported exactly once, and the
    // caller takes the names and (#301) the deep link keys from what this returns, so the two stay aligned.
    //
    // #4417: by identity, never by natural key. A scout landing mid tick re-keys a row, and a key diff then
    // read an already booked or replied show as new. Generic so the rule is testable without a store.
    static func newShows<Show, ID: Hashable>(before: Set<ID>, after: [Show], id: (Show) -> ID) -> [Show] {
        after.filter { !before.contains(id($0)) }
    }

    // One notification body summarizing what arrived, or nil when nothing is new (no notification).
    // #297: phrasing lives in OutreachEventPhrasing so this matches the manual ack word-for-word.
    static func message(newReplies: [String], newBookings: [String]) -> String? {
        let parts = [
            OutreachEventPhrasing.replyPhrase(newReplies),
            OutreachEventPhrasing.bookingPhrase(newBookings)
        ].compactMap { $0 }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }
}
