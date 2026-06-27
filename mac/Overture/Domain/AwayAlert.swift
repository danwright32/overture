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

    // One notification body summarizing what arrived, or nil when nothing is new (no notification).
    static func message(newReplies: [String], newBookings: [String]) -> String? {
        var parts: [String] = []
        if !newReplies.isEmpty {
            parts.append("\(newReplies.count) new repl\(newReplies.count == 1 ? "y" : "ies") (\(newReplies.joined(separator: ", ")))")
        }
        if !newBookings.isEmpty {
            parts.append("\(newBookings.count) new booking\(newBookings.count == 1 ? "" : "s") (\(newBookings.joined(separator: ", ")))")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }
}
