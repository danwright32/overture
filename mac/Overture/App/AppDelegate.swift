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

    // #1160: set by OvertureApp.init. When this launch is a duplicate (another live copy holds the
    // store's single-writer lock), applicationDidFinishLaunching terminates this process so it defers
    // to the resident copy instead of lingering on the degraded screen as a second instance.
    // Written once on the main thread during launch and read in applicationDidFinishLaunching (also
    // main), so the unchecked isolation is safe.
    nonisolated(unsafe) static var launchOutcome: StoreLaunchOutcome = .ready

    // Reachable from the menu-bar scene (#266) so "Run reconcile now" can trigger the scheduler.
    static weak var shared: AppDelegate?
    private var scheduler: ReconcileScheduler?
    private var onboardingWindow: NSWindow?
    // #2220: held for the process lifetime, because it is the process lifetime it reports on. An
    // observer released early would leave the watch-gap rule with no sleep to subtract, which is the
    // false-outage-every-morning defect back again with nothing to show it had returned.
    private var sleepObserver: SleepObserver?

    override init() {
        super.init()
        AppDelegate.shared = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // #1160: a duplicate launch (another live copy holds the store's single-writer lock) defers to
        // the resident copy and quits immediately, before touching any services or showing a window, so
        // two live instances can never coexist however a duplicate got spawned (the `overture` launch
        // race, or a manual double-launch). The resident copy is surfaced by build-install.sh, which
        // waits for it to register with LaunchServices before opening overture://show.
        if AppDelegate.launchOutcome == .duplicateInstance {
            NSApp.terminate(nil)
            return
        }
        guard AppEnvironment.shouldStartBackgroundServices else { return }
        // #2220, and BEFORE anything that could stamp a heartbeat. Three things in order, each of which
        // the watch-gap rule cannot work without:
        //
        // 1. Throw away any verdict reached with the awake clock #2220 retired. That clock ran straight
        //    through sleep, so what is sitting in defaults on the first launch after this ships is a
        //    twelve-hour "outage" that was Dan's laptop being shut. It would render for a day.
        // 2. Record when this process started, which is the only thing that tells "Overture was not
        //    running" apart from "Overture was running and did not check".
        // 3. Start watching for sleep, since sleep that nothing observed is sleep that gets counted as a
        //    failure to watch.
        WatchHeartbeatStore.discardVerdictsFromTheRetiredClock()
        ProcessLaunch.stampStart(now: Date())
        let sleepObserver = SleepObserver()
        sleepObserver.start()
        self.sleepObserver = sleepObserver
        // #301: become the notification delegate so a tapped alert is actionable instead of a dead end,
        // and register the action buttons (the OmniFocus-permission alert's Open Settings).
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(NotificationService.categories())
        // #279: ensure the owner-only log directory exists even in the degraded/no-store state (that is
        // exactly when the agent's stderr matters); the installer created it, this is the safety net.
        AgentLogLocation.prepareDirectory()
        // #295: bound the agent's stdout/stderr so an always-resident process can't grow them without
        // limit. Runs every launch (= every login for the resident agent); a no-op until a file is large.
        AgentLogLocation.capLogs()
        guard let container = AppDelegate.sharedContainer else { return }
        // Runs the one-time, idempotent recipients/thread/salutation backfills here on the
        // window-independent launch path (not in a View's .task), so a windowless resident launch still
        // migrates before the reconciler (and any later per-recipient send) can read the new model.
        // #479: LaunchMigrations saves explicitly right after they run, so a short-lived launch can't
        // lose the writes to autosave timing.
        // #1601: a failed save inside here now reports itself (logged, plus a first-party notification),
        // rather than returning a false that this call site discarded. Reporting lives with the failure
        // so every caller gets it, instead of each one having to remember.
        LaunchMigrations.run(in: container.mainContext)
        // #2966: the classify run's liveness, handed in HERE because the scheduler itself may not name
        // ReplyClassifyService (ReconcileNoSpendGuardTests). This closure only reads the run's marker
        // file; it can never start a run.
        let scheduler = ReconcileScheduler(context: container.mainContext,
                                           replyRunAlive: { ReplyClassifyService.isRunning(now: $0) })
        scheduler.start()
        self.scheduler = scheduler

        // #334: give the resident app a Dock running cue while its main window is open. Recompute the
        // activation policy whenever a window becomes key or closes, so a normal Dock tile (with the
        // running dot) appears in use and the app drops back to menu-bar-only when the window closes.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowVisibilityChanged),
                       name: NSWindow.didBecomeKeyNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowWillClose),
                       name: NSWindow.willCloseNotification, object: nil)
        // #2115: and whenever the due count changes, since that now decides whether there is a Dock icon
        // at all. Without this the badge would only ever appear on a window event, so work falling due
        // while Dan is away (the case it exists for) would go unshown until he came back anyway.
        nc.addObserver(self, selector: #selector(windowVisibilityChanged),
                       name: UserDefaults.didChangeNotification, object: nil)
        updateDockPresence()

        // #270: surface first-run onboarding while Dan is present whenever a grant is missing, so the
        // resident process can inherit working permissions instead of degrading silently while away.
        Task { @MainActor in
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            let state = OnboardingState(
                gmailConnected: GmailConnection.shared.isConnected,
                omniFocusGranted: OmniFocusAutomationPermission.current() == .granted,
                notificationsAuthorized: settings.authorizationStatus == .authorized,
                loginAgentInstalled: OnboardingState.agentInstalled())
            if state.shouldAutoShow { self.showOnboarding() }
        }
    }

    // #2088: closing the window must never end the process. Overture is resident (#266): with the
    // window closed the ReconcileScheduler is still doing the watching half of the product, so the
    // window is a view onto a running app and not the app itself.
    //
    // Nothing here said so, and AppKit asks. Reproduced on the live Release app on 2026-08-04 with the
    // system log open: closing the window went straight down the last-window-closed path
    // (`NSTerminateAfterLastWindowClosedDelay`) into `terminate:`, and the status bar window closed
    // five milliseconds AFTER termination had begun, so the menu bar item vanishing was a symptom of
    // the quit rather than its cause. #2088 had guessed the removable status item from #1966; the
    // capture contains no "terminating on removal" line at all, and that guess was wrong.
    //
    // An optional @objc delegate method is reached through responds(to:), so the ONLY thing standing
    // between Dan and a dead reply watcher was this method not existing. Quitting stays deliberate:
    // the menu bar's own Quit, and the #1160 duplicate-instance path, both call terminate directly and
    // are untouched by this answer.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // #2220: quitting is somebody's decision, not a fault. Dan quitting from the menu bar, or a shutdown
    // asking every app to stop, both arrive here, and without this record the silence that follows would
    // be reported back to him as Overture having failed. A product that reports a person's own decisions
    // as failures is one whose reports stop being read (L36).
    func applicationWillTerminate(_ notification: Notification) {
        guard AppEnvironment.shouldStartBackgroundServices else { return }
        ProcessLaunch.stampCleanQuit(now: Date())
    }

    // #301: handle a tapped notification. The decision is the pure NotificationService.route; here we
    // only carry out its side effects. Lead/window routes reuse the existing deep-link handler
    // (RootView.onOpenURL) by opening the app's own URL scheme, which reactivates this instance and
    // reopens its window; the settings route jumps to the Automation privacy pane.
    // nonisolated because UNUserNotificationCenterDelegate isn't main-actor-isolated; the routing
    // decision is pure, and the side effects hop to the main actor (NSWorkspace/NSApp). The completion
    // handler is called immediately; the routing work is fire-and-forget.
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
        case .openLeads(let keys):
            // #308: a coalesced multi-lead away alert opens the queue filtered to exactly the new leads.
            // Round-trips through the app's own URL scheme (like the single-lead/window routes) so the
            // windowless resident reactivates and reopens its window before the queue focuses the set.
            if let url = OvertureDeepLink.leadsURL(forKeys: keys) { open(url) }
        case .openApp:
            if let url = URL(string: "\(OvertureDeepLink.scheme)://\(OvertureDeepLink.showHost)") { open(url) }
        case .openSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
                NSWorkspace.shared.open(url)
            }
        case .retrySync:
            // #306: the Retry sync button on the OmniFocus-failed alert re-runs the safe reconcile,
            // whose last step is the OmniFocus push; runNow already acks with a result notification.
            runReconcileNow()
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

    // #334 Dock running cue. didBecomeKey fires as the main window opens; willClose fires as it
    // closes (deferred a tick so the closing window has left NSApp.windows before we recount).
    @objc private func windowVisibilityChanged() { updateDockPresence() }

    @objc private func windowWillClose() {
        DispatchQueue.main.async { [weak self] in self?.updateDockPresence() }
    }

    // The decision, the ordering and the activation all live in DockPresence, where they are tested. This
    // only supplies the real NSApp. (Promoting out of the menu-bar-only presence does NOT make the app
    // active, and an inactive app owns no menu bar, so none of its shortcuts fire: that is the Cmd+L bug.)
    private func updateDockPresence() {
        // #2115: the count decides whether there is a Dock icon at all, so it is read before the policy
        // rather than painted onto whatever icon happens to exist.
        let due = DueBadge.current()
        DockPresence.apply(
            mainWindowVisible: NSApp.windows.contains(where: isMainContentWindow),
            dueCount: due,
            current: NSApp.activationPolicy(),
            setPolicy: { NSApp.setActivationPolicy($0) },
            activate: { NSApp.activate(ignoringOtherApps: true) })
        // nil, never "0": an empty badge is no badge, and a red dot reading zero claims work Dan does not
        // have. Needs no notification permission, unlike an alert.
        NSApp.dockTile.badgeLabel = DueBadge.label(count: due)
    }

    // The main Overture window only (#334 chose to exclude the onboarding window): a visible,
    // titled window that can become main, and isn't the onboarding window or the menu-bar item.
    private func isMainContentWindow(_ w: NSWindow) -> Bool {
        w.isVisible && w !== onboardingWindow && w.canBecomeMain && w.styleMask.contains(.titled)
    }
}
