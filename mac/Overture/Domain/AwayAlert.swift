import Foundation

// #269 / Phase 5: the while-away notification. When an automatic reconcile detects new replies or
// bookings, it posts ONE coalesced message naming them (Dan's #263 decision: notify on replies and
// bookings, not just errors). Pure: the diff that finds what's new this tick and the message it builds.
enum AwayAlert {
    // Names present after the reconcile whose key was NOT present before — i.e. detected THIS tick. The
    // caller snapshots the keys before mutating, so each item is reported exactly once.
    static func newNames(before: Set<String>, after: [(key: String, name: String)]) -> [String] {
        after.filter { !before.contains($0.key) }.map { $0.name }
    }

    // #301: the natural keys of the leads new this tick, in the same order as newNames, so the away
    // alert can deep-link to one (it links only when exactly one lead is new — see ReconcileSummary).
    static func newKeys(before: Set<String>, after: [(key: String, name: String)]) -> [String] {
        after.filter { !before.contains($0.key) }.map { $0.key }
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
