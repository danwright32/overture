import SwiftUI
import AppKit

// The resident menu-bar menu (#266 / Phase 2). Reads the reconcile status reactively from
// UserDefaults (so it needs no reference to the scheduler), and offers the three actions: open the
// window, run a reconcile now, quit. Closing the window no longer quits — this menu is how Dan
// reopens or quits once the app runs headless.
struct MenuBarContent: View {
    @AppStorage(ReconcileScheduler.lastReconcileKey) private var lastReconcileEpoch: Double = 0
    @AppStorage(OmniFocusSyncStatus.failedAtKey) private var omniFocusFailedAt: Double = 0
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let last = lastReconcileEpoch > 0 ? Date(timeIntervalSince1970: lastReconcileEpoch) : nil
        Text(MenuBarStatus.line(lastReconcileAt: last, now: Date(), omniFocusFailed: omniFocusFailedAt > 0))
        Divider()
        Button("Open Overture") { openWindow(id: "main") }
        Button("Run reconcile now") { AppDelegate.shared?.runReconcileNow() }
        Divider()
        Button("Quit Overture") { NSApplication.shared.terminate(nil) }
    }
}
