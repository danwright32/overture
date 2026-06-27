import Foundation
import SwiftData

// The app-owned scheduler for the safe deterministic reconciles (#265 / Phase 1 of #237). It runs the
// while-away work — booking detection, reply detection, conversation-reminder evaluation → OmniFocus —
// from an owner whose lifetime is the PROCESS (started by AppDelegate at launch), not a window, so
// closing the window can't stop it. It runs at launch, on a configurable timer (30-min default), and
// whenever the Downbeat export changes.
//
// It runs ONLY the safe reconciles. It deliberately NEVER triggers a Prep run, a reply-classify run,
// or a scout — every `claude -p` / AI path stays attended (window-only), per the #237 plan.
@MainActor
final class ReconcileScheduler {
    private let context: ModelContext
    private var timerTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?

    init(context: ModelContext) {
        self.context = context
    }

    // The reconcile cadence (#245 decision: configurable, 30-minute default).
    static let intervalKey = "reconcileIntervalMinutes"
    static func intervalSeconds(defaults: UserDefaults = .standard) -> Double {
        let minutes = defaults.double(forKey: intervalKey)
        return (minutes > 0 ? minutes : 30) * 60
    }

    // Begin running: an immediate reconcile, then the periodic timer, plus the export-change watcher.
    func start() {
        timerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSafeReconcilesOnce()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ReconcileScheduler.intervalSeconds() * 1_000_000_000))
                if Task.isCancelled { break }
                await self.runSafeReconcilesOnce()
            }
        }
        watcherTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastSeen = ReconcileScheduler.exportModifiedAt()
            for await _ in DownbeatExportWatcher.changes() {
                let current = ReconcileScheduler.exportModifiedAt()
                if DownbeatExportWatcher.shouldReconcile(previous: lastSeen, current: current) {
                    lastSeen = current
                    await self.runSafeReconcilesOnce()
                }
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        watcherTask?.cancel()
    }

    // Run the safe reconciles once. Best-effort: each step swallows its own failure so one cannot
    // abort the others. Bookings first, then reply detection (so a fresh reply can become a due
    // reminder), then the OmniFocus push (gated on Dan's opt-in, like the old auto path).
    func runSafeReconcilesOnce(now: Date = Date()) async {
        reconcileBookings(now: now)
        // Reply detection: gated on a live Gmail connection inside checkReplies; best-effort.
        await GmailReplyChecker().checkReplies(in: context)
        let config = OmniFocusSyncConfig.loaded()
        if config.enabled {
            syncOmniFocus(now: now, client: AppleScriptOmniFocusClient(), horizonDays: config.horizonDays)
        }
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
    // (#239). Synchronous on the main actor (AppleScript requires it); the caller awaits the whole tick
    // so the Apple events complete rather than racing teardown (unlike the old fire-and-forget).
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

    // Last-modified time of the Downbeat export, to gate the live re-reconcile (#197) so a spurious
    // filesystem event on an unchanged file doesn't trigger redundant work.
    static func exportModifiedAt() -> Date? {
        (try? DownbeatBridge.defaultURL
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }
}
