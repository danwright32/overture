import Foundation

// The text shown in Overture's resident menu-bar item (#266 / Phase 2). An actionable error nudge
// wins; otherwise the last reconcile time; otherwise a watching/idle state. Pure so it's testable.
enum MenuBarStatus {
    static func line(lastReconcileAt: Date?, now: Date, omniFocusFailed: Bool) -> String {
        if omniFocusFailed { return "OmniFocus sync needs attention" }
        guard let last = lastReconcileAt else { return "Watching for replies and bookings" }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return "Last checked \(formatter.string(from: last))"
    }
}
