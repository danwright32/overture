import Foundation

// Decides whether an automatic scout is due (#33): about once a day. The app checks this
// on launch and periodically while open, and runs the scout itself when due; the scout
// is read-only (no sending), so auto-running it is safe.
enum ScoutSchedule {
    static let defaultInterval: TimeInterval = 24 * 3600  // daily

    static func isDue(lastScoutedAt: Date?, now: Date, interval: TimeInterval = defaultInterval) -> Bool {
        guard let last = lastScoutedAt else { return true }   // never scouted -> due
        return now.timeIntervalSince(last) >= interval
    }

    // The full gate the app applies before auto-running: only when auto-scout is enabled,
    // a run isn't already in progress, and a scheduled run is due.
    static func shouldAutoScout(enabled: Bool, isScanning: Bool, lastScoutedAt: Date?,
                                now: Date, interval: TimeInterval = defaultInterval) -> Bool {
        enabled && !isScanning && isDue(lastScoutedAt: lastScoutedAt, now: now, interval: interval)
    }
}
