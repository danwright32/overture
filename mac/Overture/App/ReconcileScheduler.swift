import Foundation
import SwiftData

// The app-owned scheduler for the safe deterministic reconciles (#265 / Phase 1 of #237). Its purpose
// is to run the while-away work (booking detection, reply detection, conversation-reminder evaluation
// → OmniFocus) from an owner whose lifetime is the PROCESS, not a window — so closing the window can't
// stop it. This file is the tested core: the individual reconcile steps with an injectable clock and
// OmniFocus client. The launch/timer wiring and the AppDelegate that owns it (and the stripping of
// RootView's .task blocks) are deferred to a runtime-verifiable session; this object is ready for them.
//
// It runs ONLY the safe reconciles. It deliberately NEVER triggers a Prep run, a reply-classify run,
// or a scout — every `claude -p` / AI path stays attended (window-only), per the #237 plan.
@MainActor
final class ReconcileScheduler {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // Run the safe reconciles once. Best-effort: each step swallows its own failure so one cannot
    // abort the others. Clock and OmniFocus client are injectable so the tick is unit-testable.
    func runSafeReconcilesOnce(now: Date = Date(),
                               omniFocusClient: OmniFocusClient = AppleScriptOmniFocusClient(),
                               horizonDays: Int = OmniFocusSyncConfig.loaded().horizonDays) {
        reconcileBookings(now: now)
        // Reply detection (GmailReplyChecker) is gated on a live Gmail connection and reads the real
        // token; it is best-effort and is exercised at the wiring layer / by GmailReplyChecker's own
        // tests, not here, so the tick stays hermetic.
        syncOmniFocus(now: now, client: omniFocusClient, horizonDays: horizonDays)
    }

    // Mark prospects Booked from the Downbeat export. No-op when the export is absent or unchanged.
    @discardableResult
    func reconcileBookings(now: Date) -> Int {
        let loaded = DownbeatBridge.loadWithHealth(now: now)
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let n = DownbeatBooking.reconcileBooked(prospects: all, clients: loaded.clients,
                                                bookings: loaded.bookings, health: loaded.health, now: now)
        if n > 0 { try? context.save() }
        return n
    }

    // Push due conversation reminders into OmniFocus and record the result so a failure stays visible
    // (#239). Awaited by the caller (unlike the old fire-and-forget) so the AppleScript completes.
    func syncOmniFocus(now: Date, client: OmniFocusClient, horizonDays: Int,
                       statusDefaults: UserDefaults = .standard) {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let desired = OmniFocusSync.desired(from: all, now: now, horizonDays: horizonDays)
        do {
            _ = try OmniFocusSync.apply(desired: desired, client: client)
            OmniFocusSyncStatus.recordSuccess(into: statusDefaults)
        } catch {
            OmniFocusSyncStatus.recordFailure("\(error)", at: now, into: statusDefaults)
        }
    }
}
