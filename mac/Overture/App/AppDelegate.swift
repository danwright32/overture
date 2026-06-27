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
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
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
        guard AppEnvironment.shouldStartBackgroundServices else { return }
        // #301: become the notification delegate so a tapped alert is actionable instead of a dead end,
        // and register the action buttons (the OmniFocus-permission alert's Open Settings).
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NotificationService.categories())
        // #279: ensure the owner-only log directory exists even in the degraded/no-store state (that is
        // exactly when the agent's stderr matters); the installer created it, this is the safety net.
        AgentLogLocation.prepareDirectory()
        guard let container = AppDelegate.sharedContainer else { return }
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

    // #301: handle a tapped notification. The decision is the pure NotificationService.route; here we
    // only carry out its side effects. Lead/window routes reuse the existing deep-link handler
    // (RootView.onOpenURL) by opening the app's own URL scheme, which reactivates this instance and
    // reopens its window; the settings route jumps to the Automation privacy pane.
    // nonisolated because UNUserNotificationCenterDelegate isn't main-actor-isolated; the routing
    // decision is pure, and the side effects hop to the main actor (NSWorkspace/NSApp). The completion
    // handler is called immediately — the routing work is fire-and-forget.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        if let route = NotificationService.route(actionIdentifier: response.actionIdentifier, userInfo: userInfo) {
            Task { @MainActor in self.handle(route) }
        }
        completionHandler()
    }

    // Carry out a tapped notification's route. Lead/window routes reuse the existing deep-link handler
    // (RootView.onOpenURL) by opening the app's own URL scheme, which reactivates this instance and
    // reopens its window (#236/#282); the settings route jumps to the Automation privacy pane.
    private func handle(_ route: NotificationService.Route) {
        switch route {
        case .openLead(let key):
            if let url = OvertureDeepLink.leadURL(forKey: key) { open(url) }
        case .openApp:
            if let url = URL(string: "\(OvertureDeepLink.scheme)://\(OvertureDeepLink.showHost)") { open(url) }
        case .openSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private func open(_ url: URL) {
        NSWorkspace.shared.open(url)
        NSApp.activate(ignoringOtherApps: true)
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
