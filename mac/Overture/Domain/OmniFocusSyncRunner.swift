import Foundation

// #268 / Phase 4: the decision layer for the unattended OmniFocus push. Splitting it out of the
// scheduler keeps it pure and testable; the native permission probe and the real notifier are thin
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
    // Returns how many OmniFocus tasks changed (created + completed), so a manual reconcile can report
    // it, and how many contacts a completion Dan made over there stamped; both 0 when skipped or failed.
    //
    // #2899: `recordCompletions` is injected rather than called directly, because this layer is pure over
    // value types and the model it has to write to lives on the main actor. Defaulted to doing nothing so
    // the permission and failure tests need not care, and asserted at BOTH real call sites by
    // `OmniFocusCompletionsAreCarriedBackTests`: a default that silently drops the signal is exactly the
    // shape that leaves a task ticked off in OmniFocus and nothing moved in Overture (L46).
    @discardableResult
    static func run(desired: [OmniFocusSync.DesiredTask],
                    permission: AutomationAuthorization,
                    client: OmniFocusClient,
                    notifier: OmniFocusNotifier,
                    now: Date,
                    defaults: UserDefaults = .standard,
                    recordCompletions: ([OmniFocusSync.DesiredTask]) -> Int = { _ in 0 })
        -> (tasks: Int, stamped: Int) {
        guard permission == .granted else {
            // Edge-detect on the prior state so a denial that persists across many ticks notifies once.
            let alreadyFlagged = OmniFocusSyncStatus.isPermissionNeeded(from: defaults)
            OmniFocusSyncStatus.recordPermissionNeeded(at: now, into: defaults)
            if !alreadyFlagged { notifier.notifyPermissionNeeded() }
            return (0, 0)
        }
        let hadFailure = OmniFocusSyncStatus.lastFailure(from: defaults) != nil
        do {
            let r = try OmniFocusSync.apply(desired: desired, client: client)
            let stamped = recordCompletions(r.handled)
            // #2882: a run that got through with some tasks refused is not a success and not a total
            // failure, and it must not be recorded as either. Recorded as a failure so it stays on the
            // masthead until a clean run clears it, with a message naming WHICH shows were missed, since
            // the harm is a reminder that never arrives and Dan cannot see an absence.
            guard r.failures.isEmpty else {
                let message = OmniFocusSync.partialFailureMessage(failures: r.failures,
                                                                  attempted: r.created + r.completed + r.failures.count)
                OmniFocusSyncStatus.recordFailure(message, at: now, into: defaults)
                if !hadFailure { notifier.notifySyncFailed(message) }
                return (r.created + r.completed, stamped)
            }
            OmniFocusSyncStatus.recordSuccess(at: now, into: defaults)
            return (r.created + r.completed, stamped)
        } catch {
            OmniFocusSyncStatus.recordFailure("\(error)", at: now, into: defaults)
            if !hadFailure { notifier.notifySyncFailed("\(error)") }   // one per failure episode
            return (0, 0)
        }
    }
}
