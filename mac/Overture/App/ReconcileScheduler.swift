import Foundation
import SwiftData

// The app-owned scheduler for the safe deterministic reconciles (#265 / Phase 1 of #237). It runs the
// while-away work (booking detection, reply detection, conversation-reminder evaluation → OmniFocus)
// from an owner whose lifetime is the PROCESS (started by AppDelegate at launch), not a window, so
// closing the window can't stop it. It runs at launch, on a configurable timer (30-min default), and
// whenever the Downbeat export changes.
//
// It runs ONLY the safe reconciles. It deliberately NEVER triggers a Prep run, a reply-classify run,
// or a scout: every `claude -p` / AI path stays attended (window-only), per the #237 plan.
@MainActor
final class ReconcileScheduler {
    private let context: ModelContext
    private var timerTask: Task<Void, Never>?
    private var watcherTask: Task<Void, Never>?

    // When the last reconcile finished: surfaced in the menu-bar status line (#266). Mirrored to
    // UserDefaults so the menu can read it reactively without holding the scheduler instance.
    nonisolated static let lastReconcileKey = "lastReconcileAt"
    private(set) var lastReconcileAt: Date?

    init(context: ModelContext) {
        self.context = context
    }

    // Trigger one reconcile on demand (the menu's "Run reconcile now"). Unlike the silent timer ticks,
    // a manual run ALWAYS acknowledges itself with a notification, even when nothing was due, so the
    // click never appears to do nothing (#285).
    func runNow(notify: @escaping (String) -> Void = { NotificationService.post(.reconcile, title: "Overture", body: $0) }) {
        Task { @MainActor in
            let summary = await self.runSafeReconcilesOnce()
            notify(summary.message)
        }
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
            self.notifyIfNewWhileAway(await self.runSafeReconcilesOnce())
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ReconcileScheduler.intervalSeconds() * 1_000_000_000))
                if Task.isCancelled { break }
                self.notifyIfNewWhileAway(await self.runSafeReconcilesOnce())
            }
        }
        watcherTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var lastSeen = ReconcileScheduler.exportModifiedAt()
            for await _ in DownbeatExportWatcher.changes() {
                let current = ReconcileScheduler.exportModifiedAt()
                if DownbeatExportWatcher.shouldReconcile(previous: lastSeen, current: current) {
                    lastSeen = current
                    self.notifyIfNewWhileAway(await self.runSafeReconcilesOnce())
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
    // Phase F: a reply lives on a contact now (the A3 lead rollup is gone), so a "new reply" for the
    // away alert is a contact reply that still needs attention; the legacy lead outcome is kept as a
    // fallback for un-backfilled stores.
    nonisolated static func hasNewReply(_ p: Prospect) -> Bool {
        p.hasUnhandledReply || p.outcome == .replied
    }

    @discardableResult
    func runSafeReconcilesOnce(now: Date = Date()) async -> ReconcileSummary {
        // #269: snapshot which leads are already replied/booked BEFORE mutating, so the diff after the
        // reconcile names exactly what arrived this tick (each item reported once).
        let before = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let repliedBefore = Set(before.filter(Self.hasNewReply).map(\.naturalKey))
        let bookedBefore = Set(before.filter { $0.outcome == .booked }.map(\.naturalKey))

        let bookingResult = reconcileBookings(now: now)
        // #923: same trigger as the booking pass. Re-judge conflicts so a night newly booked in the export
        // flags its show at once, instead of leaving it sendable until the next scout.
        reapplyConflicts(now: now)
        // #1456: watch whether Downbeat's feed is still MOVING, on this same free tick, so the dry-pipe
        // nudge advances daily without a scout.
        observeFeedFreshness(now: now)
        // Reply detection: gated on a live Gmail connection inside checkReplies; best-effort.
        let replyCheckSaveFailed = await GmailReplyChecker().checkReplies(in: context)
        // #1158: keep the cached Gmail signature current so a signature Dan changes in Gmail is picked up
        // without a manual reconnect. Rides this safe, free tick (launch + periodic + export-change) but
        // self-throttles to at most one fetch per day, and can never clobber a good stored signature on a
        // failed fetch. Best-effort and free, like the reply detection above; no paid AI run.
        await GmailSignatureService.refreshIfDue()
        var omniFocusChanged = 0
        let config = OmniFocusSyncConfig.loaded()
        if config.enabled {
            omniFocusChanged = syncOmniFocus(now: now, client: AppleScriptOmniFocusClient(), horizonDays: config.horizonDays)
        }

        let after = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let repliedAfter = after.filter(Self.hasNewReply).map { (key: $0.naturalKey, name: $0.groupName) }
        let bookedAfter = after.filter { $0.outcome == .booked }.map { (key: $0.naturalKey, name: $0.groupName) }
        let newReplies = AwayAlert.newNames(before: repliedBefore, after: repliedAfter)
        let newBookings = AwayAlert.newNames(before: bookedBefore, after: bookedAfter)
        // #301: keep the keys aligned with the names so the away alert can deep-link to a sole new lead.
        let newReplyKeys = AwayAlert.newKeys(before: repliedBefore, after: repliedAfter)
        let newBookingKeys = AwayAlert.newKeys(before: bookedBefore, after: bookedAfter)

        lastReconcileAt = now
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: ReconcileScheduler.lastReconcileKey)
        return ReconcileSummary(omniFocusChanged: omniFocusChanged,
                                newReplies: newReplies, newBookings: newBookings,
                                newReplyKeys: newReplyKeys, newBookingKeys: newBookingKeys,
                                saveFailed: bookingResult.saveFailed || replyCheckSaveFailed)
    }

    // #269: an AUTOMATIC tick (timer/watcher, i.e. while Dan is likely away) posts one coalesced
    // notification naming any new replies/bookings. The manual menu run uses the ack instead (#285), so
    // a click is never double-notified.
    // The poster is injected (defaulting to NotificationService.post) so the body and the deep-link keys
    // threaded onto the alert are testable without the live notification center (#301/#308).
    func notifyIfNewWhileAway(_ summary: ReconcileSummary,
                              post: (_ body: String, _ leadKeys: [String]) -> Void = {
                                  NotificationService.post(.away, title: "Overture", body: $0, leadKeys: $1)
                              }) {
        // #499: a save failure is worth waking Dan for even with no new leads this tick, since it
        // is more actionable than "nothing was due" and would otherwise never surface unattended.
        if summary.saveFailed {
            post(summary.message, summary.newLeadKeys)
            return
        }
        guard let body = AwayAlert.message(newReplies: summary.newReplies, newBookings: summary.newBookings) else { return }
        // #308: carry every new-lead key: a tap deep-links to the sole lead when one is new, or to the
        // filtered new-leads view when several are.
        post(body, summary.newLeadKeys)
    }

    // #923: re-judge every stored show's date conflict against the export that just reconciled.
    //
    // A conflict has two inputs: Dan's days off (which he edits by hand, re-judged on the spot by #901/#922)
    // and Downbeat's bookings (which Dan does NOT touch; they arrive in the export). The scout judges a
    // show when it first arrives, so a booking that lands AFTER the scout leaves the show on that night
    // unflagged, on the Prep work-list, and sendable, until the next scout happens to run. reconcileBookings
    // above already reads the export on the same trigger (launch, timer, export-change); this closes the
    // other half on that same trigger. ConflictSweep is pure, tested, and idempotent, and preserves any
    // clearance Dan already made (setScoutConflict compares against the key he cleared).
    func reapplyConflicts(now: Date, from url: URL = DownbeatBridge.defaultURL) {
        let loaded = DownbeatBridge.loadWithHealth(from: url, now: now)
        ConflictSweep.reapplyAll(export: (loaded.bookings, loaded.blockedDates), in: context)
    }

    // Mark prospects Booked from the Downbeat export. No-op when the export is absent or unchanged.
    // #499: saveFailed reports a persistence failure back to the caller so it can surface via
    // #1456: record whether Downbeat's feed is still moving. A booking id never seen before, dated today or
    // later, resets the dry-spell clock the Days off mark reads; nothing new for four weeks lights the mark.
    // Best-effort telemetry in UserDefaults, never fails the tick. `from`/`into` are injectable so a test can
    // drive it against a fixture export and a scratch defaults suite.
    func observeFeedFreshness(now: Date, from url: URL = DownbeatBridge.defaultURL,
                              into defaults: UserDefaults = .standard) {
        let loaded = DownbeatBridge.loadWithHealth(from: url, now: now)
        DownbeatFeedFreshnessStore.record(bookings: loaded.bookings,
                                          today: QueueModel.easternToday(), now: now, into: defaults)
    }

    // ReconcileSummary instead of failing silently. #617: `from` mirrors DownbeatBridge.loadWithHealth's
    // own injectable URL, so a test can drive a real booking match without touching Dan's real export.
    @discardableResult
    func reconcileBookings(now: Date, from url: URL = DownbeatBridge.defaultURL) -> (count: Int, saveFailed: Bool) {
        let loaded = DownbeatBridge.loadWithHealth(from: url, now: now)
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let n = DownbeatBooking.reconcileBooked(prospects: all, clients: loaded.clients,
                                                bookings: loaded.bookings, health: loaded.health, now: now)
        guard n > 0 else { return (0, false) }
        do {
            try context.save()
            return (n, false)
        } catch {
            return (n, true)
        }
    }

    // Push due conversation reminders into OmniFocus and record the result so a failure stays visible
    // (#239). Synchronous on the main actor (AppleScript requires it); the caller awaits the whole tick
    // so the Apple events complete rather than racing teardown (unlike the old fire-and-forget).
    @discardableResult
    func syncOmniFocus(now: Date, client: OmniFocusClient, horizonDays: Int,
                       permission: AutomationAuthorization = OmniFocusAutomationPermission.current(),
                       notifier: OmniFocusNotifier = OmniFocusUserNotifier(),
                       statusDefaults: UserDefaults = .standard) -> Int {
        // #268: gate on a SILENT Automation pre-check. If OmniFocus isn't already grantable, the runner
        // skips the AppleScript (so this windowless process can't post a TCC modal into the void) and
        // notifies once; otherwise it applies and records success/failure. AppleScript stays synchronous
        // on this main actor, awaited by the caller, so the write completes before the tick returns.
        // Returns the number of OmniFocus tasks changed, for the manual-reconcile acknowledgment (#285).
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let desired = OmniFocusSync.desired(from: all, now: now, horizonDays: horizonDays)
        return OmniFocusSyncRunner.run(desired: desired, permission: permission, client: client,
                                       notifier: notifier, now: now, defaults: statusDefaults)
    }

    // Last-modified time of the Downbeat export, to gate the live re-reconcile (#197) so a spurious
    // filesystem event on an unchanged file doesn't trigger redundant work.
    static func exportModifiedAt() -> Date? {
        (try? DownbeatBridge.defaultURL
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
    }
}
