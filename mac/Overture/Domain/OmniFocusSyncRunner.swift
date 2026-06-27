import Foundation

// #268 / Phase 4: the decision layer for the unattended OmniFocus push. Splitting it out of the
// scheduler keeps it pure and testable — the native permission probe and the real notifier are thin
// untestable shims injected in. The rule: if Automation is not already granted, NEVER fire the
// AppleScript (a windowless process can't answer the TCC modal it would post); record the
// permission-needed state and notify ONCE per episode. When granted, run the apply and notify once on
// a fresh failure.

// Whether this process already holds OmniFocus Automation permission. Resolved by a silent probe
// (AEDeterminePermissionToAutomateTarget with askUserIfNeeded:false), never one that prompts.
enum AutomationAuthorization: Sendable {
    case granted
    case notGranted
}

// The seam Phase 5 fills with a real UNUserNotification delivery; Phase 4 ships a minimal real
// notifier plus this protocol so the runner stays testable.
protocol OmniFocusNotifier {
    func notifyPermissionNeeded()
    func notifySyncFailed(_ message: String)
}

enum OmniFocusSyncRunner {
    static func run(desired: [OmniFocusSync.DesiredTask],
                    permission: AutomationAuthorization,
                    client: OmniFocusClient,
                    notifier: OmniFocusNotifier,
                    now: Date,
                    defaults: UserDefaults = .standard) {
        guard permission == .granted else {
            // Edge-detect on the prior state so a denial that persists across many ticks notifies once.
            let alreadyFlagged = OmniFocusSyncStatus.isPermissionNeeded(from: defaults)
            OmniFocusSyncStatus.recordPermissionNeeded(at: now, into: defaults)
            if !alreadyFlagged { notifier.notifyPermissionNeeded() }
            return
        }
        let hadFailure = OmniFocusSyncStatus.lastFailure(from: defaults) != nil
        do {
            _ = try OmniFocusSync.apply(desired: desired, client: client)
            OmniFocusSyncStatus.recordSuccess(into: defaults)
        } catch {
            OmniFocusSyncStatus.recordFailure("\(error)", at: now, into: defaults)
            if !hadFailure { notifier.notifySyncFailed("\(error)") }   // one per failure episode
        }
    }
}
