import Foundation

// Decides whether an automatic scout is due (#33): about once a day. The app checks this
// on launch and periodically while open, and runs the scout itself when due.
//
// Auto-running is safe for two reasons now, not one (#802). The scout still never sends anything, and
// as of Dan's 4th decision (2026-07-12) the automatic run also never SPENDS anything: it runs at
// `.watchOnly` depth, which fetches and hashes every watched source and reads none of them. Carnegie
// still fully ingests on it, because its Algolia path is native and free.
//
// That distinction is load-bearing and it is why this comment is not just "read-only, so it is safe"
// any more. Phase 4 could easily have made the daily run launch a claude -p extract batch while Dan was
// not at the machine, competing with Prep for the same Max-plan capacity. Reading a changed page happens
// only on a scout Dan started.
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
