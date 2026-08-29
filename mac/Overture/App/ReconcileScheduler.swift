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

    // #2966/#2878: whether the reply-classify run is alive at a given instant, INJECTED rather than
    // read here, because the only symbol that can answer it is one of the paid-run launchers and this
    // file must never so much as name one, even in a comment: ReconcileNoSpendGuardTests matches the
    // file's whole text (#237/#1098). Reading the run's marker file is free, but that guard is
    // deliberately coarser than the free/paid distinction. AppDelegate supplies the real closure.
    // No default (L168): a default standing for "no run is alive" would silently report a live drafting
    // run as a dead one (#471) on the Dock tile and menu bar, a wrong badge instead of a compile error.
    private let replyRunAlive: (Date) -> Bool

    init(context: ModelContext, replyRunAlive: @escaping (Date) -> Bool) {
        self.context = context
        self.replyRunAlive = replyRunAlive
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
    // #2091: nonisolated (it only reads a default) so the watch-gap window can be derived from the real
    // cadence off the main actor, per L51: the staleness threshold must come from the schedule that
    // computes it rather than be guessed beside it.
    nonisolated static let intervalKey = "reconcileIntervalMinutes"
    nonisolated static func intervalSeconds(defaults: UserDefaults = .standard) -> Double {
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

    // #2091: `defaults` and the watch readings are injected (both defaulting to the real ones) so the
    // watch heartbeat this tick writes can be driven against a scratch suite and a fake Mac, and so the
    // existing lastReconcileAt write stops landing in the real defaults during a test run too.
    // #2220: one set of readings for the whole tick, taken once. Read twice, the observe and the stamp
    // could straddle a wake and disagree about how much sleep this tick sat on top of.
    @discardableResult
    // #2679: the threading repair is injected, defaulting to the real one, for the same reason
    // `retireShowsThatOpened(save:)` takes its save: without a seam its `saveFailed` cannot be driven from
    // a test, and a fold nothing can exercise is indistinguishable from no fold at all (L3).
    func runSafeReconcilesOnce(now: Date = Date(), defaults: UserDefaults = .standard,
                               watchReadings: WatchGap.Readings? = nil,
                               repairThreading: @MainActor (ModelContext) async -> GmailThreadingRepair.Outcome? = {
                                   await GmailThreadingRepair().repair(in: $0)
                               })
        async -> ReconcileSummary {
        let readings = watchReadings ?? WatchHeartbeatStore.readings(now: now, defaults: defaults)
        // #2091: note a silence this tick is resuming after, BEFORE the stamp at the end hides it. Why
        // that ordering is the whole design, and why it lives here rather than in start(), is in WatchGap.
        WatchHeartbeatStore.observeResume(
            now: now, readings: readings,
            intervalSeconds: ReconcileScheduler.intervalSeconds(defaults: defaults), into: defaults)
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
        // #1566: retire the shows that opened since the last tick, so the queue stops offering a run Dan
        // will not pitch just because the app has not been relaunched since it opened.
        let retirement = retireShowsThatOpened(now: now)
        // Reply detection: gated on a live Gmail connection inside checkReplies; best-effort.
        // #2741: the whole outcome, not a Bool that meant "a save failed" and was shared by three other
        // states. `everyThreadUnreadable` is the one that reaches Dan, and only on the rate.
        let replyCheck = await GmailReplyChecker().checkReplies(in: context)
        let replyCheckSaveFailed = replyCheck.saveFailed
        // #2649: repair the stored Message-ID on conversations that are still live, where Overture wrote
        // the id it minted and Gmail discarded (#2647 fixed this from the next send onward and could not
        // touch what was already stored). Rides this same free tick for the same reasons the two Gmail
        // calls around it do: it is read only, it is gated on the connection inside itself, and it spends
        // no paid AI run. It selects only rows still holding a minted id, so it empties itself after one
        // effective pass rather than re-reading Gmail on every tick forever.
        // #2679: its answer is READ, not discarded. `saveFailed` is the one that matters: the repair
        // rewrites a stored Message-ID, and when the save then fails nothing persisted and nothing said
        // so, while the pass looked like it ran. That is success over a write that did not commit (L12)
        // inside a background job whose failure reached nothing that could report it (L13).
        //
        // Folded into the SAME flag the reply checker's failure uses two lines above, rather than given a
        // second path: both mean "this tick could not write what it found", Dan needs one sentence either
        // way, and #1912 owns telling him when Gmail access itself has died.
        //
        // nil is not a failure. It means Gmail is not connected, so no repair was attempted at all, and
        // reporting that as a save failure would wake Dan for a tick that did nothing wrong (L98 from the
        // other side: an empty result is not a bad one).
        //
        // `refused` and `unreadable` deliberately get no surface of their own, decided rather than
        // overlooked. A refusal already marks its rows `threadingDegraded`, which has a reader in the
        // `.sendThreadingDegraded` focus, so a conversation that cannot thread reaches Dan where he can
        // act on it (L80). An unreadable thread says Gmail could not be read this tick, which the next
        // free tick retries and which #1912 is the right home for; a count of it here would be a number
        // with no action attached.
        let threadingRepair = await repairThreading(context)
        // #2718: read the mailbox for a reply to a pitch Overture cannot watch, rank what it finds, and
        // store at most one question per contact. Rides this same free tick for the reasons the two Gmail
        // calls above do: it is read only, it is gated on the connection inside itself, and it spends no
        // paid AI run. It is self limiting in three ways rather than one (a 30 day horizon per pitch, a
        // high-water mark on the mailbox, and a per-tick message cap), because a sent pitch never ages off
        // until Dan closes it out.
        //
        // Its failure gets its OWN field on the summary rather than the shared `saveFailed`: that flag's
        // message is about a save, and a Gmail READ that failed is a different fact (L11, L53).
        let proposals = await sweepReplyProposals(context, now)
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
        defaults.set(now.timeIntervalSince1970, forKey: ReconcileScheduler.lastReconcileKey)
        // #2115: the count Dan sees on the Dock and beside the menu bar glyph. Published from here
        // because this tick already holds every prospect fetched and already writes to defaults, and
        // because neither surface that draws it can hold a SwiftData query of its own. Same predicate as
        // the toolbar's Due badge, so the three can never state different numbers.
        DueBadge.publish(DueWork.counts(prospects: after, now: now,
                                        replyRunAlive: replyRunAlive(now)).total,
                         into: defaults)
        // #2091: the watch heartbeat, carrying the observed sleep alongside the wall clock so the next
        // tick can tell a sleeping Mac (nothing missed) from a dead process (everything missed).
        WatchHeartbeatStore.stamp(now: now, readings: readings, into: defaults)
        return ReconcileSummary(omniFocusChanged: omniFocusChanged,
                                newReplies: newReplies, newBookings: newBookings,
                                newReplyKeys: newReplyKeys, newBookingKeys: newBookingKeys,
                                saveFailed: bookingResult.saveFailed || replyCheckSaveFailed
                                    || retirement.saveFailed                       // #1566
                                    || threadingRepair?.saveFailed == true         // #2679
                                    || proposals.saveFailed,                       // #2718
                                replySearchFailure: proposals.failure,             // #2718
                                replyWatchUnreadable: replyCheck.everyThreadUnreadable,  // #2741
                                inquiryThreadsUnreadable: proposals.inquiryThreadsUnreadable,  // #2798
                                inquiryGmailNotConnected: proposals.inquiryNotConnected,       // #2798
                                replyWatchNotConnected: replyCheck.notConnected,               // #1912
                                replyWatchTokenExpired: replyCheck.tokenRefreshFailed)         // #1912
    }

    // #2718: the mailbox sweep, in its own function so the scheduler body stays readable and so a test can
    // drive the tick without it. Returns the two facts the summary needs and nothing else: `.notConnected`
    // and `.nothingInScope` are not failures and must not wake Dan for a tick that did nothing wrong (the
    // same reading the threading repair's nil gets, two calls above).
    // #2798: it also returns the two facts the INQUIRY half of that sweep establishes, which had no
    // reader at all before. Both are about a tick that could not read Gmail for the conversations a hire
    // inquiry is on, and neither is "nothing arrived", so neither may be swallowed by the same silence.
    func sweepReplyProposals(_ context: ModelContext, _ now: Date,
                             sweep: @MainActor (ModelContext, Date) async -> ReplyProposalSweep.Outcome = {
                                 await ReplyProposalSweep().run(in: $0, now: $1)
                             }) async -> (saveFailed: Bool, failure: String?,
                                          inquiryThreadsUnreadable: Bool, inquiryNotConnected: Bool) {
        switch await sweep(context, now) {
        case .notConnected, .nothingInScope: return (false, nil, false, false)
        case .failed(let reason): return (false, reason, false, false)
        case .swept(_, _, let saveFailed, let threadsUnreadable, let notConnected):
            return (saveFailed, nil, threadsUnreadable, notConnected)
        }
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
        // #2692: clear the cancellations whose booking Downbeat no longer exports, BEFORE the sweep below
        // reads the calendar, so a night freed by a row that no longer stands for anything is re-blocked
        // on the same tick rather than on the next one.
        //
        // Hygiene rather than a correctness guard, and the difference is worth keeping straight: a booking
        // id is Downbeat's own, so a row left behind cannot suppress a FUTURE booking landing on the same
        // date, because that booking carries a different id. What it would otherwise do is sit in the
        // store forever as a rule nobody can see. `sweep` refuses an empty booking list outright, so an
        // export that failed to load cannot be read as "Downbeat dropped everything" and take every one of
        // Dan's cancellations with it (L214).
        CancelledShootEditing.sweep(against: loaded.bookings, in: context)
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
        // #2478: and what this export CARRIED, which is the only way anything can later notice it stop
        // carrying. Recorded on the same read as the stall clock above, but into its own keys with its own
        // verdict: "nothing new for four weeks" and "everything gone at once" are different questions and
        // must not share an answer (L53).
        DownbeatBookingFeedStore.record(clientCount: loaded.clients.count, bookings: loaded.bookings,
                                        today: QueueModel.easternToday(), now: now, into: defaults)
    }

    // ReconcileSummary instead of failing silently. #617: `from` mirrors DownbeatBridge.loadWithHealth's
    // own injectable URL, so a test can drive a real booking match without touching Dan's real export.
    @discardableResult
    func reconcileBookings(now: Date, from url: URL = DownbeatBridge.defaultURL) -> (count: Int, saveFailed: Bool) {
        let loaded = DownbeatBridge.loadWithHealth(from: url, now: now)
        // #1434/#1435: one generic reconcile pass over prospects AND inquiries, so a booking is
        // consumed once across both types. Inquiries are suggestion-only but claim a booking to win the
        // tie-break. `try?` yields none on a container predating Inquiry.
        // The prospects are fetched here rather than inside the call below because the contact-score
        // settle further down needs them whatever the export's health says.
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        // #1960: the inquiries and the boxing are built INSIDE the call, so an unhealthy export refuses
        // before paying for them.
        let n = DownbeatBooking.reconcileBooked(
            entities: DownbeatBooking.bookingEntities(prospects: prospects, in: context),
            clients: loaded.clients, bookings: loaded.bookings, health: loaded.health, now: now)
        // #1648: the periodic half of the contact adjustment. An answer past its 90 day expiry has to
        // give the show its score back, and this pass is where that happens: it already runs on a
        // schedule with a context and a save, whereas the queue rebuild (where the plan originally put
        // it) is a pure display calculation running inside view drawing, with no ability to save.
        // A row therefore self-corrects while the app is open rather than only after a relaunch.
        let lifted = ContactScoreAdjustment.settleAll(prospects, now: now)
        guard n > 0 || lifted > 0 else { return (0, false) }
        do {
            try context.save()
            return (n, false)
        } catch {
            return (n, true)
        }
    }

    // #1566: retire the untriaged shows that have opened since the last tick.
    //
    // #864 put this at launch, which was enough while the line fell on a run's CLOSING night. #1540 moved
    // it to the OPENING night, a line every show in the queue crosses on its own opening day, so these
    // rows are now minted by the calendar turning over rather than by a show finishing. Dan leaves
    // Overture open for days, so launch-only left a run he has said he will not pitch sitting in triage
    // until he next relaunched. Same trigger family as the booking pass and the conflict re-check above:
    // launch, the 30-minute timer, and every export change.
    //
    // Judged against the tick's own `now`, like every other pass here, and it reports a save failure
    // instead of swallowing it (#499): a retirement that never reached disk would come straight back.
    //
    // `save` is injected purely so that failure path is reachable from a test. A SwiftData in-memory
    // container cannot be made to fail its save on demand, so without this seam the do/catch would be
    // asserted only by reading it, which is how #499's silent `try?` survived in the first place.
    @discardableResult
    func retireShowsThatOpened(now: Date, save: (() throws -> Void)? = nil) -> (count: Int, saveFailed: Bool) {
        let n = WentByRetirement.run(in: context, today: QueueModel.easternToday(now))
        guard n > 0 else { return (0, false) }
        do {
            if let save { try save() } else { try context.save() }
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
        let changed = OmniFocusSyncRunner.run(desired: desired, permission: permission, client: client,
                                              notifier: notifier, now: now, defaults: statusDefaults,
                                              // #2899: carry back what Dan ticked off in OmniFocus. Passed
                                              // as a closure because the runner is pure over value types
                                              // and the model lives here, on the main actor.
                                              recordCompletions: { handled in
                                                  OmniFocusSync.recordCompletions(handled, in: all, now: now)
                                              })
        if changed.stamped > 0 { try? context.save() }
        return changed.tasks
    }

    // Last-modified time of the Downbeat export, to gate the live re-reconcile (#197) so a spurious
    // filesystem event on an unchanged file doesn't trigger redundant work.
    static func exportModifiedAt() -> Date? {
        // #2105: the shared read. This gates the live re-reconcile, so a cached reading would mean an
        // export that HAS changed reads as unchanged and the reconcile silently does not run.
        FileTimestamp.modifiedAt(DownbeatBridge.defaultURL)
    }
}
