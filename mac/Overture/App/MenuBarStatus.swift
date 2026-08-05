import Foundation

// The text shown in Overture's resident menu-bar item (#266 / Phase 2). An actionable error nudge
// wins; otherwise the last reconcile time; otherwise a watching/idle state. Pure so it's testable.
enum MenuBarStatus {
    // #2091: `watchReport` is passed in (built by WatchHeartbeatStore.currentReport at the call site,
    // which owns the clocks) rather than derived here, so this stays pure and the queue masthead and
    // this line are two readers of ONE verdict instead of two implementations of it.
    static func line(lastReconcileAt: Date?, now: Date, omniFocusFailed: Bool,
                     hasUnreadLogProblems: Bool, watchReport: WatchGap.Report? = nil) -> String {
        // #2091: a watch that has stopped outranks everything below it, because everything below it is
        // about work this app is supposed to be doing and is not. In particular it must outrank the
        // "Last checked" line, which is the defect: with no date on it, "Last checked 9:14 PM" reads
        // exactly the same three days into an outage as it does thirty seconds after a healthy tick.
        // A silence that has already ENDED is deliberately not shown here: it is history, and the queue
        // masthead is where Dan reads it. This line is for the fault that is happening now.
        if let watchReport, case .ongoing = watchReport {
            return WatchGap.line(for: watchReport, now: now)
        }
        if omniFocusFailed { return "OmniFocus sync needs attention" }
        // #302: the agent wrote new stderr Dan hasn't seen; nudge him to the logs so a silently
        // misbehaving overnight agent doesn't go unnoticed. Ranks below the more specific OmniFocus
        // failure (which has its own remedy) but above the idle/last-checked states.
        if hasUnreadLogProblems { return "Agent logged a problem: open agent logs" }
        guard let last = lastReconcileAt else { return "Watching for replies and bookings" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "Last checked \(formatter.string(from: last))"
    }
}
