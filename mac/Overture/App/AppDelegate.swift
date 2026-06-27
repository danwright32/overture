import SwiftUI
import SwiftData
import AppKit
import UserNotifications

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

    // Reachable from the menu-bar scene (#266) so "Run reconcile now" can trigger the scheduler.
    static weak var shared: AppDelegate?
    private var scheduler: ReconcileScheduler?
    private var onboardingWindow: NSWindow?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard AppEnvironment.shouldStartBackgroundServices,
              let container = AppDelegate.sharedContainer else { return }
        let scheduler = ReconcileScheduler(context: container.mainContext)
        scheduler.start()
        self.scheduler = scheduler

        // #270: surface first-run onboarding while Dan is present whenever a grant is missing, so the
        // resident process can inherit working permissions instead of degrading silently while away.
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let state = OnboardingState(
                gmailConnected: GmailAuthManager.shared.isConnected,
                omniFocusGranted: OmniFocusAutomationPermission.current() == .granted,
                notificationsAuthorized: settings.authorizationStatus == .authorized,
                loginAgentInstalled: OnboardingState.agentInstalled())
            if state.shouldAutoShow { self.showOnboarding() }
        }
    }

    // The menu's "Run reconcile now".
    func runReconcileNow() {
        scheduler?.runNow()
    }

    // The menu's "Set up Overture…" and the first-run auto-show. Hosts OnboardingView in a plain
    // AppKit window so it works for the windowless resident (LSUIElement) process at launch.
    func showOnboarding() {
        if let existing = onboardingWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: OnboardingView(onClose: { [weak self] in
            self?.onboardingWindow?.close()
        }))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Set up Overture"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        onboardingWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
