import Foundation

// The text shown in Overture's resident menu-bar item (#266 / Phase 2). An actionable error nudge
// wins; otherwise the last reconcile time; otherwise a watching/idle state. Pure so it's testable.
enum MenuBarStatus {
    static func line(lastReconcileAt: Date?, now: Date, omniFocusFailed: Bool,
                     hasUnreadLogProblems: Bool) -> String {
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
