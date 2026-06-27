import SwiftUI
import SwiftData

// Owns the ReconcileScheduler for the PROCESS lifetime (#265 / Phase 1 of #237), so the safe
// reconciles run independent of any window. Wired via @NSApplicationDelegateAdaptor in OvertureApp;
// the store container is handed over by OvertureApp through `sharedContainer` (the App owns the store
// after the Phase 0 lock). Starting here, at applicationDidFinishLaunching, rather than in a View's
// .task, is what survives the window closing (the point of the resident rearchitecture).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Set by OvertureApp.init once the store has been opened (nil in the degraded/no-store state).
    // Written once on the main thread during launch and read in applicationDidFinishLaunching (also
    // main), so the unchecked isolation is safe.
    nonisolated(unsafe) static var sharedContainer: ModelContainer?

    private var scheduler: ReconcileScheduler?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppEnvironment.shouldStartBackgroundServices,
              let container = AppDelegate.sharedContainer else { return }
        let scheduler = ReconcileScheduler(context: container.mainContext)
        scheduler.start()
        self.scheduler = scheduler
    }
}
