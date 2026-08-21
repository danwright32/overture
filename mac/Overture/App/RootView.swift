import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @State private var isScanning = false
    @State private var scoutStartedAt: Date?   // when the current scan began, for the live elapsed counter (#435)
    // #799: shared with the menu-bar command (OvertureApp), because a toolbar-menu shortcut never
    // registers with the system and the keyboard route has to work.
    @Environment(AddLeadPresenter.self) private var addLead
    @AppStorage("autoScoutEnabled") private var autoScoutEnabled = true
    // #1047: the center status slot enforces its own precedence, so a routine informational write
    // (a Prep summary, an OmniFocus receipt, a reply-classify note) cannot silently erase an unattended
    // scout's warning that landed first on the same launch. Every writer below goes through status.set.
    @State private var status = StatusLine()
    // #346: the scout outcome ("N found · N unsure", or a failure status) gets its own state so
    // it can render next to the Scout control instead of the unrelated center status slot.
    @State private var scoutSummary: String?
    @State private var errorMessage: String?
    // #285: the shared acknowledgment surface for this window and its sheets, so a control whose
    // effect isn't otherwise visible still shows it ran.
    @State private var feedback = ActionFeedback()
    @State private var dayOffOffer = DayOffOfferRequest()   // #924: dismiss-to-day-off picker request
    // #1414: owned by the App (a .commands block cannot read view state) and injected down to here.
    @Environment(QueueUndoStack.self) private var undoStack
    // #2365: which watched calendars are a past client's, so a far-out client show routes to the Queue
    // rather than the Archive. Optional for the same reason undoStack is: a missing injection must not
    // fatal-error the whole app or every test that builds this view.
    @Environment(ClientRoster.self) private var clientRoster: ClientRoster?
    @Environment(QueueUndoRequest.self) private var undoRequest
    // #1770: the one cached answer, observed rather than snapshotted. As @State it was read from disk
    // once at init and then only ever set to true on a successful connect, so a revoked credential left
    // this reading connected until relaunch. GmailConnection is @Observable, so this re-renders whenever
    // something refreshes it (a connect, a failed send, the periodic reply check).
    private var gmailConnected: Bool { GmailConnection.shared.isConnected }
    @State private var isConnectingGmail = false
    @State private var gmailConnectStartedAt: Date?   // for the live elapsed counter + stuck timeout (#436)
    // #1163: a Gmail-connect failure gets its OWN alert (not the shared "Something went wrong" one) so it
    // can offer a one-click Try again, since a failed handoff is the one connect error Dan recovers from by
    // simply retrying.
    @State private var gmailConnectError: String?
    // #1027: the finished scout's warnings, as one branded popup shown ONCE at the true end of a manual
    // run. Replaces the plain warningMessage alert that fired after the native sweep, before the read.
    @State private var scoutWarnings: ScoutWarnings?
    // #1034: the takeover progress modal, shown while a scout Dan STARTED runs (never the scheduled
    // watch-only run, which keeps its quiet toolbar label). One presented sheet carries the whole run:
    // it shows RunProgressView while scoutWarnings is nil, then swaps to #1027's ScoutSummaryView once
    // the run finishes with something to say, so the takeover becomes the results without a dismiss/
    // re-present flicker between two sheets.
    @State private var scoutIsManual = false          // this run is one Dan started (drives the modal)
    // #2202: the one way to raise something Dan has to answer. macOS presents an alert and a sheet the
    // same way, so an alert raised while any of the sheets below is up queues behind it and is never
    // seen. Every raise goes through here, and raising closes what is presented first. See AppModals.
    @State private var modals = AppModals()
    @State private var scoutSheetShown = false        // the sheet is presented (vs hidden while it runs)
    @State private var scoutNativeSnapshot: RunProgressView.Snapshot?   // latest native-phase heartbeat
    // Supersedes an abandoned run's completion after a stalled-state Retry, so the old Task cannot
    // clobber the fresh run's state when it finally returns (CLAUDE.md: assume it runs twice).
    @State private var scoutGeneration = 0
    @State private var scoutTask: Task<Void, Never>?
    // #1037: Dan asked to stop this run. The native sweep reads it between sources; the detached read is
    // stopped via a cancel file the runner checks; and finishScout reads it to close quietly instead of
    // popping a summary for a run he chose to abandon.
    @State private var scoutCancelRequested = false
    // #1498: the pending "read all of them, or 20 now?" question, non-nil only while the sweep is
    // suspended waiting for Dan. The one-shot answer lives on ScoutReadAsk, so no route out of this alert
    // can leave the run waiting forever or answer it twice.
    @State private var scoutReadAsk: ScoutReadAsk? = nil
    // #1054: non-nil while the keep-or-discard prompt is up, holding the count of shows a cancelled read
    // wrote before it stopped. Its partial results file is NOT imported until Dan answers.
    @State private var cancelledScoutRead: Int?
    // #239: reactively reflect a failed OmniFocus sync in the masthead (0 = no failure on record).
    @AppStorage(OmniFocusSyncStatus.failedAtKey) private var omniFocusFailedAt: Double = 0
    // #2884: the stored reason and the permission flag, read reactively beside the timestamp, so the
    // masthead can say WHY rather than only THAT. Both were already on disk and reachable only from a
    // terminal.
    @AppStorage(OmniFocusSyncStatus.errorKey) private var omniFocusLastError: String = ""
    @AppStorage(OmniFocusSyncStatus.permissionNeededKey) private var omniFocusPermissionNeeded: Bool = false
    // #469: when the current sync began (nil = not syncing), for the live "Syncing… m:ss" state,
    // consistent with scout/prep/connect/send.
    @State private var omniFocusSyncStartedAt: Date?
    // #355: the SAME key ReminderSettingsView binds, so toggling from either surface stays in sync.
    @AppStorage(OmniFocusSyncConfig.Keys.enabled) private var omniFocusEnabled = OmniFocusSyncConfig().enabled
    // #236: the natural key of a lead opened from an OmniFocus deep link, handed to the queue to
    // select and scroll to. Cleared by the queue once it has acted on it.
    @State private var deepLinkedKey: String?
    // #308: the natural keys of the new leads from a tapped multi-lead away alert, handed to the queue
    // to filter down to exactly them. Cleared by the queue once it has acted on it.
    @State private var deepLinkedKeys: [String]?

    // Kept prospects with no draft yet: what a Prep run would work on.
    // #367: shares PrepQueueBuilder.needsPrepPredicate rather than an inline #Predicate literal,
    // so this gate for enabling "Prep kept" stays in lockstep with every other eligibility check
    // (a #Predicate macro can't call the plain-Swift needsPrep function the other checks use, so
    // this is the one place the SAME logic has to be expressed a second way; see
    // PrepQueueEligibilityParityTests for the guard against the two drifting apart).
    @Query(filter: PrepQueueBuilder.needsPrepPredicate)
    private var toPrep: [Prospect]

    // All prospects, for the time-based follow-up due count (#45).
    @Query private var allProspects: [Prospect]
    // #805: the live store, not a snapshot taken when the window opened. A source that degrades DURING a
    // scout must light the badge on that scout, not on the next launch.
    @Query private var watchedSources: [WatchedSource]
    // #1570: Dan's town refusals and un-skipped seed towns, read here for the same reason QueueView
    // reads them: the routing below decides whether a show opens the Queue, and it can only answer that
    // correctly if it applies the same geography gate the Queue's own lists do.
    @Query private var excludedTownRows: [ExcludedTown]
    @Query private var allowedSeedTownRows: [AllowedSeedTown]
    private var geo: GeoRefusals {
        GeoRefusals(userExcludedTowns: Set(excludedTownRows.map(\.town)),
                    allowedSeedTowns: Set(allowedSeedTownRows.map(\.town)))
    }
    // #2365: an absent roster answers "no client information", which holds every show to the ordinary 90
    // days. That is the wrong answer rather than a safe one, so it can only arise from a missing
    // injection, never from a call site forgetting to pass it: `StageContext` requires the argument.
    private var clientWindow: ClientWindow {
        clientRoster?.window(for: watchedSources) ?? .none
    }
    @State private var showArchive = false
    @State private var archiveJumpKey: String?
    // #685: which contact on the jumped-to show to highlight (nil when the jump only identifies
    // the show, e.g. a plain search pick or the toolbar Archive button).
    @State private var archiveJumpRecipientId: String?
    // #1580: the query Archive opens already searching, carried over from a queue search that found
    // nothing so Dan does not retype it. Empty every other way Archive opens.
    @State private var archiveOpeningQuery: String = ""
    // #1926: what Dan has typed into the search bar is NOT state here. It lives on QueueSearchBar, because
    // @State invalidates the view that declares it and this view builds the Queue: as state here, every
    // keystroke re-derived all 724 prospects. See QueueSearchBar.
    @State private var showPatterns = false
    @State private var showFollowUps = false
    // #682: the recipient Dan clicked "Send a follow-up" from on the Reached Out row, handed to
    // FollowUpsView so it opens with that same entry highlighted instead of a plain list.
    @State private var showVoiceGuidance = false
    // #1435/#1436: the "Log an inquiry" intake sheet, opened from the same grouped menu as "Add a lead".
    @State private var showInquiryIntake = false
    @State private var showPrepSelection = false   // #953: the per-run "which kept shows to prep" picker
    // #1130: the detached run's takeover progress screen, and #1824's in-app listing-page read that runs
    // before the run launches. #2760: PER SLOT, in one value, because these were three single `@State`
    // values shared by both launches: the first run to finish dismissed the takeover out from under the
    // second, and one launch's `defer` wiped the other's live listing count while it was still advancing.
    // The rules live in RunTakeover, where a test can reach them (#863).
    @State private var takeover = RunTakeover()
    @State private var showSources = false
    @State private var showDaysOff = false      // #901
    @State private var showExcludedTowns = false   // #1118: review and un-exclude skipped towns
    @State private var showOrganisations = false   // #1731: what Overture reads as a building
    @State private var showOmniFocusSettings = false   // #931 rehome, #2397 trimmed to the sync window
    // #803: when the DETACHED reading half began, so it has a visible working / still-alive / stalled
    // state of its own. It had none: runScout returned, the spinner went out, and Overture then sat
    // reading calendars for minutes with nothing on screen at all, and nothing to say if that run hung.
    // CLAUDE.md's rule is binding, and this was a straight violation of it.
    @State private var readingStartedAt: Date?
    // #1427: how many sources THIS reading run set out to read, captured when the read begins, so a normal
    // completion can record {sources, elapsed} for the "~X remaining" pace. Kept alongside readingStartedAt
    // because both describe the same run.
    @State private var readingSourceCount = 0

    // #885: one definition of "due", shared with the sheet this badge opens (DueWork). Summed here in
    // the body before, and summed again in FollowUpsView's own body: the pill Dan clicks and the list he
    // lands on stated the same rule twice, with nothing asserting they agreed.
    private var followUpsDue: Int {
        let now = Date()
        // #2878: the badge counts a stalled reply draft too, because the sheet it opens now lists one.
        // The liveness is read here rather than defaulted, so a classify run still beating is not
        // reported as a dead one (#471, L168).
        return DueWork.counts(prospects: allProspects, now: now,
                              replyRunAlive: ReplyClassifyService.isRunning(now: now)).total
    }

    // #805: how many watched sources need Dan's eyes. Counted by SourceAttention and never summed here, for
    // the same reason as the Due pill above: the number on the button and the rows in the sheet it opens
    // must be one rule, not two that happen to agree.
    private var sourcesNeedingALook: Int { SourceAttention.count(watchedSources) }

    // #901: Overture knows of no upcoming shoot, so the only days it can keep clear of are the ones Dan
    // types in himself. Asked of DaysOffAttention, never decided here, so the toolbar and the sheet it
    // opens cannot come to different answers.
    //
    // #925: the snooze is bound rather than merely read, so dismissing it in the sheet clears the mark on
    // this toolbar immediately instead of on the next launch.
    @AppStorage(DaysOffAttention.snoozeKey) private var daysOffSnoozedUntil: Double = 0
    // #1456: the timestamp of the last genuinely-new upcoming booking, read reactively so the mark updates
    // as the reconcile tick advances it.
    @AppStorage(DownbeatFeedFreshnessStore.lastNewAtKey) private var feedLastNewAt: Double = 0

    // #2478: the four facts the reconcile tick records about Downbeat's export, read reactively so the
    // masthead's verdict changes the moment a tick (or the notice's own Check again) rewrites them. The
    // FACTS are stored and the verdict is derived here on every read, rather than the verdict being
    // stored: that way the line retires itself the day the last vanished shoot's date passes, without
    // anything having to run to clear it.
    @AppStorage(DownbeatBookingFeedStore.clientCountKey) private var feedClientCount = 0
    @AppStorage(DownbeatBookingFeedStore.upcomingBookingCountKey) private var feedUpcomingBookings = 0
    @AppStorage(DownbeatBookingFeedStore.lastCarriedCountKey) private var feedLastCarriedCount = 0
    @AppStorage(DownbeatBookingFeedStore.lastCarriedEndDateKey) private var feedLastCarriedEndDate = ""
    @AppStorage(DownbeatBookingFeedStore.lastCarriedAtKey) private var feedLastCarriedAt: Double = 0

    private var bookingsVanished: DownbeatBookingFeed.Vanished? {
        let now = Date()
        return DownbeatBookingFeed.vanished(clientCount: feedClientCount,
                                            upcomingBookingCount: feedUpcomingBookings,
                                            lastCarriedCount: feedLastCarriedCount,
                                            lastCarriedEndDate: feedLastCarriedEndDate,
                                            lastCarriedAt: feedLastCarriedAt,
                                            today: QueueModel.easternToday(now), now: now)
    }

    // #1900: whether Dan's shoot history file is there, readable, and recent enough to be worth drafting
    // from. Held rather than derived on every read, because answering it decodes a JSON file, and this
    // view is on the render path (the reason ClientRoster exists, and the reason #1960 had to stop the
    // days-off mark being worked out three times to draw one button). nil until something has actually
    // looked, so the masthead says nothing rather than vouching for a file nobody has opened.
    @State private var shootHistoryHealth: ShootHistory.Health?

    // #2879: the handoff files Overture currently cannot read. Held as state and refreshed on a tick,
    // following this view's existing convention (StatusLine is a plain value in @State too) rather than
    // reading the register inside `body`, which would register no dependency on it and leave the line
    // frozen at whatever was true when the masthead last drew for some other reason.
    @State private var unreadableFiles: [HandoffReadFailures.Failure] = []

    // Reads an in-memory dictionary under a lock, no filesystem and no derivation, and assigns only on a
    // real change so an app with nothing wrong redraws nothing (#1774: an idle surface must pay nothing).
    private func refreshUnreadableFiles() {
        let current = HandoffReadFailures.shared.current()
        if current != unreadableFiles { unreadableFiles = current }
    }

    // The ONE place the file is read for this line, so the launch load and the notice's own re-read
    // cannot reach different verdicts about the same file.
    // Returns what it read as well as storing it, so the caller that has to ANSWER the read never has
    // to re-derive it from the state (or invent a fallback for an optional that cannot be empty here).
    @discardableResult
    private func readShootHistoryHealth() -> ShootHistory.Health {
        let health = ShootHistory.loadWithHealth(now: Date()).health
        shootHistoryHealth = health
        return health
    }

    // #1900: the same read, ANSWERED, for the press Dan makes after running the import himself.
    // Silence would be wrong here in the one case that matters: an import that did not take leaves the
    // verdict unchanged and the masthead line exactly where it was, so a control that worked and one
    // that never registered look identical (L12). The launch load stays silent for the opposite reason:
    // nobody asked it anything.
    private func rereadShootHistoryHealth() {
        let answer = ActionAck.shootHistoryReread(readShootHistoryHealth())
        feedback.acknowledge(answer.text, tone: answer.resolved ? .info : .warning)
    }

    private var daysOffReason: DaysOffAttention.Reason {
        DaysOffAttention.reason(
            ScoutService.blockedCalendar(export: DownbeatBridge.loadedExport(), context: context),
            feedStalled: DownbeatFeedFreshness.isStalled(lastNewAt: feedLastNewAt, now: Date()))
    }

    // #1960: the mark is worked out ONCE and handed down. Drawing this button needs the same answer three
    // times (the title, the ink, the hover), and each read of daysOffReason decodes the Downbeat export
    // and fetches the stored days off, so three reads is three of each, on every render of this window.
    private func daysOffButton(_ reason: DaysOffAttention.Reason) -> some View {
        Button {
            showDaysOff = true
        } label: {
            ToolbarHoverLabel(title: DaysOffAttention.badgeTitle(reason),
                              systemImage: "calendar.badge.clock")
                .foregroundStyle(reason != .none ? OVColor.inkSoft : Color.primary)
        }
        .help(DaysOffAttention.help(reason))
    }

    private var nonDismissedProspects: [Prospect] { allProspects.filter { $0.status != .dismissed } }

    private var reachedOutKeys: Set<String> {
        Set(ReachedOutQueue.active(from: nonDismissedProspects, now: Date()).map(\.prospect.naturalKey))
    }

    // Every show Overture has ever tracked. Not what the search bar above the Queue offers (see
    // searchableItems); it is what Archive holds, counted so an empty search can say the show is there.
    private var allItems: [QueueItem] { allProspects.map(QueueItem.init) }

    // #1580: what the persistent bar above the Queue can find, which is exactly the shows a stage will
    // render. Dan asked for the split: "search should only allow me to search for shows in the queue.
    // Archive can have its own search." It used to be every prospect the store held, dismissed ones
    // included, so roughly half of what it surfaced took him out of the Queue the moment he picked it.
    //
    // Scoped by StageNavigation.stagedKeys, the same predicate the stage lists render from, so a pick
    // can only ever land on a row he can see.
    private var searchableItems: [QueueItem] {
        let scope = StageNavigation.stagedKeys(in: nonDismissedProspects, reachedOutKeys: reachedOutKeys,
                                               context: StageContext(geo: geo, clients: clientWindow))
        return allItems.filter { scope.contains($0.id) }
    }

    // Whether a deep-linked show (an OmniFocus follow-up tap, #628, or a search pick) should jump into
    // the Queue (#236's existing deep link mechanism) or open Archive with that row forced into view
    // instead. A show no stage will render never appears in the Queue, so it routes to Archive rather
    // than silently landing nowhere.
    //
    // #1567: asked through StageNavigation, the same predicate the focused list renders from, rather
    // than a second date filter of its own. A show Dan can SEE in his Scout list is now always
    // reachable, and a show no stage renders never opens the Queue on an empty list.
    //
    // #1580: one copy, not two. A search pick is now always in scope and so always takes the Queue
    // branch, but the Archive branch stays for the follow-up taps, which can name a closed show.
    private func routeDeepLink(toKey key: String) {
        if StageNavigation.opensInQueue(key: key, in: nonDismissedProspects,
                                        reachedOutKeys: reachedOutKeys,
                                        context: StageContext(geo: geo, clients: clientWindow)) {
            deepLinkedKey = key
        } else {
            openArchive(key: key)
        }
    }

    // #1580: every way Archive opens, in one place. Five callers each set the same three pieces of
    // state by hand before, which was survivable while they all cleared them; adding a fourth piece
    // (the opening query) to five call sites is how one of them ends up carrying a stale one.
    // Defaulted, so "open Archive" with nothing to say clears all three.
    private func openArchive(key: String? = nil, recipientId: String? = nil, query: String = "") {
        archiveJumpKey = key
        archiveJumpRecipientId = recipientId
        archiveOpeningQuery = query
        showArchive = true
    }

    // #2546: why "Prep kept" is refusing, from the same call that decides whether it is. The rule moved
    // to PrepStartGate so it is reachable from a test at all (#863); this reads it twice, for the
    // sentence in the menu and for the item's disabled state, and both are the same answer (L109).
    private var prepRefusal: String? {
        // #3015: the PREP slot's own question. It used to ask the whole-app one, which refuses for ANY
        // live run, so a check going meant the menu item was disabled and Cmd+P refused. That is one of
        // the four gates that had to lift together: lifting only the throw would have shipped the feature
        // invisible, with the control still greyed out.
        PrepStartGate.reason(keptToPrep: toPrep.count,
                             ownSlotRunInFlight: PrepQueueService.runInFlight(slot: .prep, now: Date()))
    }

    // #367/#733: shares ProspectMutations.bulkReprepEligible with bulkReprep itself, so the
    // menu's disabled state always agrees with what a tap would actually do.
    private var eligibleForBulkReprep: [Prospect] {
        ProspectMutations.bulkReprepEligible(allProspects, now: Date())
    }

    private func bulkReprep(_ mode: ReprepMode) {
        ProspectMutations.bulkReprep(mode, prospects: allProspects, context: context, feedback: feedback)
    }

    // #355: glanceable freshness, reusing the same coarse relative-time formatter PrepStatus and
    // ScoutStatus already use in the masthead rather than introducing a second one.
    private var omniFocusStatusLine: String {
        OmniFocusSyncStatus.line(lastSuccessAt: OmniFocusSyncStatus.lastSuccessAt(), now: Date())
    }

    #if DEBUG
    // #1930: what THIS screen renders from, in the same shape the queue's own fingerprint uses, so a queue
    // derivation reporting "nothing this view reads" can be read against the render above it and told which
    // of these moved.
    //
    // This screen builds the queue, so every render here rebuilds QueueView and pays a whole-store
    // derivation. The first reading (2026-08-01) was a launch burst of five derivations, four of them
    // reporting "nothing this view reads", which means the invalidation arrives from here rather than from
    // anything the queue itself reads. Both surfaces write to one log, in the order they happened.
    //
    // Counts and small values only. Nothing here may cost a fetch or a filesystem stat, or the diagnostic
    // joins the problem it measures: the Prep and reply run markers are both stats and are deliberately
    // absent for exactly that reason, the same call the queue's fingerprint makes.
    //
    // The live objects this view holds are read through their WRITE counts (`QueueWriteTrace`), never off
    // the objects themselves, for #1922's reason: reading an @Observable property here would create a
    // dependency the body may not otherwise have, so the diagnostic would cause renders it then reported.
    // A static count depends on nothing. Until this landed they were simply missing, and every render one
    // of them triggered reported `nothing this view reads`, which is the answer this whole trace is trusted
    // for: it was blind to its own most likely cause while being read as evidence about the cause.
    //
    // The status line is different and is read directly: it is a plain Equatable STRUCT in @State, so this
    // view is already invalidated by every write to it whether the body reads it or not, and naming it
    // costs nothing.
    //
    // The two progress snapshots are read by their contents rather than by presence, because a run's
    // heartbeat replaces the whole snapshot on every tick and presence alone would report every one of
    // those ticks as nothing having moved, which is precisely the blind spot #1931 removed downstream.
    private var rootRenderInputs: [String: String] {
        [
            "toPrep": "\(toPrep.count)",
            "allProspects": "\(allProspects.count)",
            "watchedSources": "\(watchedSources.count)",
            "excludedTowns": "\(excludedTownRows.count)",
            "allowedSeedTowns": "\(allowedSeedTownRows.count)",
            "gmail": "\(GmailConnection.shared.isConnected)",
            "isConnectingGmail": "\(isConnectingGmail)",
            "gmailConnectStarted": "\(gmailConnectStartedAt != nil)",
            "gmailConnectError": "\(gmailConnectError != nil)",
            "isScanning": "\(isScanning)",
            "scoutStarted": "\(scoutStartedAt != nil)",
            "scoutSummary": "\(scoutSummary != nil)",
            "scoutWarnings": "\(scoutWarnings != nil)",
            "scoutIsManual": "\(scoutIsManual)",
            "scoutSheetShown": "\(scoutSheetShown)",
            "scoutGeneration": "\(scoutGeneration)",
            "scoutCancelRequested": "\(scoutCancelRequested)",
            "scoutReadAsk": "\(scoutReadAsk != nil)",
            "cancelledScoutRead": "\(cancelledScoutRead ?? -1)",
            "scoutSnapshot": snapshotFingerprint(scoutNativeSnapshot),
            "listingRead": snapshotFingerprint(takeover.listingProgress(.prep)),
            "listingReadStarted": "\(takeover.listingStartedAt(.prep) != nil)",
            "checkListingRead": snapshotFingerprint(takeover.listingProgress(.check)),
            "checkListingReadStarted": "\(takeover.listingStartedAt(.check) != nil)",
            "readingStarted": "\(readingStartedAt != nil)",
            "readingSourceCount": "\(readingSourceCount)",
            "prepSheetShown": "\(takeover.isShown(.prep))",
            "checkSheetShown": "\(takeover.isShown(.check))",
            "showPrepSelection": "\(showPrepSelection)",
            "autoScoutEnabled": "\(autoScoutEnabled)",
            "omniFocusEnabled": "\(omniFocusEnabled)",
            "omniFocusFailedAt": "\(omniFocusFailedAt)",
            "omniFocusSyncing": "\(omniFocusSyncStartedAt != nil)",
            "daysOffSnoozedUntil": "\(daysOffSnoozedUntil)",
            "feedLastNewAt": "\(feedLastNewAt)",
            "errorMessage": "\(errorMessage != nil)",
            "deepLinkedKey": deepLinkedKey ?? "none",
            "deepLinkedKeys": "\(deepLinkedKeys?.count ?? -1)",
            "archiveJumpKey": archiveJumpKey ?? "none",
            "archiveJumpRecipientId": archiveJumpRecipientId ?? "none",
            "archiveOpeningQuery": "\(archiveOpeningQuery.count)",
            "sheets": [showArchive, showPatterns, showFollowUps, showVoiceGuidance, showInquiryIntake,
                       showSources, showDaysOff, showExcludedTowns, showOrganisations,
                       showOmniFocusSettings].map { $0 ? "1" : "0" }.joined(),
            "status": "\(status.text?.count ?? -1)/\(status.priority)",
            "scoutTask": "\(scoutTask != nil)",
            "writes.feedback": "\(QueueRenderCounter.writes(QueueWriteTrace.feedback))",
            "writes.dayOffOffer": "\(QueueRenderCounter.writes(QueueWriteTrace.dayOffOffer))",
            "writes.undoStack": "\(QueueRenderCounter.writes(QueueWriteTrace.undoStack))",
            "writes.undoRequest": "\(QueueRenderCounter.writes(QueueWriteTrace.undoRequest))",
            "writes.addLead": "\(QueueRenderCounter.writes(QueueWriteTrace.addLead))",
        ]
    }

    // Called from the body, so it runs exactly once per render of this screen. Returns the reason purely so
    // the call site can be a `let _ =` inside the view builder.
    @discardableResult
    private func traceRootRender() -> String {
        QueueRenderCounter.recordRender(surface: QueueRenderCounter.rootSurface, inputs: rootRenderInputs)
    }

    private func snapshotFingerprint(_ s: RunProgressView.Snapshot?) -> String {
        guard let s else { return "none" }
        return "\(s.sourceName ?? "-")/\(s.completed)/\(s.total)"
    }
    #endif

    var body: some View {
        // The search bar lives here in the window body, not the toolbar: confirmed against the
        // running app that a native NSToolbar item cannot anchor a SwiftUI .popover at all (the
        // results dropdown silently never appeared), while the identical field embedded in
        // Archive's own body works correctly. This still reads as "persistent" per the design
        // (always visible above the Queue, not tucked into a menu), just not toolbar-hosted.
        VStack(spacing: 0) {
            #if DEBUG
            let _ = traceRootRender()   // #1930, see rootRenderInputs
            #endif
            // #1926: the bar owns the query, and both scopes are handed over as work to do rather than
            // work already done. Neither closure runs unless Dan is actually searching.
            QueueSearchBar(items: { searchableItems },
                           archiveItems: { allItems },
                           onSelect: { result in routeDeepLink(toKey: result.id) },
                           onSearchArchive: { query in openArchive(query: query) })
            .padding(.horizontal, OVSpacing.lg).padding(.vertical, OVSpacing.sm)
            Divider()
            queueContent
        }
    }

    // #2803: the modifier chain is split into expressions the compiler type-checks separately.
    //
    // It was ONE chain of about thirty modifiers hanging off `QueueView`, at the Swift type checker's
    // practical limit: adding a single `.task` during #2760 made the whole thing fail with "unable to
    // type-check this expression in reasonable time", which names no line worth reading, and #2760
    // worked around it twice rather than fixing it. Each group below is its own generic function, so
    // the next modifier anybody adds is checked against one small expression instead of the whole
    // surface.
    //
    // Grouped by WHAT a modifier does, not by where its line happened to fall: the surface and its
    // toolbars, the lifecycle work, the alerts, the sheets, and what has to sit outermost. `body` is
    // deliberately untouched, which is what keeps the three guards that read it (the search bar's
    // position above the queue) pointing at the same text.
    // #2883 / #2884: the failure as a KIND plus its stored reason, or nothing when the last sync was
    // clean. Derived here, from the three defaults the sync writes, so the masthead's sentence and its
    // button both follow from one classification instead of each surface reading the raw text (L35).
    private var omniFocusFailure: (kind: OmniFocusFailureKind, reason: String)? {
        guard omniFocusFailedAt > 0 else { return nil }
        return (OmniFocusFailureKind.of(message: omniFocusLastError,
                                        permissionNeeded: omniFocusPermissionNeeded),
                omniFocusLastError)
    }

    private var queueContent: some View {
        withOutermostWrappers(withSheets(withAlerts(withLifecycle(queueSurface))))
    }

    private var queueSurface: some View {
        QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys, onConnectGmail: connectGmail,
                  // #2204: out of the toolbar's status slot, which macOS hides in the overflow chevron at
                  // Dan's ordinary window width, and onto the masthead he reads.
                  // #2478: and the Downbeat export that has lost every shoot it was carrying, which is
                  // upstream of everything else this screen shows.
                  // #1900: and whether the shoot history behind "you've photographed this room before"
                  // is still worth drafting from. It is refreshed by hand, so nothing else on this
                  // screen would ever say it had gone stale.
                  notices: AppNotices.current(omniFocusFailure: omniFocusFailure,
                                              bookingsVanished: bookingsVanished,
                                              shootHistory: shootHistoryHealth,
                                              // #2879: and any handoff file the app is reading and
                                              // cannot read, which used to be indistinguishable from a
                                              // file that was simply not there yet.
                                              unreadableFiles: unreadableFiles, status: status),
                  // #2250: the remedy a notice names, run from here where the sync lives.
                  onNoticeAction: { action in
                      switch action {
                      case .retryOmniFocusSync: syncOmniFocus(force: true)
                      // #1805: finish exactly the shows the last check never reached. The set comes from
                      // the queue's own rule, and it goes through the SAME confirm sheet as every other
                      // check, so a paid run started from a report costs what the sheet says it costs.
                      // Handled inside QueueView, which holds the rows this needs. Reaching here would
                      // mean the queue passed it up rather than serving it, so do nothing rather than
                      // start a run over a set this view cannot compute.
                      case .finishShowsACheckMissed: break
                      // #2478: read the export again, through the same one recorder the reconcile tick
                      // uses, so pressing this and waiting for a tick can never reach different verdicts.
                      // A fixed export clears the line on the spot; a still-broken one leaves it standing,
                      // which is the honest answer to "has Overture noticed yet".
                      case .recheckDownbeatExport: DownbeatBookingFeedStore.observe(now: Date())
                      // #1900: Dan has run the shoot-history import, so read the file again through the
                      // same call the launch load uses (pressing this and relaunching can never reach
                      // different verdicts) and SAY what it found. A finished import clears the line on
                      // the spot; an import that did not take leaves it standing, and that outcome is
                      // the whole reason the press answers rather than changing nothing in silence.
                      case .recheckShootHistory: rereadShootHistoryHealth()
                      }
                  },
                  onShowFollowUps: { showFollowUps = true },
                  // #1129: the Prep stage's discoverable "Prep these N" button opens the same #953 per-run
                  // selection sheet the toolbar menu and Cmd+P do, so there is one Prep-start path, not two.
                  onStartPrep: { showPrepSelection = true },
                  // #1880: the per-row Re-prep launches through the SAME core the batch does, so it shows
                  // "Reading show pages" while the app renders the show's listing page rather than
                  // "Prepping" for that whole stretch.
                  onLaunchPrep: { ctx, now, keys in
                      try await launchPrep(context: ctx, now: now, includedKeys: keys)
                  },
                  // #1308 Layer 2: the date-header "Check reachability" control launches an opt-in probe
                  // over that date's still-open candidates.
                  onProbeReachability: { keys in startReachabilityProbe(keys: keys) })
            .onOpenURL { url in
                // #282: `overture://show` (used by the build script) just surfaces the main window;
                // delivering the URL already reopens the resident copy's window, openWindow makes it
                // explicit and focuses it.
                if OvertureDeepLink.isShowCommand(url) { openWindow(id: "main"); return }
                // #308: a tapped multi-lead away alert opens overture://leads?key=…&key=…; hand the set
                // to the queue to filter down to exactly those new leads.
                if let keys = OvertureDeepLink.leadKeys(from: url) { deepLinkedKeys = keys; return }
                // #236: a tapped OmniFocus follow-up opens overture://lead?key=<naturalKey>; route it
                // the same way as a search pick (#628) since a closed show can still generate a due
                // follow-up (a late reply on a different contact) after it's left the Queue entirely.
                if let key = OvertureDeepLink.leadKey(from: url) { routeDeepLink(toKey: key) }
            }
            .sheet(isPresented: Bindable(addLead).isPresented) { AddLeadSheet() }
            .toolbar {
                // #2204: there is no status slot here any more. macOS moved it into the overflow chevron
                // at Dan's ordinary half-screen width, so every message it carried (the do-not-contact
                // receipt, the unattended scout's warning, a reply-classify save failure, a run that
                // died) was off screen unless he clicked the chevron, which he never has. They are
                // masthead lines now, where they wrap and stay visible at any width. See AppNotice.
                // #352: Scout and Prep are sequential steps in one flow (scout finds performances,
                // then prep researches the ones kept), merged into one menu with Scout listed
                // first. Each action keeps its own keyboard shortcut and its own disabled
                // condition, even nested in the same Menu (a shortcut fires independent of whether
                // the menu is open, same as any AppKit menu command).
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Run scout now") { runScout() }
                            .keyboardShortcut("r", modifiers: .command)
                            // #1033: disabled through BOTH scout phases, not just the native sweep. The
                            // detached read follows with isScanning already false, so the old
                            // .disabled(isScanning) went clickable again mid-run. Same rule runScout
                            // guards on before starting a run.
                            .disabled(ScoutControlState.isRunScoutDisabled(isScanning: isScanning,
                                                                           isReading: readingStartedAt != nil))
                        // #799: a lead Dan found himself (a link to the show, or to the org's events
                        // page). It goes through the same classify/rank/upsert chain as a scouted one.
                        // The shortcut lives on the MENU-BAR command (OvertureApp), not here: a
                        // keyboardShortcut on a Button inside a toolbar Menu draws the "⌘L" and never
                        // registers with the system, so the key did nothing at all. This item stays as
                        // the clickable route, and drives the same presenter.
                        Button("Add a lead...") { addLead.request() }
                        // #1435: a direct hire inquiry Dan logs by hand, tracked alongside scouted shows.
                        Button("Log an inquiry...") { showInquiryIntake = true }
                        Toggle("Auto-scout daily", isOn: $autoScoutEnabled)
                        Divider()
                        // #953: opens the per-run picker rather than prepping every kept show at once, so
                        // Dan can hold a long lead-time show out of this run. The sheet defaults the
                        // selection by performance date and hands back exactly the rows he chose.
                        Button {
                            showPrepSelection = true
                        } label: {
                            Label("Prep kept", systemImage: "envelope.badge")
                        }
                        .keyboardShortcut("p", modifiers: .command)
                        .disabled(prepRefusal != nil)
                        .accessibilityHint(prepRefusal ?? "")
                        .help(prepRefusal ?? "")
                        // #2546: the reason as its own row directly under the item it explains, rather
                        // than only as a tooltip. A menu item has no room beside it for a sentence, but
                        // the greyed item is only ever visible while this menu is open, which is exactly
                        // when this row is on screen too, so the reason is there at rest (L49).
                        ControlRefusalLine(reason: prepRefusal)
                        // #367: re-prep everything already drafted/approved in one go; each choice
                        // just flags the eligible prospects and they ride along in the next
                        // "Prep kept" run above, no separate run/launch of its own.
                        Menu("Re-prep kept") {
                            Button("Redraft only") { bulkReprep(.draftOnly) }
                            Button("Find contacts only") { bulkReprep(.contactsOnly) }
                            Button("Redraft and find contacts") { bulkReprep(.both) }
                        }
                        .disabled(eligibleForBulkReprep.isEmpty)
                        // #1038: stop a Prep run in flight. Present only while one is running (a detached
                        // run has no trackable PID, so this writes the sentinel the runner checks on its
                        // heartbeat and stops cooperatively). The label stays "Prepping" until the runner
                        // notices on its next tick, exactly like the scout takeover's Cancel.
                        // #2614: named after the run it would actually stop. It stops the right thing
                        // whichever is going (one lock, one runner, one cancel sentinel), but while a
                        // reachability check held the slot this was the only stop control on screen and it
                        // called that check a prep run.
                        // #3012: bound to the run `cancelPrep()` will ACTUALLY stop, and labelled by
                        // asking that same slot what kind of run it is. Before this the label came from
                        // the whole-app `runInFlight`, which cannot describe two live runs, while the
                        // action targeted `takeover.presented`: with a prep running and a check started
                        // after it the button read "Cancel reachability check" and stopped the prep.
                        //
                        // It also removes a dead control. `cancelPrep()` has always returned early when
                        // nothing is presented, so a button shown on the old condition could do nothing at
                        // all and say nothing about why (L109). Now the control exists exactly when it has
                        // something to stop.
                        if let slot = takeover.presented,
                           let kind = PrepQueueService.runInFlight(slot: slot, now: Date()) {
                            Divider()
                            Button(kind.cancelLabel, role: .destructive) { cancelPrep(slot: slot) }
                        }
                    } label: {
                        if isScanning && !scoutIsManual {
                            // #1034: the compact toolbar label is now ONLY the scheduled watch-only
                            // scout's treatment. A scout Dan STARTED takes over the screen with the
                            // RunProgressView modal instead (both the native "Scouting" sweep and the
                            // detached "Reading calendars" read), so its progress never shows here. The
                            // detached-read branch that used to live here moved into the modal wholesale:
                            // a watch-only run never reads, so readingStartedAt is only ever set by a
                            // manual run, which the modal owns.
                            LiveRunLabel(base: RunProgressCopy.title(.scouting), since: scoutStartedAt,
                                         timeout: RunTimeouts.scout, compact: true)
                        } else if PrepQueueService.anyRunIsRunning(now: Date()) {
                            // #2760: either slot. Reading only the prep slot would leave a live check with
                            // no toolbar label at all, which is the state the label exists to prevent.
                            prepToolbarLabel
                        } else {
                            // #994: the idle tooltip belongs HERE rather than on the Menu. A live run's
                            // own tooltip (the elapsed counter and "N of M", which compact mode makes
                            // the only place they appear) is set inside LiveRunLabel, and a second
                            // `.help` on the Menu wrapping it would be free to win, silently costing Dan
                            // the still-alive signal this whole change is built to keep.
                            ToolbarHoverLabel(title: "Scout & Prep", systemImage: "binoculars")
                                .help("Scout the venue calendars for new performances (⌘R), then find contacts and draft emails for the ones you keep (⌘P). Auto-scouts about daily.")
                        }
                    }
                    // No primaryAction: a plain click always opens the dropdown instead of
                    // guessing which of Scout or Prep was meant.
                }
                // #346: rendered next to the Scout control that produced it, not the unrelated
                // center status slot. #345: symmetric padding so the text doesn't crowd the pill.
                if let scoutSummary {
                    ToolbarItem(placement: .primaryAction) {
                        Text(scoutSummary)
                            .padding(.horizontal, OVSpacing.sm)
                            .padding(.vertical, 2)
                            .font(.system(size: 11))
                            .foregroundStyle(OVColor.inkFaint)
                    }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        openArchive()
                    } label: {
                        ToolbarHoverLabel(title: "Archive", systemImage: "archivebox")
                    }
                    .help("Every show Overture has ever tracked: past its window, booked, closed, or dismissed")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showFollowUps = true
                    } label: {
                        ToolbarHoverLabel(title: DueWork.badgeTitle(count: followUpsDue),
                                          systemImage: "arrow.uturn.right")
                    }
                    .help("Follow-ups and active conversations due for a touch")
                }
                // #800: read-only for now. Phase 4 adds a source, Phase 5 lets Dan stop watching one.
                //
                // #805: the button changes how it LOOKS while a source needs him. A source that half works
                // is silent (healthy fetch, healthy verdict, quietly returning 16 of its 30 shows), and its
                // only symptom was a sentence in a sheet he has no reason to open. The gold is what he sees
                // across the room; the count and the sentence are there when he hovers. Both come from
                // SourceAttention, never summed here, so this can never disagree with the sheet it opens.
                //
                // #901: Days off shares this group with Sources rather than taking a slot of its own,
                // because SwiftUI's toolbar builder tops out at ten children and one more would not
                // compile. They belong together anyway: both say what Overture is working from, one the
                // calendars it reads and the other the days it must keep clear of.
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button {
                        showSources = true
                    } label: {
                        ToolbarHoverLabel(title: SourceAttention.badgeTitle(count: sourcesNeedingALook),
                                          systemImage: "list.bullet.rectangle",
                                          // The words stay up while a source needs him, rather than hiding
                                          // until he happens to hover the right icon. A symptom only a man
                                          // already looking for it can find is what #805 called the bug.
                                          showsTitle: sourcesNeedingALook > 0)
                            // Gold, not rust: a source degrading is not a source that failed, and the
                            // Sources sheet says it in the same color (#800). The tint is a bonus on top of
                            // the words, never the message itself: macOS may do as it likes with a toolbar
                            // button's foreground style, and the count has to survive that.
                            .foregroundStyle(sourcesNeedingALook > 0 ? OVColor.gold : Color.primary)
                    }
                    .help(SourceAttention.help(count: sourcesNeedingALook))

                    // #901: the days Overture won't pitch him for, and a standing mark while it holds no
                    // booked shoots at all.
                    //
                    // That state is the trap this issue was written about: the conflict guard has never
                    // once fired, because Downbeat exports no bookings and nothing ever wrote the local
                    // override file, and a guard protecting nothing looked exactly like one that worked. It
                    // may sit marked for a long time (bookings only accrue going forward), and that is the
                    // honest reading: until he blocks those days himself, Overture cannot keep clear of them.
                    //
                    // #1430: quiet secondary ink, NOT the gold two items to the left. Gold is the app's
                    // "something is wrong" colour, and nothing here is wrong: a long stretch with no shoots
                    // to keep clear of is an ordinary state of affairs, and Dan read the gold as being told
                    // otherwise. Sources keeps its gold, where a failing calendar really is wrong.
                    //
                    // And no printed title (Dan, 2026-07-24: no words unless something is wrong). The item
                    // reads "Days off" in both states; the whole difference is the ink. That keeps the mark
                    // this feature exists for, because nothing else in the app watches for a dry Downbeat
                    // pipe (its health check passes a fresh export holding no bookings, the #901 trap),
                    // while giving the toolbar nothing to say about Dan's schedule. The sentence is on the
                    // hover and in the sheet, which have room for it.
                    daysOffButton(daysOffReason)

                    // #1118: the towns Overture keeps out of the queue, and where Dan takes one back off.
                    // It shares this group with Sources and Days off (SwiftUI's toolbar builder tops out at
                    // ten children, and a fourth ToolbarItem would not compile), and it belongs with them:
                    // all three say what Overture is working from, one the calendars it reads, one the days
                    // it keeps clear, one the places it stays out of. No attention state of its own: the
                    // skip list is Dan's to review when he chooses, never something that needs him.
                    Button {
                        showExcludedTowns = true
                    } label: {
                        ToolbarHoverLabel(title: "Skipped towns", systemImage: "hand.raised")
                    }
                    .help("Towns you've told Overture to skip. Take one back off the list here.")

                    // #1731: who Overture thinks puts each show on. It belongs in this group for the same
                    // reason the other three do: all four say what Overture is working from, one the
                    // calendars it reads, one the days it keeps clear, one the places it stays out of, and
                    // this one the organisations it decided about. No attention state: these verdicts are
                    // his to review when he chooses, never something that needs him.
                    Button {
                        showOrganisations = true
                    } label: {
                        ToolbarHoverLabel(title: "Presenters", systemImage: "building.2")
                    }
                    .help("Who Overture thinks puts each show on, and who it reads as the building.")
                }
                // #901 (Dan's walk, 2026-07-14): What converts and Voice guidance sit AFTER the
                // Sources/Days off group, not before it. With every toolbar label now always shown the row
                // overflows into the macOS ">>" menu, and in that order the brand-new Days off button was
                // the first thing hidden. The daily-driver buttons (Archive, Follow-ups) and the two things
                // Overture is working from (Sources, Days off) come first; these two settings-ish views can
                // fall into the overflow instead.
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showPatterns = true
                    } label: {
                        ToolbarHoverLabel(title: "What converts", systemImage: "chart.bar")
                    }
                    .help("Booking and response rates by production, discipline, and fit tier")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showVoiceGuidance = true
                    } label: {
                        ToolbarHoverLabel(title: "Voice guidance", systemImage: "text.quote")
                    }
                    .help("Read and edit how Overture drafts in your voice. Your notes stay yours; tendencies are learned from your edits.")
                }
                // #344: connected is the steady state Dan will see almost always, so it collapses to
                // a bare icon; disconnected stays a prominent, labeled call to action since it
                // blocks sending.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        connectGmail()
                    } label: {
                        if gmailConnected {
                            Image(systemName: "checkmark.circle.fill")
                        } else if isConnectingGmail {
                            LiveRunLabel(base: "Connecting", since: gmailConnectStartedAt,
                                         timeout: RunTimeouts.gmailConnect)
                        } else {
                            // #901: labelled statically (showsTitle) even though the toolbar is otherwise
                            // icons-only. A disconnected Gmail blocks every send, so "Connect Gmail" has to
                            // read at a glance, not only on hover.
                            ToolbarHoverLabel(title: "Connect Gmail", systemImage: "link", showsTitle: true)
                        }
                    }
                    .disabled(gmailConnected || isConnectingGmail)
                    .help(GmailCopy.connectionHelp(connected: gmailConnected))
                }
                // #355: the automatic sync's enabled/last-synced state is now glanceable, and the
                // rarely-needed manual force-run moves out of the prominent toolbar into this menu.
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Toggle("Auto-sync to OmniFocus", isOn: $omniFocusEnabled)
                        if omniFocusEnabled {
                            Text(omniFocusStatusLine).foregroundStyle(OVColor.inkFaint)
                        }
                        Divider()
                        Button("Sync now") { syncOmniFocus(force: true) }
                            .disabled(omniFocusSyncStartedAt != nil)
                        Divider()
                        // #931: the reminder-cadence and look-ahead settings, orphaned when the
                        // Follow-ups reminder button was removed (#901/#930), live here now. This menu is
                        // already the follow-up-automation surface, and it is NOT the Follow-ups header
                        // Dan asked to keep clear.
                        Button("Sync window…") { showOmniFocusSettings = true }
                    } label: {
                        // #469: the menu itself stays clickable while syncing (unlike Scout/Prep and
                        // Gmail connect, this doesn't block anything Dan would want to check), but the
                        // idle icon swaps for a live state so a sync in progress is never silently
                        // indistinguishable from an idle one.
                        if let since = omniFocusSyncStartedAt {
                            LiveRunLabel(base: "Syncing", since: since, timeout: RunTimeouts.omniFocusSync)
                        } else {
                            ToolbarHoverLabel(title: "OmniFocus", systemImage: "checklist")
                        }
                    }
                    .help("Automatic sync pushes due follow-ups into the OmniFocus Outreach project. \"Sync now\" force-runs it immediately; the first time, macOS will ask permission to control OmniFocus.")
                }
            }
            // #1034: the reopen control, shown only while a scout Dan started is running and he has
            // hidden its progress window. Dismissing the window only hides it (#1010); the run keeps
            // going. Its own .toolbar block, not the main one above, because that block is already at
            // SwiftUI's ten-item ceiling (the same reason the DEBUG block below is separate).
            .toolbar {
                if scoutIsManual && !scoutSheetShown {
                    ToolbarItem(placement: .primaryAction) {
                        Button { scoutSheetShown = true } label: {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.small)
                                Text("Scout progress")
                            }
                        }
                        .help("Show the scout that's running. Hiding its window doesn't stop it.")
                    }
                }
            }
            .toolbar {
                #if DEBUG
                // DEBUG ONLY (#196): test affordances, compiled out of release builds. Split into its
                // own .toolbar block (rather than the main one above) because the new global search
                // field pushed the main block past SwiftUI's toolbar item limit.
                ToolbarItem(placement: .secondaryAction) {
                    Menu { debugMenuItems } label: { Label("DEBUG", systemImage: "ladybug") }
                }
                #endif
            }
    }

    // The attended launch work and the watchers that follow it.
    private func withLifecycle<Content: View>(_ content: Content) -> some View {
        content
            .task {
                // The ATTENDED launch work (window present). The SAFE reconciles (booking detection,
                // reply detection, and the OmniFocus push) and the Downbeat-export watcher now live on
                // the app-owned ReconcileScheduler (#265) so they run independent of this window. What
                // stays here is the AI/scout work, which must stay attended (never run unattended).
                // Skip it entirely when running only as the unit suite's test host (#195).
                guard AppEnvironment.shouldStartBackgroundServices else { return }
                // Ingest any classifications from a prior run, then launch a classify run for replies
                // still needing an intent (#112). Both no-op when there's nothing to do.
                ingestReplyClassifications()
                startReplyClassifyIfNeeded()
                // #1878: a run that ENDED while Overture was closed still has its pair on disk with nobody
                // to keep it, and the next run overwrites both. Archived here, before any of the settling
                // below, and only when no run is live: a live run's results file is still being written,
                // and a copy of it taken now would claim that run's own folder with a half-finished
                // version the real settle would then decline to replace.
                // #2760: per slot, each with its own archive. A live run in EITHER slot still blocks the
                // archive of either, because a check that touched a prep-slot file is precisely what the
                // boundary record below reports, and a copy taken mid-write would claim the run's folder
                // with a half-finished version the real settle would then decline to replace.
                if !PrepQueueService.anyRunIsRunning(now: Date()) {
                    for slot in RunSlot.allCases { archiveFinishedRun(slot: slot) }
                }
                // #2760: and each slot is reattached, swept and settled on its own terms. Sharing one pass
                // was what made a check started during a prep unwatched and unsettled.
                for slot in RunSlot.allCases {
                    reattachOrSettle(slot: slot)
                }
                // #2760 (carrying #2764's requirement): the runner records a run that wrote another run's
                // results file, and until now nothing in the app read that record. From here two runs can
                // be on disk at once, so a file nobody surfaces is the account of one run destroying
                // another's paid work with no reason for Dan ever to open it (L46, L142).
                reportAnyBoundaryViolation()
                // #1035: the same reattach, for the scout's detached read. A scout-extract run outlives
                // the app, so one can still be going at launch (a relaunch over a live run, or the window
                // scene torn down and rebuilt mid-read). Reopen the takeover and follow it to completion
                // so a live run is never invisible now that the modal is the primary progress signal.
                if ScoutExtractService.isRunning(now: Date()) {
                    await reattachScoutExtractRun()
                }
                autoScoutIfDue()   // run a scheduled scout on launch if one is due (#33)
            }
            // #2365: load Dan's client list at launch, and again whenever the reconcile tick observes the
            // Downbeat export changing. WITHOUT THIS the roster is empty until the Sources sheet is
            // opened, and an empty roster is not a neutral state: it answers "nobody is a client", which
            // holds every one of his clients' far-out shows to the ordinary 90 day window. So the feature
            // would have done nothing on any launch where he never opened that sheet, while every test
            // passed, because a test hands the client list in directly (L3: built is not wired).
            //
            // `feedClientCount` is written by the app-owned ReconcileScheduler each time it reads the
            // export, so watching it re-reads the roster on the same signal rather than on a timer of its
            // own. It is a count, so a client RENAMED without the total moving does not move it; the
            // launch load is what covers that, and the gap between them is a session.
            .task { clientRoster?.reload() }
            // #1900: and read the shoot history's verdict at launch, for the same reason: without this
            // the masthead holds nil forever and the warning is built but never wired (L3). Once per
            // launch is enough for a file only a manual import rewrites, and the notice's own re-read
            // control covers the case where Dan runs that import mid-session.
            .task { readShootHistoryHealth() }
            // #2879: keep the "couldn't read" line current. Once at launch, because the launch ingests
            // have already run by then, and then on a tick, because most of these files are read by
            // background work (a run watcher, the reconcile scheduler) that has no way to reach this
            // view. Reading the register is a dictionary lookup, so an app with nothing wrong pays a
            // lock and an equality check a minute and redraws nothing.
            .task {
                refreshUnreadableFiles()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    refreshUnreadableFiles()
                }
            }
            .onChange(of: feedClientCount) { clientRoster?.reload() }
            .task {
                guard AppEnvironment.shouldStartBackgroundServices else { return }
                // Follow every reply-classify run to completion so a finished draft clears the spinner
                // and ingests at once instead of waiting for the next launch (#435).
                await watchReplyClassifyRuns()
            }
            .task {
                guard AppEnvironment.shouldStartBackgroundServices else { return }
                // #1143: follow every Prep run to completion, the same way. A per-row Re-prep click
                // launches a Prep run straight from ProspectMutations, with no RootView startPrep call
                // to open the takeover or ingest its results, so without this a re-prepped show's drafts
                // would only surface on the next launch and its progress would be invisible mid-session.
                // #2760: ONE WATCHER PER SLOT, side by side in this one task. A single watcher over a
                // single activity is what left a check started during a live prep followed by nobody: it
                // woke no listener, so its paid answers landed only at the next launch, via
                // settleOrphanedProbe.
                //
                // `async let` rather than a task group (whose `addTask` closure is `@Sendable` and cannot
                // inherit the main actor) and rather than an unstructured `Task {}` (which the window's
                // teardown would not cancel, leaving a watcher outliving the view that owns it). Both
                // children are cancelled with this task. `everySlotHasAWatcher` keeps the pair complete.
                async let prepWatch: Void = watchRuns(slot: .prep)
                async let checkWatch: Void = watchRuns(slot: .check)
                _ = await (prepWatch, checkWatch)
            }
            .task {
                guard AppEnvironment.shouldStartBackgroundServices else { return }
                // Keep the daily scout schedule honored while the app stays open (#33).
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)  // hourly
                    autoScoutIfDue()
                }
            }
    }

    // Everything that stops Dan with a question or a failure.
    private func withAlerts<Content: View>(_ content: Content) -> some View {
        content
            .alert("Something went wrong", isPresented: errorBinding) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            // #1163: a Gmail-connect failure (the handoff never landed) is recoverable by simply retrying,
            // so its alert leads with Try again instead of a bare OK, and fires as soon as the attempt gives
            // up rather than leaving Dan on a silent "Connecting…".
            .alert("Couldn't connect Gmail", isPresented: gmailConnectErrorBinding) {
                Button("Try again") { gmailConnectError = nil; connectGmail() }
                Button("Cancel", role: .cancel) { gmailConnectError = nil }
            } message: {
                Text(gmailConnectError ?? "")
            }
            // #1054: a scout Dan cancelled had already read some shows before it stopped. Rather than
            // import them silently after he hit Cancel, ask. Keep is the default (the shows are real finds
            // and keeping is reversible); Discard is destructive because it drops them and deletes the file.
            .alert(CancelledReadCopy.title, isPresented: cancelledReadBinding,
                   presenting: cancelledScoutRead) { count in
                Button(CancelledReadCopy.keepLabel(readCount: count)) { keepCancelledRead() }
                    .keyboardShortcut(.defaultAction)
                Button(CancelledReadCopy.discardLabel, role: .destructive) { discardCancelledRead() }
            } message: { count in
                Text(CancelledReadCopy.message(readCount: count))
            }
            // #1498: the run has fetched and hashed everything (all free) and is about to spend. Above
            // ScoutReadBudget's threshold it stops here and asks, with the true count of pages that need
            // reading. A plain alert, matching the reconnect prompt rather than the send sheet: this is a
            // recoverable interruption to a run in flight, not a consequential commit.
            //
            // Every route out answers the sweep, including the dismissal, because doing nothing is the one
            // outcome that leaves the modal spinning on a run that can never finish.
            .alert(ScoutReadBudget.askTitle(pending: scoutReadAsk?.pending ?? 0),
                   isPresented: scoutReadAskBinding, presenting: scoutReadAsk) { ask in
                Button(ScoutReadBudget.readAllTitle(pending: ask.pending)) { answerReadAsk(ask, .all) }
                    .keyboardShortcut(.defaultAction)
                Button(ScoutReadBudget.readBatchTitle()) { answerReadAsk(ask, .firstBatch) }
                Button(ScoutReadBudget.readNoneTitle, role: .cancel) { answerReadAsk(ask, .none) }
            } message: { ask in
                Text(ScoutReadBudget.askMessage(pending: ask.pending))
            }
            // #1034/#1027: ONE presented sheet for a manual scout, from click to results. While the run
            // is in flight (scoutWarnings still nil) it is the RunProgressView takeover; the instant the
            // run finishes with something to say it becomes #1027's ScoutSummaryView, in the same sheet,
            // so there is no dismiss-then-present flicker between two separate sheets. A run with nothing
            // to report just closes it.
    }

    // Every sheet this window can present.
    private func withSheets<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $scoutSheetShown, onDismiss: { scoutWarnings = nil }) {
                if let scoutWarnings {
                    // Fires once, at the true end of a manual run; lets Dan fix or confirm a source inline.
                    ScoutSummaryView(warnings: scoutWarnings,
                                     onReadFixed: { ids in runScout(only: ids) },
                                     // #1190: check the sources this run was over budget to reach. The
                                     // ordinary runScout() reads the next batch first (its fairness clock
                                     // keeps the deferred ones next in line); no dismiss, so the sheet
                                     // swaps to progress in place, exactly as "Read the ones I fixed" does.
                                     onRunAgain: { runScout() })
                } else {
                    scoutProgressModal
                }
            }
            .sheet(isPresented: $showArchive) {
                ArchiveView(initialHighlightKey: archiveJumpKey, initialHighlightRecipientId: archiveJumpRecipientId,
                           initialQuery: archiveOpeningQuery, onConnectGmail: connectGmail)
            }
            .sheet(isPresented: $showPatterns) { OutcomePatternsView() }
            .sheet(isPresented: $showInquiryIntake) { InquiryIntakeSheet() }
            .sheet(isPresented: $showFollowUps) {
                FollowUpsView(onOpenInArchive: { key, recipientId in
                    showFollowUps = false
                    openArchive(key: key, recipientId: recipientId)
                })
            }
            .sheet(isPresented: $showVoiceGuidance) { VoiceGuidanceView() }
            // #953: pick which kept shows this Prep run covers. Defaults by performance date; the run
            // fires with exactly the rows Dan leaves checked.
            .sheet(isPresented: $showPrepSelection) {
                // #2365: no sources and no client list any more. The sheet applies no date rule, so it
                // needs neither, and this call no longer reads the export off disk to present a sheet.
                PrepSelectionSheet(prospects: toPrep,
                                   allItems: allProspects.map(QueueItem.init)) { includedKeys in startPrep(includedKeys: includedKeys) }
            }
            // #1130: the Prep run's takeover, mirroring the scout's (#1034). A detached Prep run takes
            // minutes, so it gets the same prominent working/still-alive/stalled screen instead of only a
            // subtle toolbar label. Shown while the run is in flight (set by startPrep and on launch-reattach)
            // and cleared by the run watcher when the run ends; Hide keeps the run going, Cancel stops it.
            // #2760: which slot the one sheet is showing is RunTakeover's decision, and dismissing it
            // closes only that run's takeover.
            .sheet(isPresented: runTakeoverBinding) { prepProgressModal }
            .sheet(isPresented: $showSources) { SourcesView(readOne: { runScout(only: [$0.sourceId]) }) }
            .sheet(isPresented: $showDaysOff) { DaysOffView() }
            .sheet(isPresented: $showOmniFocusSettings) { OmniFocusSettingsView() }
            .sheet(isPresented: $showExcludedTowns) { ExcludedTownsView() }
            .sheet(isPresented: $showOrganisations) { OrganisationsView() }
            // #924: the date picker a multi-night dismissal opens, pre-filled with the run's dates.
            .sheet(item: Bindable(dayOffOffer).pending) { pending in
                BlockDaysSheet(pending: pending, undo: undoStack)
            }
            // #2202: the presenter cannot reach this view's own @State, so it is handed the way to
            // close it. Here rather than in a .task, because a question can be raised by a launch-time
            // reattach before any task has run.
    }

    // Injected outermost, so the sheets above inherit them too (#285).
    private func withOutermostWrappers<Content: View>(_ content: Content) -> some View {
        content
            .onAppear { modals.closesSheetsWith { closeEveryPresentedSheet() } }
            .actionFeedbackBanner()
            // Injected outermost so the sheets above inherit it too (#285).
            .environment(feedback)
            .environment(dayOffOffer)
            // #1414: the Edit menu's Undo raises a token on the App; the reversal happens HERE, where
            // the context, the live rows and the feedback banner all exist.
            .onChange(of: undoRequest.token) { _, _ in performQueueUndo() }
    }


    // One press, one whole action reversed (#1414), INCLUDING a day off the dismiss led to (#1473), which
    // is why the store is passed: the block is a row of its own and the sweep it triggered flagged other
    // shows. Takes the top entry whether or not it turns out to
    // be applicable, because a stale entry is spent either way: leaving it on the stack would make the
    // next Cmd+Z retry the same dead entry forever instead of reaching the one behind it.
    private func performQueueUndo() {
        guard let entry = undoStack.takeTop() else { return }
        let outcome = QueueUndo.apply(entry, resolving: { key in
            allProspects.first { $0.naturalKey == key }
        }, in: context)
        guard outcome.didAnything else {
            // #1415: the row moved since (a scout re-scored it, a sweep took it, a send made it contacted)
            // or is gone, so there is nothing to put back. Since #1134 the store and the visible stage move
            // independently, so a silent no-op here is pixel-identical to a working undo; say so instead.
            feedback.acknowledge(entry.rows.count == 1
                                 ? ActionAck.undoSkipped(org: entry.groupName)
                                 : ActionAck.undoSkippedNight(count: entry.rows.count))
            return
        }
        // #1415: an undo usually restores the row into a stage Dan is not looking at, so name what came
        // back and where. Only on a good save: saveOrWarn already posts its own warning on failure, and a
        // "back in Prep" over a failed save would contradict it.
        guard context.saveOrWarn(org: entry.groupName, feedback: feedback) else { return }
        feedback.acknowledge(undoMessage(for: entry, outcome: outcome))
    }

    // #1500: an entry can now cover a whole night, and a night can come back in part (a show a scout or a
    // sweep moved on stays dismissed). All three cases are said in the row's own terms: which stage pill to
    // look at, and how many did NOT come back, which nothing else on screen would tell him.
    private func undoMessage(for entry: QueueUndoEntry, outcome: QueueUndo.Outcome) -> String {
        guard entry.rows.count > 1 else {
            return ActionAck.undoRestored(org: entry.groupName, priorStatus: entry.priorStatus)
        }
        let stages = entry.rows.map(\.priorStatus)
        if outcome.isPartial {
            return ActionAck.undoRestoredPartOfNight(restored: outcome.restored, missed: outcome.missed,
                                                     priorStatuses: stages)
        }
        return ActionAck.undoRestoredNight(count: outcome.restored, priorStatuses: stages)
    }

    #if DEBUG
    // DEBUG ONLY (#196): stage the first not-yet-sent prospect as approved-and-sent so the
    // post-send lifecycle can be exercised end to end without a real send or store surgery.
    // DEBUG ONLY (#281): copy the live handoff inputs into the isolated Overture-Debug folder, then
    // force a fresh re-ingest so scout/booking/reply features show realistic data without a relaunch.
    // PrepImporter/ReplyClassifyImporter are idempotent (keep/dismiss decisions survive a re-run), so
    // this is safe to run repeatedly; booking reconcile reads the now-seeded Downbeat export on its
    // next cycle.
    private func debugSeedFromLive() {
        let result: (copied: [String], missing: [String])
        do {
            result = try DebugSeed.seedFromLive()
        } catch {
            status.set("DEBUG seed failed: \(error.localizedDescription)")
            return
        }
        ingestPrep()
        ingestReplyClassifications()
        status.set("DEBUG: seeded \(result.copied.count) file\(result.copied.count == 1 ? "" : "s")"
            + (result.copied.isEmpty ? " (none found in live)" : ": " + result.copied.joined(separator: ", ")))
    }

    // DEBUG ONLY (#325): copy the live Gmail credentials into the isolated Overture-Debug folder so the
    // real approve -> send -> success/error path can be driven end to end in a dev build. The #267 split
    // otherwise leaves the Debug build with no Gmail login. Sensitive (real OAuth client + refresh
    // token); opt-in. Requires that the release app is already connected (the token file must exist).
    private func debugSeedGmailFromLive() {
        let result: (copied: [String], missing: [String])
        do {
            result = try DebugSeed.seedGmailFromLive()
        } catch {
            status.set("DEBUG Gmail connect failed: \(error.localizedDescription)")
            return
        }
        if result.missing.contains("gmail-tokens.json") {
            status.set("DEBUG: live Gmail isn't connected. Connect it in the release app first, then retry.")
            return
        }
        status.set(GmailConnection.shared.refreshedIsConnected()
            ? "DEBUG: Gmail connected from live (\(result.copied.joined(separator: ", ")))"
            : "DEBUG: copied \(result.copied.count) file(s) but Gmail still reads as not connected")
    }

    // DEBUG ONLY (#318): targeted reset of the isolated Overture-Debug dev environment: empties the
    // store and removes the seeded handoff inputs, so seed/test/reset is repeatable. Only ever
    // touches the Debug location; leaves the dev Gmail login intact.
    private func debugClearDevData() {
        DebugSeed.clearStore(in: context)
        do {
            try context.save()
        } catch {
            status.set("DEBUG clear failed: \(error.localizedDescription)")
            return
        }
        let removed: [String]
        do {
            removed = try DebugSeed.clearHandoffInputs(debugBase: DebugSeed.debugHandoffDirectory)
        } catch {
            status.set("DEBUG clear failed: \(error.localizedDescription)")
            return
        }
        syncOmniFocus(force: true)   // completes the now-orphaned OmniFocus tasks
        status.set("DEBUG: cleared dev data (store + \(removed.count) file\(removed.count == 1 ? "" : "s"))")
    }

    private func debugStageFirstAsSent() {
        guard let target = allProspects.first(where: { $0.sentAt == nil }) else {
            status.set("DEBUG: no un-sent prospect to stage")
            return
        }
        DebugStaging.stageAsSent(target, now: Date())
        do {
            try context.save()
            status.set("DEBUG: staged \(target.groupName) as sent")
        } catch {
            status.set("DEBUG stage failed: \(error.localizedDescription)")
        }
    }

    private func debugStageReminderLead() {
        let p = DebugStaging.stageReminderDueLead(in: context, now: Date())
        do {
            try context.save()
            status.set("DEBUG: staged \(p.groupName) as reminder-due")
        } catch {
            status.set("DEBUG stage failed: \(error.localizedDescription)")
        }
    }

    // DEBUG ONLY (#325): stage a self-addressed lead so the real approve -> send path can be verified
    // without risking a real email to a prospect. Approve it, then Send: it goes to Dan's own inbox.
    private func debugStageSelfSendLead() {
        let address = DebugStaging.resolvedSelfSendAddress(
            override: UserDefaults.standard.string(forKey: "selfSendTestAddress"))
        let p = DebugStaging.stageSelfSendLead(in: context, now: Date(), address: address)
        do {
            try context.save()
            status.set("DEBUG: staged self-send lead to \(p.recipients.first?.email ?? "?"). Approve it, then Send")
        } catch {
            status.set("DEBUG stage failed: \(error.localizedDescription)")
        }
    }

    // DEBUG ONLY (#425): like debugStageSelfSendLead, but with two recipients (act + presenter) so the
    // per-recipient send fan-out (#415) can be proven end to end: approve once, then Send twice, two
    // separate emails should land in Dan's own inbox on their own threads.
    private func debugStageMultiRecipientSelfSendLead() {
        let address = DebugStaging.resolvedSelfSendAddress(
            override: UserDefaults.standard.string(forKey: "selfSendTestAddress"))
        let p = DebugStaging.stageMultiRecipientSelfSendLead(in: context, now: Date(), address: address)
        do {
            try context.save()
            status.set("DEBUG: staged multi-recipient self-send lead (\(p.recipients.count) recipients). Approve it, then Send twice")
        } catch {
            status.set("DEBUG stage failed: \(error.localizedDescription)")
        }
    }

    // DEBUG ONLY (#1245): seed the states two shipped-but-hard-to-see features need in a near-empty dev
    // store: a draft in Review with a stored Gmail signature (#1203's styled preview) and a second show on
    // the same date already emailed (#1219's self double-booking note/warning). Open the drafted show in
    // Review to see the signature render, and note the double-booking flag on its date.
    private func debugStageVisualQAScenario() {
        let p = DebugStaging.stageVisualQAScenario(in: context, now: Date())
        do {
            try context.save()
            status.set("DEBUG: staged visual-QA scenario. Open '\(p.groupName)' in Review for the signature preview and the double-booking flag")
        } catch {
            status.set("DEBUG stage failed: \(error.localizedDescription)")
        }
    }

    private func debugStageWarmRegisterDraft() {
        let p = DebugStaging.stageWarmRegisterDraft(in: context, now: Date())
        do {
            try context.save()
            status.set("DEBUG: staged warm-register returning-client draft. Open '\(p.groupName)' in Review")
        } catch {
            status.set("DEBUG stage failed: \(error.localizedDescription)")
        }
    }

    private func debugStageReprepQueuedDraft() {
        let p = DebugStaging.stageReprepQueuedDraft(in: context, now: Date())
        do {
            try context.save()
            // #1940: Prep, not Review. A queued re-prep now takes the show out of the Review count, so the
            // stage this sentence sends you to is the one that no longer holds it.
            status.set("DEBUG: staged re-prep-queued draft. Open '\(p.groupName)' in Prep for the 'Re-prep queued' badge")
        } catch {
            status.set("DEBUG stage failed: \(error.localizedDescription)")
        }
    }

    private func debugStageReachabilityCompetition() {
        let shows = DebugStaging.stageReachabilityCompetition(in: context, now: Date())
        do {
            try context.save()
            status.set("DEBUG: staged \(shows.count) shows competing on one date. The emailable one carries the best-contact highlight")
        } catch {
            status.set("DEBUG stage failed: \(error.localizedDescription)")
        }
    }

    private func debugStageFormPitchScenario() {
        let shows = DebugStaging.stageFormPitchScenario(in: context, now: Date())
        do {
            try context.save()
            status.set("DEBUG: staged \(shows.count) form-only shows. One is in Review with 'Copy pitch and open form'; the other is in Reached out, already recorded")
        } catch {
            status.set("DEBUG stage failed: \(error.localizedDescription)")
        }
    }

    private func debugClearDebugLeads() {
        DebugStaging.clearDebugLeads(in: context)
        do {
            try context.save()
        } catch {
            status.set("DEBUG clear failed: \(error.localizedDescription)")
            return
        }
        syncOmniFocus(force: true)   // completes the now-orphaned OmniFocus tasks
        status.set("DEBUG: cleared debug leads")
    }
    #endif

    private func connectGmail() {
        isConnectingGmail = true
        gmailConnectStartedAt = Date()   // #436: drives the live elapsed counter + the "looks stuck" warning
        status.set(nil)
        // connect() self-aborts after a hard internal timeout (GmailAuthManager.timeoutTask, 120s) and
        // throws, so the failure path below always resolves; the LiveRunLabel surfaces a "looks stuck"
        // warning a bit earlier so Dan can check the browser sign-in window before it gives up.
        Task {
            do {
                try await GmailAuthManager.shared.connect()
                GmailConnection.shared.refresh()   // #1770: the tokens just landed; re-read them once.
                status.set("Gmail connected. You can now send approved emails.")
            } catch {
                reportGmailConnectError(error.localizedDescription)
            }
            isConnectingGmail = false
            gmailConnectStartedAt = nil
        }
    }

    // #953: `includedKeys` is the per-run subset Dan chose in the Prep selection sheet. It is always an
    // explicit set (possibly empty), never nil, so this run covers exactly the rows he left checked.
    // #1308 Layer 2: launch an opt-in reachability probe over a date's still-open candidates. Mirrors
    // startPrep (same single-slot lock, same takeover for working/still-alive/stalled), but researches
    // contacts only. watchPrepRuns follows it to completion and settleReachabilityProbe settles it.
    private func startReachabilityProbe(keys: Set<String>) {
        // #1856: a check over shows that name no producer renders each of their listing pages first, which
        // is seconds of real work. Same treatment as startPrep's: the takeover goes up BEFORE the launch
        // and carries a live count, or that whole phase happens behind a button that looks inert.
        takeover.show(.check)
        takeover.startListingRead(.check, at: Date())
        Task { @MainActor in
            defer { takeover.finishListingRead(.check) }
            do {
                _ = try await PrepQueueService.startReachabilityProbe(
                    keys: keys, from: context, now: Date(),
                    onListingProgress: { done, total in
                        takeover.recordListingProgress(.check, completed: done, total: total, at: Date())
                    })
            } catch {
                // The check never started, so the takeover must not sit there implying it did.
                takeover.hide(.check)
                reportError(error.localizedDescription)
            }
        }
    }

    // #1880: the launch's awaitable core, so a per-row Re-prep can use the SAME one.
    //
    // A Re-prep reaches `PrepQueueService.startPrep` directly, which left `listingProgress` unset, so the
    // takeover fell through to "Prepping" for the whole time the app was rendering the show's listing page
    // in a hidden browser. #1824 added that phase precisely so a launch spending tens of seconds there
    // would not read as a dead button, and one of the three ways a run starts still read that way.
    //
    // Everything the phase needs lives on this view, so the wiring goes OUT to the callers rather than the
    // takeover coming in: `QueueView` and the row factory take this closure and hand it to
    // `ProspectMutations.reprep`'s existing `startPrep:` seam, which already has this exact shape.
    @MainActor
    func launchPrep(context ctx: ModelContext, now: Date, includedKeys: Set<String>) async throws {
        takeover.show(.prep)
        takeover.startListingRead(.prep, at: now)
        defer { takeover.finishListingRead(.prep) }
        _ = try await PrepQueueService.startPrep(
            from: ctx, now: now, includedKeys: includedKeys,
            onOrphanSettled: { reportReachabilityRun($0) },
            onListingProgress: { done, total in
                takeover.recordListingProgress(.prep, completed: done, total: total, at: Date())
            })
    }

    private func startPrep(includedKeys: Set<String>) {
        // #1130: show the takeover so the run's working state is unmistakable from the moment it starts,
        // the same as a manual scout, rather than a subtle toolbar label a first-time user misses.
        // #1824: raised to BEFORE the launch, because the launch now renders each kept show's listing page
        // first (seconds of real work). Left where it was, that whole phase happened behind a button that
        // looked like it had done nothing.
        Task { @MainActor in
            do {
                // #1809: the orphan settle lives in PrepQueueService.startPrep, so every way a Prep run
                // begins is covered. This only supplies somewhere to SAY what that settle found.
                // #353: no separate "started" message. The button's own "Prepping…" state and
                // QueueView's masthead count already say a run is in progress; a second message
                // saying the same thing was redundant.
                // #1143: the continuous watchPrepRuns task follows this run to completion (ingest, or a
                // clear empty-run notice), so it is not started per-launch here; one watcher owns every run.
                // #1880: through `launchPrep`, the same core a per-row Re-prep now uses, so all three
                // entry points show one phase label rather than two of three.
                try await launchPrep(context: context, now: Date(), includedKeys: includedKeys)
            } catch {
                // The run never started, so the takeover must not sit there implying it did.
                takeover.hide(.prep)
                reportError(error.localizedDescription)
            }
        }
    }

    // #1038: stop a Prep run in flight, cooperatively. The detached run has no trackable PID, so this
    // writes the sentinel the runner checks on its heartbeat; the runner stops the claude process it
    // recorded and exits at the next tick (never mid-write, so no draft is corrupted). The run watcher
    // notices the marker clear and ingests whatever the run had already written.
    // #2760: the run on screen, not "the run". Cancel on the check's takeover has to reach the check's own
    // sentinel, or it would stop the prep run beside it while the check carried on spending.
    // #2761: the slot is passed IN, by the block the button sits in, rather than looked up. With one line
    // per live run there is no "the run on screen" to resolve against, and a lookup would be a second
    // source of truth for which run a button means, which is the defect #3012 fixed one layer up.
    private func cancelPrep(slot: RunSlot) {
        PrepQueueService.requestCancel(slot: slot)
    }

    // Report what a finished run produced. Reached only once a run that was genuinely live has ended, so
    // an old failed run never re-nags on a normal open.
    //
    // #1938: the waiting itself moved to DetachedRunActivity.followUntilFinished, which polls only while a
    // run is in flight. What is left here is the settling, which is what this always really was.
    private func settleFinishedRun(slot: RunSlot) async {
        // #3014: a run ending is the moment the fan-out block must lift, and it is not a store write, so
        // nothing would re-derive the queue on its own (L175). Refreshed FIRST, so anything below that
        // triggers a rebuild sees the released state rather than the held one.
        defer { LiveRunHoldings.refresh() }
        // #3013: a run ending is when a mark left by a run that never carried the show has to go. Without
        // this a cancelled or died run leaves a card saying it was left out of a run that ended days ago,
        // and nothing else would ever clear it (L200, L121).
        defer { PrepQueueService.sweepStaleHeldBackMarks(now: Date(), in: context) }
        // #1878: keep this run's work-list and results before anything else. FIRST, and above the dead-run
        // sweep in particular, because that sweep RETURNS: a run that died is the one whose evidence is
        // worth the most, and archiving after it would be archiving every run except those.
        archiveFinishedRun(slot: slot)
        // #1130: the run has ended (the marker cleared). Close the takeover so it does not sit showing a
        // finished run; the outcome surfaces below via ingest / the empty-run notice.
        // #2760: THIS slot's takeover only. One `prepSheetShown = false` dismissed whichever screen was up,
        // which meant the first run to finish took the other's takeover with it.
        takeover.hide(slot)
        // #1613: a run can end two ways and they deserve opposite treatment. The runner removes its own
        // marker on the way out, so a marker STILL THERE at the moment the run stopped being live means it
        // died somewhere it never reached that exit. Nothing more is coming, so the panel must not sit
        // offering Cancel (which writes a sentinel only a live runner reads, and so could never do
        // anything). Swept and reported instead; the normal settle below is for a run that finished.
        if sweptADeadRun(slot: slot) { return }
        let started = PrepQueueService.lastRunStartedAt(slot: slot)
        // #2105: through the shared read, which drops Foundation's per-URL cache. Safe here only by
        // accident before (the default URL is a computed property), and this decides whether a finished
        // run produced results at all.
        let resultsMod = FileTimestamp.modifiedAt(PrepImporter.resultsURL(for: slot))
        // #1308 Layer 2: a probe and a real Prep share this one runner and results file, so route by the
        // probe-run marker first. settleReachabilityProbe returns a report only when the finished run was a
        // probe (marking every probed show, ingesting probe-safely, clearing the marker); a probe that
        // found nothing is a valid "no email found" result, so on finishedEmpty it still settles rather
        // than raising the generic empty-run error. A normal prep run has no marker, so it falls through to
        // the usual handling.
        //
        // #1769: "settles rather than nagging" used to mean it said NOTHING, which was right for a check
        // that answered its shows and found nobody and wrong for one that came home short. The report now
        // carries that difference, and stays silent when there is genuinely nothing to say.
        // #1616: read the run's own size BEFORE the settle below clears the marker that carries it.
        let checkLookups = ((try? ReachabilityProbeMarker.read(from: PrepQueueService.defaultProbeRunURL))
                            ?? nil)?.lookups
        switch DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: resultsMod ?? nil) {
        case .producedResults:
            if let report = PrepQueueService.settleReachabilityProbe(slot: slot, into: context, now: Date()) {
                recordCheckPace(slot: slot, lookups: checkLookups, cancelled: report.cancelled)
                reportReachabilityRun(report)
            } else {
                ingestPrep()
            }
        case .finishedEmpty:
            // #1940: the case that made the release necessary. The run ended having written nothing, so
            // PrepImporter never sees this run at all and nothing else would ever clear the re-prep flags
            // it was carrying, leaving a readable draft out of the Review count indefinitely (L45).
            // #2760: scoped to the shows THIS run was carrying. Over the whole store, a check finishing
            // empty gives back the re-prep requests the prep slot is holding, and a show goes back to
            // Review in the middle of being drafted.
            ReprepRelease.releaseAfterRun(in: context, carrying: keysCarriedBy(slot))
            if let report = PrepQueueService.settleReachabilityProbe(slot: slot, into: context, now: Date()) {
                reportReachabilityRun(report)
            } else {
                reportError(DetachedRunOutcome.finishedEmptyMessage(
                    slot == .check ? .reachabilityCheck : .prep,
                    tail: RunLog.tail(8, from: RunLog.url(for: slot))))
            }
        case .idle:
            break
        }
        // #2760 (carrying #2764's requirement): a settle is the other moment the record can have grown,
        // and the moment Dan is looking at what a run produced.
        reportAnyBoundaryViolation()
    }

    // #2760: which shows the run that has just ended was given, read off its own work-list. That is the
    // scope of the re-prep release: over the whole store it reaches shows another live run is carrying.
    private func keysCarriedBy(_ slot: RunSlot) -> Set<String> {
        PrepQueue.keys(inQueueAt: PrepQueueBuilder.queueURL(for: slot))
    }

    // #1878: keep the finished run's work-list and results, since the next run overwrites both. One
    // helper with two callers (the settle above, and launch for a run that ended while Overture was
    // closed), so the two paths cannot archive different things or drift apart.
    //
    // Best effort by construction: archiveFinishedRun never throws, reports its own failure to the
    // problem ledger, and returns an outcome nothing here depends on. The results are the thing Dan paid
    // for; this is a copy of them, and insurance must never be able to cost what it insures.
    private func archiveFinishedRun(slot: RunSlot) {
        PrepRunArchive.archiveFinishedRun(slot: slot,
                                          handoffDirectory: StoreLocation.handoffDirectory,
                                          now: Date())
    }

    // #1613: sweep a Prep run that died rather than finished, and say so. Returns whether there was one,
    // so both callers (the run watcher and the launch path) can stop rather than also running the settle
    // for a run that finished, which would report the same check twice.
    //
    // Dan's call (2026-08-04): Overture clears it itself rather than offering a button. The button it used
    // to offer was Cancel, and Cancel cannot work on a dead run however many times it is pressed, so
    // waiting for a click meant waiting forever. The check it was running is settled on the way through
    // (the sweep does that), so a death never silently discards answers already paid for.
    @discardableResult
    private func sweptADeadRun(slot: RunSlot) -> Bool {
        // Read WHICH kind of run it was before the sweep clears the marker that says so.
        // #1810: the same rule the rest of the app uses, so a died run cannot be named one thing here and
        // another everywhere else.
        // #2760: the check slot holds nothing but checks, so only the prep slot has anything to infer, and
        // that inference is the legacy branch (an upgrade window check still in the old slot).
        let wasProbe: Bool
        if slot == .check {
            wasProbe = true
        } else {
            let marker = (try? ReachabilityProbeMarker.read(from: PrepQueueService.defaultProbeRunURL)) ?? nil
            wasProbe = PrepQueueService.prepSlotRunKind(
                runStartedAt: PrepQueueService.lastRunStartedAt(slot: .prep),
                probeMarkerStartedAt: marker?.startedAt) == .reachabilityCheck
        }
        guard let outcome = PrepQueueService.clearDeadRun(slot: slot, into: context,
                                                          now: Date()) else { return false }
        // #1940: a run that died is a run that ended, so the re-prep requests it was carrying come back
        // here too. Without this the one way a run can end that produces nothing AND says so is the one
        // way a show never returns to Review.
        // #2760: this run's own shows, for the same reason the empty-run path is scoped.
        ReprepRelease.releaseAfterRun(in: context, carrying: keysCarriedBy(slot))
        if let report = outcome.probeReport { reportReachabilityRun(report) }
        // .warning, not .info: an .info write can be silently overwritten by a later routine receipt, and
        // a run Dan was waiting on having died is the one thing about it he has to see.
        status.set(RunProgressCopy.diedLine(phase: wasProbe ? .probing : .prepping), priority: .warning)
        return true
    }

    // #1769: a check that came home partial says so. The sentence itself lives in ReachabilityRunSummary,
    // where a test can read it (#863): assembled here in the view body it would be unreachable by any test,
    // which is how the shortfall came to be computed and discarded in the first place.
    //
    // .warning for the same reason a Prep run's shortfall is: an .info write can be silently overwritten by
    // a later routine receipt, and this is the one thing about a run that long Dan has to see.
    // #1616: teach the wait estimate what this check actually took. Called on the produced-results path
    // only, which is the one unambiguous "the run worked through its list and finished" signal, and the
    // same rule `recordReadingRun` follows next door.
    //
    // The wall clock is the runner's own recording (`runCost.durationMs` in the results file), not elapsed
    // time measured here: the run is detached, so anything timed from inside the app also counts however
    // long Overture took to notice it had ended. Whether the sample counts at all is
    // ProbeRunPaceRecording's decision, so the rule sits where a test can reach it rather than in a view.
    // Best-effort in both directions: this must never disturb a run that has just settled paid-for answers.
    //
    // #2978: THIS run's results file, from the slot that just settled, never `PrepImporter.defaultURL`.
    // That default is the prep slot, and since #2760 a check has its own, so the pace being learned was
    // whatever the other slot happened to be holding. Measured on the live store on 2026-08-18: one stale
    // prep-slot reading (301470ms over 6 streams, from two days earlier) was filed as two different
    // checks' pace, while the two checks that actually ran that day recorded nothing at all. The legacy
    // path still reads the prep file, because for a check sitting in the prep slot that genuinely IS its
    // file, which is the one case the old line was accidentally right about.
    private func recordCheckPace(slot: RunSlot, lookups: Int?, cancelled: Bool) {
        ProbeDurationHistoryStore.record(
            ProbeRunPaceRecording.sample(lookups: lookups,
                                         cost: RecordedRunCost.complete(
                                            contentsOf: PrepImporter.resultsURL(for: slot)),
                                         cancelled: cancelled))
    }

    private func reportReachabilityRun(_ report: ReachabilityRunReport) {
        guard let message = report.attentionMessage else { return }
        // #1805: the report carries the offer to finish what the run missed. Whether there is anything
        // LEFT to finish is decided where the queue's rows are (QueueView strips an action it cannot
        // serve), because this view has no rows: a shortfall sentence for shows since answered would
        // otherwise put a control on screen that starts a run over nobody.
        status.set(message, priority: .warning, action: .finishShowsACheckMissed)
    }

    // #1143: watch for a Prep run to begin (a per-row Re-prep click, an explicit "Prep kept" run, a
    // reachability check, or one in flight at launch) and follow it to completion. One watcher owns every
    // run, so there is a single ingest and takeover path rather than a per-launch Task at each start site.
    //
    // #1938: it is TOLD, rather than asking. This used to stat the run marker every three seconds for the
    // whole life of the window, whether or not a run had ever started, which is the shape #1923 removed
    // from the reply side. A run the app starts announces itself from the service, and a run a previous
    // launch left in flight is caught by the one stat DetachedRunActivity makes when it is first built, so
    // an idle window pays nothing at all. The poll survives inside followUntilFinished, where a run really
    // is in flight, because a detached run ends without telling anyone.
    // #2760: one watcher per slot, each holding its OWN DetachedRunActivity. The single activity was wired
    // as the default `announce:` of both launches and opens `runStarted()` with
    // `guard !isRunning else { return }`, so a check launched during a live prep woke nothing at all.
    private func watchRuns(slot: RunSlot) async {
        let activity = DetachedRunActivity.forSlot(slot)
        for await _ in activity.runStarts() {
            takeover.show(slot)
            if await activity.followUntilFinished() {
                await settleFinishedRun(slot: slot)
            }
        }
    }

    // #2760: what a launch finds already on disk for one slot. Its own function so the two slots cannot
    // drift, and so the prep slot's legacy branch is the only place `RunKind.of` still decides anything.
    private func reattachOrSettle(slot: RunSlot) {
        if PrepQueueService.isRunning(slot: slot, now: Date()) {
            // #1130: a detached run outlives the app, so one can still be going at launch. Reopen the
            // takeover so a live run is never invisible; the continuous watcher above follows it to
            // completion, so this no longer awaits here (which also stops an in-flight run from blocking
            // the scout reattach that follows).
            takeover.show(slot)
        } else if sweptADeadRun(slot: slot) {
            // #1613: a run that DIED while Overture was closed leaves its marker standing, because the
            // runner never reached the exit that removes it. Swept here, before the orphan settle below,
            // because the sweep performs that settle itself and reports the death as well: the two must
            // not both run and report the same check twice.
        } else if let report = PrepQueueService.settleOrphanedProbe(slot: slot, into: context,
                                                                    now: Date()) {
            // #1809: a check that finished while Overture was CLOSED. The run watcher only settles a run
            // it is watching, and the detached runner removes its own marker on exit, so without this the
            // check is never settled at all: its paid answers never land, and the marker it leaves behind
            // makes the next Prep run read as a check and discard every draft it wrote. #1765 is what made
            // that likely, since a check is no longer capped at about eleven minutes.
            reportReachabilityRun(report)
        } else if slot == .prep {
            ingestPrep()
        }
    }

    // #2760 (carrying #2764's requirement). `.warning`, and for the reason the dead-run notice is: an
    // `.info` write can be silently overwritten by a later routine receipt, and this is the record of paid
    // work having been destroyed.
    private func reportAnyBoundaryViolation() {
        guard let message = RunBoundaryViolations.newlyReported(in: StoreLocation.handoffDirectory) else {
            return
        }
        status.set(message, priority: .warning)
    }

    // #802: the scout's reading half. The extract run is detached, so without this the pages it read
    // would sit in a results file nobody opens until the next launch, and Dan's scout would look like it
    // had found nothing. Mirrors the Prep watcher deliberately: wait for the live run, then ingest at once,
    // or say plainly that it finished without producing anything.
    //
    // A run that finished empty is NOT silence. It is the one shape of failure that would otherwise be
    // indistinguishable from every watched calendar happening to be quiet.
    // #1027: returns what the read produced so runScout can fold it into ONE end-of-scout popup, instead
    // of setting a warning here (mid-run, before the popup) as it used to. The finishedEmpty message is
    // its own return, because that signal (the reader ran and produced nothing) has no source to attach to.
    // #1054: what a scout-extract read produced. Richer than the old (outcome, finishedEmpty) tuple so one
    // case can carry "cancelled with partial shows, deliberately NOT imported yet" up to the caller, which
    // then shows Dan the keep-or-discard prompt instead of importing them silently.
    private enum ScoutReadResult {
        case ingested(ScoutService.Outcome?)
        case finishedEmpty(String)
        case idle
        case cancelledWithPartial(readCount: Int)
        // #2104: the read stopped without reaching its own exit. Distinct from `finishedEmpty`, which is a
        // run that WORKED and found nothing: a death produced at best a partial file and is worth saying
        // out loud, where an empty read is routine. Collapsing the two would be the L10 defect, an error
        // wearing an empty state's clothes.
        case died(String)
    }

    // #1427: record this Reading-calendars run's pace for the "~X remaining" estimate, but ONLY for a run
    // that finished normally. Called on the `.ingested` path alone: a produced-and-imported result is the
    // one unambiguous "the detached run worked through its queue and finished" signal. `.finishedEmpty` is
    // deliberately excluded, because it cannot be told apart from a run that crashed early producing nothing,
    // whose tiny elapsed would poison the pace toward too-optimistic. A run past its own timeout is excluded
    // too (a stall's timing is not real pace), as are degenerate zero counts. Best-effort: the write never
    // touches the live store and never disturbs the run.
    private func recordReadingRun(elapsed: TimeInterval?) {
        guard let elapsed, elapsed > 0, elapsed < RunTimeouts.scoutExtract,
              readingSourceCount > 0 else { return }
        RunDurationHistoryStore.record(sources: readingSourceCount, seconds: elapsed)
    }

    private func watchScoutExtractRun() async -> ScoutReadResult {
        while ScoutExtractService.isRunning(now: Date()) {
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
        }
        // #2104: the read has stopped being live, which happens two ways. A marker still present means it
        // died somewhere it never reached the exit that removes it, so the results file below holds at
        // best a partial read and Cancel can no longer reach it. Swept and named, rather than falling
        // through to a phase check that would report a dead run as one that simply found nothing.
        if ScoutExtractService.clearDeadRun(now: Date()) {
            return .died(RunProgressCopy.diedLine(phase: .reading))
        }
        let started = ScoutExtractService.lastRunStartedAt
        let resultsMod = FileTimestamp.modifiedAt(ScoutExtractResultsDecoder.defaultURL)   // #2105
        switch DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: resultsMod ?? nil) {
        case .producedResults:
            // #1054: a read Dan cancelled is not imported here. The decision (ask, and with what count) is
            // the pure CancelledReadDisposition, so the rule stays testable rather than living in the view.
            switch CancelledReadDisposition.decide(
                cancelled: scoutCancelRequested,
                readCount: scoutCancelRequested ? pendingCancelledReadCount() : 0) {
            case .ingest:
                return .ingested(ingestScoutExtract())
            case .promptKeepOrDiscard(let count):
                return .cancelledWithPartial(readCount: count)
            case .discardSilently:
                ScoutExtractResultsDecoder.discard()   // nothing usable to keep; do not leave it to reattach
                return .idle
            }
        case .finishedEmpty:
            return .finishedEmpty(DetachedRunOutcome.finishedEmptyMessage(
                .scoutExtract, tail: RunLog.tail(8, from: RunLog.scoutExtractURL)))
        case .idle:
            return .idle
        }
    }

    // #1054: how many shows the cancelled read wrote that would actually survive the guard, read from the
    // same results file the ingest would use, without importing anything.
    private func pendingCancelledReadCount() -> Int {
        // #2879: recorded, because this is the same file the ingest below reads, and this count is what
        // Dan is shown when he is asked whether to keep a cancelled read.
        guard let results = HandoffFile.read(at: ScoutExtractResultsDecoder.defaultURL,
                                             decode: ScoutExtractResultsDecoder.decode).value else { return 0 }
        return results.usableEventCount
    }

    @discardableResult
    private func ingestScoutExtract() -> ScoutService.Outcome? {
        // #2879: THE SCOUT SIBLING of #2873, the same line for the third time. A results file the
        // decoder refused returned nil here, which every caller reads as "the run produced nothing", so
        // a whole extract run's shows could be dropped in silence. The answer to the caller is unchanged;
        // the failure is now recorded against the file and reaches the masthead.
        guard let results = HandoffFile.read(at: ScoutExtractResultsDecoder.defaultURL,
                                             decode: ScoutExtractResultsDecoder.decode).value else { return nil }
        let loaded = DownbeatBridge.loadWithHealth(now: Date())
        let existing = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let outcome = ScoutExtractIngest.ingest(
            results, clients: loaded.clients,
            history: LocalHistory.forMatching(existing: existing),
            blocked: ScoutService.blockedCalendar(export: (loaded.bookings, loaded.blockedDates),
                                                  context: context),
            into: context)

        scoutSummary = ScoutRunSummary.watchedCalendarSummary(for: outcome)   // #885
        return outcome
    }

    // The reply drafter's completion half (#435): the classify+drafter run is detached, so without this
    // a finished draft only surfaced on the NEXT app launch (the bare spinner spun until then). Mirrors
    // the Prep watcher: once the live run ends, ingest immediately (clearing the per-recipient spinner) or
    // report that it finished without a draft. A single continuous watcher (below) drives this so it
    // covers every launch source: the at-launch auto run, an in-flight run, AND a "Draft a reply" click.
    //
    // #1923: called only after DetachedRunActivity has followed a real run to its end, so the waiting
    // itself is no longer here. That matters beyond tidiness: this is the ingest, and running it for a
    // run that was never followed would re-apply a finished run's results.
    private func ingestFinishedReplyClassifyRun() {
        let started = ReplyClassifyService.lastRunStartedAt
        let resultsMod = FileTimestamp.modifiedAt(ReplyClassifyImporter.defaultURL)   // #2105
        switch DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: resultsMod ?? nil) {
        case .producedResults:
            ingestReplyClassifications()
        case .finishedEmpty:
            reportError(DetachedRunOutcome.finishedEmptyMessage(
                .replyClassify, tail: RunLog.tail(8, from: RunLog.replyClassifyURL)))
        case .idle:
            break
        }
    }

    // Watch for a reply-classify run to begin (a click, the at-launch auto run, or one in flight at open)
    // and follow it to completion, so an old failed run never re-nags on a normal open (#48).
    //
    // #1923: this used to stat the run marker every three seconds for the whole life of the window,
    // whether or not a run had ever started, which on an idle Mac is thousands of filesystem calls a day
    // to learn nothing. It waits now: `runStarts()` is told when a run begins rather than looking for
    // one, and DetachedRunActivity's own poll is what follows a live run to its end. The ingest happens
    // only when a run was genuinely followed, so a wake-up can never re-apply a finished run's results.
    private func watchReplyClassifyRuns() async {
        let activity = DetachedRunActivity.replyClassify
        for await _ in activity.runStarts() {
            if await activity.followUntilFinished() {
                // #2104: a run can end two ways. A marker still present when it stops being live means it
                // died somewhere it never reached the exit that removes it, so there are no drafts coming
                // and the ingest below has nothing to do. Say so instead of falling silently quiet, which
                // is indistinguishable from a run that found nothing to reply to.
                if ReplyClassifyService.clearDeadRun(now: Date()) {
                    status.set(RunProgressCopy.diedLineForReplies, priority: .warning)
                    continue
                }
                ingestFinishedReplyClassifyRun()
            }
        }
    }

    // MARK: - #2202: raising something Dan has to answer

    // Every sheet this view can present. A question raised while one of these is up would queue behind
    // it and never appear, so raising closes all of them.
    //
    // Maintained as one list rather than each raiser remembering: `RootViewModalGuardTests` derives the
    // set from the `.sheet(isPresented:)` modifiers in this file and fails when one is missing here, so a
    // sheet added later cannot quietly become a place questions go to die (L41).
    private func closeEveryPresentedSheet() {
        addLead.isPresented = false
        dayOffOffer.pending = nil
        scoutSheetShown = false
        showArchive = false
        showPatterns = false
        showInquiryIntake = false
        showFollowUps = false
        showVoiceGuidance = false
        showPrepSelection = false
        // #2760: every slot's takeover, since this is the close-everything path.
        for slot in RunSlot.allCases { takeover.hide(slot) }
        showSources = false
        showDaysOff = false
        showExcludedTowns = false
        showOrganisations = false
        showOmniFocusSettings = false
    }

    // The four raisers. Nothing else in this file may assign these states to a non-nil value: that is the
    // invariant the guard test pins, because a single forgotten raise site is a whole error message Dan
    // never sees.
    private func reportError(_ message: String) {
        modals.raise { errorMessage = message }
    }

    private func reportGmailConnectError(_ message: String) {
        modals.raise { gmailConnectError = message }
    }

    private func askAboutCancelledRead(count: Int) {
        modals.raise { cancelledScoutRead = count }
    }

    // #2200: the read-budget question, which is the instance that surfaced the whole class. A manual
    // scout that finds more than ScoutReadBudget's threshold suspends here and waits, and this used to be
    // raised straight into a window already presenting the progress takeover, so all 68 sources fetched,
    // the takeover froze at "68 of 68 done" and kept counting, and the run waited on an answer that could
    // not be given.
    //
    // The takeover comes BACK once he answers (`answerReadAsk`), because the run is not over: it still
    // has the reading, the reconcile and the saves to do, and a run that carried on with nothing on
    // screen would be the same invisibility from the other end.
    private func askReadBudget(_ ask: ScoutReadAsk) {
        modals.raise { scoutReadAsk = ask }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil; modals.settled() } })
    }

    // #1163: drives the Gmail-connect failure alert, which unlike the shared error alert offers a Try again.
    private var gmailConnectErrorBinding: Binding<Bool> {
        Binding(get: { gmailConnectError != nil }, set: { if !$0 { gmailConnectError = nil; modals.settled() } })
    }

    // #1054: presents the keep-or-discard alert while a cancelled read is awaiting Dan's choice.
    private var cancelledReadBinding: Binding<Bool> {
        Binding(get: { cancelledScoutRead != nil }, set: { if !$0 { cancelledScoutRead = nil; modals.settled() } })
    }

    // #1498: same shape as the binding above, with one addition that matters. Any dismissal that is not a
    // button (Escape, a click away, the window going down) lands in the setter with false, and it MUST
    // still answer the sweep: a run left suspended on an unanswered continuation shows as the takeover
    // modal spinning forever on a scout that can never finish. `replyIfUnanswered` is a no-op when a
    // button already answered, so the ordinary path is unaffected.
    private var scoutReadAskBinding: Binding<Bool> {
        Binding(get: { scoutReadAsk != nil },
                set: { presented in
                    guard !presented else { return }
                    scoutReadAsk?.replyIfUnanswered()
                    scoutReadAsk = nil
                    modals.settled()
                    // #2200: whichever way the question went away, the run carries on, so put the
                    // takeover back. Including the dismissal routes (Escape, a click away), which answer
                    // `.none` and still leave a sweep with reconciling and saving left to report.
                    if isScanning { scoutSheetShown = true }
                })
    }

    // Answer, then clear. Clearing goes through the binding above, so the one-shot on ScoutReadAsk is what
    // stops the dismissal that follows from resuming the continuation a second time.
    private func answerReadAsk(_ ask: ScoutReadAsk, _ choice: ScoutReadBudget.Choice) {
        ask.reply(choice)
        scoutReadAsk = nil
        modals.settled()
        // #2200: the run is not over. See askReadBudget.
        if isScanning { scoutSheetShown = true }
    }

    // Run a scout automatically when the daily schedule says one is due and auto-scout is
    // on (#33). Safe to trigger unattended: the scout only reads/extracts, never sends.
    // Ingest classifications a prior reply-classify run wrote (suggests states, auto). No-op if the
    // results file isn't there yet.
    private func ingestReplyClassifications() {
        // #2873: this used to be `guard let outcome = try? ...ingestFile(...) else { return }`, which made
        // a results file the decoder refused indistinguishable from no file at all. Every AI reply draft
        // was dropped in silence, for months, while the reply sheet showed a spinner over the empty box.
        let outcome: ReplyClassifyImporter.Outcome
        switch ReplyClassifyImporter.read(at: ReplyClassifyImporter.defaultURL, into: context) {
        case .nothingToRead:
            return
        case .unreadable(let reason):
            status.set(ReplyClassifyRunSummary.unreadableMessage(reason: reason), priority: .warning)
            return
        case .ingested(let read):
            outcome = read
        }
        // #499: this run's intent hints/drafts were written in memory but never persisted. The save
        // failure is the actionable one, so it wins the single status line.
        //
        // Dan (2026-07-18): both branches here are already shortfall/failure-only (ReplyClassifyRunSummary is
        // scoped to the drop count on purpose, never a routine "N replies classified" tally), so both
        // are worth .warning, the same tier as the scout's own unattended-run warning.
        if outcome.saveFailed {
            status.set("Reply-classify results couldn't save. Try again.", priority: .warning)
        } else if let message = ReplyClassifyRunSummary.statusMessage(for: outcome) {
            // #1018: replies the run never came back with, so a silently dropped reply is no longer invisible.
            status.set(message, priority: .warning)
        }
    }

    // Launch a reply-classify run for replies still needing an intent. Throws (and is swallowed)
    // when nothing needs classifying or the runner isn't configured, so it never disrupts launch.
    private func startReplyClassifyIfNeeded() {
        guard !ReplyClassifyService.isRunning(now: Date()) else { return }
        _ = try? ReplyClassifyService.startClassify(from: context, now: Date())
    }

    private func autoScoutIfDue() {
        guard ScoutSchedule.shouldAutoScout(enabled: autoScoutEnabled, isScanning: isScanning,
                                            lastScoutedAt: ScoutService.lastScoutedAt(), now: Date()) else { return }
        // #802, Dan's 4th decision: the automatic run WATCHES and spends nothing. It fetches and hashes
        // every source, so a dead one is noticed within a day rather than whenever he next scouts by
        // hand, and it never launches a claude -p run. Carnegie still fully ingests on it: its Algolia
        // path is native and free, so today's behavior is preserved exactly.
        runScout(auto: true, depth: .watchOnly)
    }

    private func runScout(auto: Bool = false, depth: ScoutDepth = .readChanged,
                          only: Set<String>? = nil) {
        // #1027: never start a second run over a run already in flight, in EITHER phase. isScanning
        // covers the native sweep; readingStartedAt covers the detached read (isScanning is already
        // false by then). Without this, a double-tap of "Read the ones I fixed" starts two runs, and the
        // second dies on the extract runner's already-running guard.
        guard !isScanning, readingStartedAt == nil else { return }
        // #2208: and the read that is still running in the BACKGROUND, which the guard above cannot see:
        // `readingStartedAt` goes nil the moment the takeover is hidden and the app moves on. Without
        // this, pressing Run scout swept all 68 sources, fetched and hashed every one, worked out which
        // had changed, and only then discovered it could not hand them off.
        if case .waitForTheReader(let why) = ScoutStartGate.decide(
            readerIsRunning: ScoutExtractService.isRunning(now: Date()), depth: depth, auto: auto,
            // The learned pace applied to the read that is actually in flight. nil when the history is
            // too thin to have learned one, which leaves the sentence claiming no estimate at all.
            remaining: {
                let live = RunProgressView.Snapshot.liveReading()
                return RunDurationHistoryStore.load().remaining(total: live.total, completed: live.completed)
            }()) {
            feedback.acknowledge(why, tone: .warning)
            return
        }
        scoutGeneration += 1
        let gen = scoutGeneration   // this run's token; a Retry bumps it so an abandoned Task no-ops
        isScanning = true
        scoutStartedAt = Date()
        scoutSummary = nil
        scoutNativeSnapshot = nil
        scoutCancelRequested = false   // #1037: a fresh run starts un-cancelled
        // #1034: a scout Dan STARTED takes over the screen with the progress modal; the scheduled
        // watch-only run keeps its quiet toolbar label and never pops it (his call, #1010).
        if !auto {
            scoutIsManual = true
            scoutWarnings = nil       // fresh run: the sheet shows progress, not last run's summary
            scoutSheetShown = true
        }
        scoutTask = Task {
            do {
                let outcome = try await ScoutService.runScout(
                    into: context, depth: depth, only: only,
                    // #1034: the native "Scouting" phase heartbeat feeds the modal's source name and
                    // "3 of 9". Guarded so an abandoned run's late callback cannot move a fresh run's bar.
                    onNativeProgress: { name, index, total in
                        guard gen == scoutGeneration else { return }
                        // #1530: stamped as it lands, which is what tells the takeover a long sweep is
                        // working rather than stuck. A sweep through all 62 sources (#1518) passes the
                        // 3-minute ceiling every run, so without this every scout ended by warning that
                        // it looked stuck. Carried on the snapshot so it clears with it.
                        scoutNativeSnapshot = .init(sourceName: name, completed: index, total: total,
                                                    advancedAt: Date())
                    },
                    // #2203: the SAME phase, once its counted part is done. Keeps `advancedAt` moving
                    // across the tail (the read hand-off, the booking reconcile, the retirement, the
                    // saves), which is both what the screen says and its only evidence of still being
                    // alive. Without it a slow tail was judged stuck by the wall clock alone.
                    onNativeStep: { step in
                        guard gen == scoutGeneration else { return }
                        scoutNativeSnapshot = .init(sourceName: nil,
                                                    completed: scoutNativeSnapshot?.completed ?? 0,
                                                    total: scoutNativeSnapshot?.total ?? 0,
                                                    advancedAt: Date(), step: step)
                    },
                    // #1037: the native sweep stops between sources when Dan cancels, and launches no read.
                    isCancelled: { scoutCancelRequested },
                    // #1498: the one question in the run, asked only when more pages need reading than
                    // ScoutReadBudget's threshold. An abandoned run must not put a question on screen for
                    // a run Dan already replaced, and it must not leave the sweep awaiting an answer that
                    // can never come, so a superseded generation answers itself with `.none`: it reads
                    // nothing, and every page stays flagged for the run that replaced it.
                    askReadBudget: { pending in
                        guard gen == scoutGeneration, !scoutCancelRequested else { return .none }
                        return await withCheckedContinuation { continuation in
                            askReadBudget(ScoutReadAsk(pending: pending) { continuation.resume(returning: $0) })
                        }
                    })
                guard gen == scoutGeneration else { return }   // superseded by a Retry / newer run
                scoutSummary = ScoutRunSummary.summary(for: outcome)   // #885

                // #802, Dan's 3rd decision: SHOW him the do-not-contact guard working. An org that asked
                // him to stop can still turn up on a venue's calendar he legitimately watches, and #769
                // suppresses each of those silently. Silent is the problem: on the one mistake that
                // cannot be taken back he would rather see the guard working than trust that it is.
                //
                // Deliberately the STATUS line and not the warning line. Nothing is wrong, nothing needs
                // fixing, and putting a receipt in the warning slot would teach him to dismiss warnings.
                status.set(SuppressionReport.summary(for: outcome.suppressedOrgs))

                // #802: the native half is done and shown. The pages that CHANGED are being read by a
                // detached run right now, and its results land minutes later, so follow it to completion
                // and ingest at once. Without this, Dan's scout would report Carnegie's numbers and then
                // sit on a results file it never opened, and the watched calendars would look empty.
                //
                // Dan sees Carnegie immediately and the watched calendars when they land. He is never
                // shown a total that silently omits half the run.
                isScanning = false
                scoutStartedAt = nil
                var extract: ScoutService.Outcome? = nil
                var finishedEmpty: String? = nil
                if outcome.sources.contains(where: { $0.state == .queuedForReading }) {
                    // #1034: the modal now flips to its "Reading calendars" phase, naming each source as
                    // it lands (the queue/results diff) and counting the run's own "3 of 9", with a
                    // stalled state if the detached run dies.
                    readingStartedAt = ScoutExtractService.lastRunStartedAt ?? Date()
                    readingSourceCount = outcome.sources.filter { $0.state == .queuedForReading }.count
                    scoutNativeSnapshot = nil
                    let read = await watchScoutExtractRun()
                    guard gen == scoutGeneration else { return }
                    // #1427: the read's elapsed, captured before readingStartedAt is cleared, so a normal
                    // completion can record its pace.
                    let readingElapsed = readingStartedAt.map { Date().timeIntervalSince($0) }
                    readingStartedAt = nil
                    switch read {
                    case .ingested(let o):
                        extract = o
                        recordReadingRun(elapsed: readingElapsed)
                    case .finishedEmpty(let m): finishedEmpty = m
                    case .idle: break
                    case .died(let message):
                        // #2104: falls through to finishScout like any other empty-handed ending, so the
                        // run UI still closes; the death itself rides the status line at .warning, where
                        // a later routine receipt cannot quietly overwrite it.
                        status.set(message, priority: .warning)
                    case .cancelledWithPartial(let count):
                        // #1054: a cancelled read's shows are not imported yet. Wind the run down and hand
                        // the keep-or-discard choice to Dan; its buttons own what happens next, so skip
                        // finishScout (which would quietly close a cancelled run and drop the choice).
                        presentCancelledRead(count: count)
                        return
                    }
                }
                // #1027/#1034: ONE surface at the true end of the whole run. A manual run's takeover
                // becomes the branded summary in place; an unattended scheduled run leaves a quiet line.
                finishScout(ScoutWarnings.from(native: outcome, extract: extract,
                                               finishedEmpty: finishedEmpty), auto: auto)
                return
            } catch {
                guard gen == scoutGeneration else { return }
                // A scheduled run failing stays quiet (a status line); a manual run shows
                // the modal Dan expects after clicking (#77).
                let p = ScoutFailure.presentation(auto: auto, message: String(describing: error))
                if let status = p.status { scoutSummary = status }
                if let alert = p.alert {
                    // The takeover is closed by the raise itself now (#2202), so the alert is what Dan
                    // sees rather than a frozen progress screen with a question behind it.
                    reportError(alert)
                } else {
                    // A scheduled run says it quietly, and the takeover still must not sit there
                    // implying a run that has already died.
                    scoutSheetShown = false
                }
            }
            guard gen == scoutGeneration else { return }
            isScanning = false
            scoutStartedAt = nil
            scoutIsManual = false
            scoutNativeSnapshot = nil
        }
    }

    // #1027/#1034: how a finished run surfaces what it found. A MANUAL run's takeover sheet becomes the
    // branded summary (or just closes when there is nothing to say); an unattended scheduled run he did
    // not start leaves a quiet masthead line and never pops a modal (his call).
    private func finishScout(_ warnings: ScoutWarnings, auto: Bool) {
        isScanning = false
        scoutStartedAt = nil
        readingStartedAt = nil
        scoutIsManual = false
        scoutNativeSnapshot = nil
        // #1037: a run Dan stopped closes quietly. It gets no summary popup: he abandoned it, so the
        // partial warnings are not something he asked to see, and cancelScout already closed the sheet.
        if scoutCancelRequested {
            scoutCancelRequested = false
            scoutSheetShown = false
            return
        }
        switch ScoutWarningsPresentation.decide(warnings, auto: auto) {
        case .popup(let w):
            // Setting scoutWarnings swaps the still-presented takeover to the summary in place; setting
            // scoutSheetShown covers the case where Dan had hidden the takeover before it finished.
            scoutWarnings = w
            scoutSheetShown = true
        case .quietLine(let line):
            // #1047: a warning, so a later informational write (a Prep summary, an OmniFocus receipt, a
            // reply-classify note) on this same launch cannot silently erase it before Dan reads it.
            status.set(line, priority: .warning)
            scoutSheetShown = false
        case .nothing:
            scoutSheetShown = false
        }
    }

    // #1035: reattach to a scout-extract read still running at launch. Reopens the takeover in its
    // reading phase (on its own, no click, since Dan started this scout) and follows the run to
    // completion through the SAME watch + finish path a manual run uses, so a reattached run ingests its
    // results and surfaces its warnings rather than being a dead end. The native half already ran (and
    // was reported) in the session that started it, so only the read's own outcome is folded in here.
    private func reattachScoutExtractRun() async {
        scoutGeneration += 1
        let gen = scoutGeneration
        scoutIsManual = true
        scoutNativeSnapshot = nil
        scoutWarnings = nil
        readingStartedAt = ScoutExtractService.lastRunStartedAt ?? Date()
        // #1427: the native half ran in the session that started this run, so its queued count is gone; the
        // run's own live progress file still carries the total it set out to read.
        readingSourceCount = ScoutExtractProgressDecoder.loadCurrent()?.total ?? 0
        scoutSheetShown = true
        let read = await watchScoutExtractRun()
        guard gen == scoutGeneration else { return }
        let readingElapsed = readingStartedAt.map { Date().timeIntervalSince($0) }
        readingStartedAt = nil
        let emptyNative = ScoutService.Outcome(found: 0, inserted: 0, updated: 0, skipped: 0)
        switch read {
        case .ingested(let o):
            recordReadingRun(elapsed: readingElapsed)
            finishScout(ScoutWarnings.from(native: emptyNative, extract: o, finishedEmpty: nil), auto: false)
        case .finishedEmpty(let m):
            finishScout(ScoutWarnings.from(native: emptyNative, extract: nil, finishedEmpty: m), auto: false)
        case .idle:
            finishScout(ScoutWarnings.from(native: emptyNative, extract: nil, finishedEmpty: nil), auto: false)
        case .died(let message):
            // #2104: the case this path is most likely to meet. A read that died while Overture was shut
            // is discovered here, on reattach, and must close the run UI like any other ending rather than
            // leaving the takeover sitting over a run that stopped hours ago.
            status.set(message, priority: .warning)
            finishScout(ScoutWarnings.from(native: emptyNative, extract: nil, finishedEmpty: nil), auto: false)
        case .cancelledWithPartial(let count):
            // #1054: not expected on a reattach (Dan did not cancel this run), but surface the choice
            // rather than importing silently if it ever does.
            presentCancelledRead(count: count)
        }
    }

    // #1037: stop the run for real, cooperatively. The native sweep sees the flag and stops between
    // sources (launching no read); a detached read in flight is stopped by the cancel file the runner
    // checks on its heartbeat. Either way the takeover closes now and the run winds down in the
    // background; finishScout sees the flag and does not pop a summary for a run Dan abandoned. Not
    // instant (the read stops on its next tick), but safe: no source is interrupted mid-write.
    private func cancelScout() {
        scoutCancelRequested = true
        ScoutExtractService.requestCancel()
        // #2201: a run parked on the read-budget question is suspended on a continuation, and a stop that
        // left it there would leak the run rather than end it. `replyIfUnanswered` answers `.none`, which
        // reads nothing and leaves every page flagged for the next press.
        scoutReadAsk?.replyIfUnanswered()
        scoutReadAsk = nil
        modals.settled()
        scoutSheetShown = false
        scoutIsManual = false
    }

    // #354: real "N of M" progress from the run's own progress file, instead of a bare indefinite spinner.
    // #1322: a probe reuses this same run slot, so the compact label names it "Checking reachability"
    // rather than "Prepping".
    //
    // #1822: lifted out of the toolbar's `label:` builder, which the added arguments pushed past the Swift
    // type-checker's limit for one expression. Nothing about the label changed in the move.
    private var prepToolbarLabel: some View {
        // #2760: the run really in flight, whichever slot holds it. `runInFlight` asks both, so the label
        // names a check whether it is in the check slot or (during the upgrade window) still in the prep
        // slot. The exclusion means at most one of them is live, so there is one label to draw.
        let kind = PrepQueueService.runInFlight(now: Date()) ?? .prep
        let isProbe = kind == .reachabilityCheck
        let slot: RunSlot = PrepQueueService.isRunning(slot: .check, now: Date()) ? .check : .prep
        return LiveRunLabel(
            base: RunProgressCopy.title(isProbe ? .probing : .prepping),
            since: PrepQueueService.lastRunStartedAt(slot: slot),
            // #1822: a probe gets its OWN ten-minute window, as the takeover already gives it. Judged
            // against Prep's three minutes, every probe past three minutes was called stuck while it was
            // running perfectly well.
            timeout: isProbe ? RunTimeouts.reachabilityProbe : RunTimeouts.prep,
            // #1822: the heartbeat this label never had. Without it RunProgress.liveness saw no evidence
            // of life at all and called every run past its timeout stuck, inside a branch that renders
            // only BECAUSE isRunning returned true one line above. The label contradicted its own
            // condition for the whole remainder of every long run.
            // #1003: closures, so both this and the count are re-read every tick rather than captured
            // whenever RootView last happened to re-render.
            progressDetail: {
                PrepProgressDecoder.label(for: PrepProgressDecoder.loadCurrent(
                    from: PrepProgressDecoder.progressURL(for: slot)))
            },
            heartbeat: { PrepQueueService.heartbeat(slot: slot, now: Date()) },
            compact: true)
    }

    // #1054: the cancelled read stopped with partial shows. Wind the run down and raise the keep-or-discard
    // prompt; its buttons decide whether those shows enter the queue. Clearing scoutCancelRequested hands
    // the decision to Dan (the flag has done its job of stopping the run).
    private func presentCancelledRead(count: Int) {
        isScanning = false
        scoutStartedAt = nil
        readingStartedAt = nil
        scoutIsManual = false
        scoutNativeSnapshot = nil
        scoutCancelRequested = false
        askAboutCancelledRead(count: count)
    }

    // #1054: Dan kept the cancelled read's shows. Import the partial file the normal way (dedup and
    // classify still apply); they join the queue like any other find.
    private func keepCancelledRead() {
        ingestScoutExtract()
        cancelledScoutRead = nil
        modals.settled()
    }

    // #1054: Dan discarded them. Delete the partial file so the reattach path cannot re-import it on a
    // later launch, and clear the prompt. Nothing enters the queue.
    private func discardCancelledRead() {
        ScoutExtractResultsDecoder.discard()
        cancelledScoutRead = nil
        modals.settled()
    }

    // #1034: the stalled-state Retry. A stalled modal means the run's heartbeat has gone dead, so abandon
    // this watch (its Task's completion is guarded by the generation token) and start a fresh scout,
    // which re-shows the takeover from the top.
    private func retryScout() {
        // #2201: a run parked on a question is not stuck, and Retry cannot rescue it. A Task suspended on
        // `withCheckedContinuation` is not cancellable, so cancelling it leaks the parked run AND its
        // pending question while a second full sweep starts and ends in the same place. Refuse, and put
        // the question back in front of him instead, since answering it is the actual next step.
        //
        // Belt and braces: the panel withholds Retry in this state, so this is the second of two, and it
        // is the one that holds if the button is ever reached another way.
        if let ask = scoutReadAsk { askReadBudget(ask); return }
        scoutTask?.cancel()
        isScanning = false
        readingStartedAt = nil
        scoutStartedAt = nil
        runScout()
    }

    // #1034: the takeover itself. Phase, start, and live providers are read from the run's state; the
    // per-second ticking happens inside RunProgressView's own TimelineView. The reading phase reads its
    // source name and count live from the files the app owns via the shared RunProgressView.Snapshot
    // .liveReading() (#1036 uses the same in AddLeadSheet). The chrome (fixed frame + canvas, centered) is
    // applied HERE because the component itself is sized to content so it can also render inline.
    private var scoutProgressModal: some View {
        VStack {
            Spacer(minLength: 0)
            RunProgressView(
                phase: readingStartedAt != nil ? .reading : .scouting,
                since: readingStartedAt ?? scoutStartedAt,
                snapshot: { readingStartedAt != nil ? RunProgressView.Snapshot.liveReading()
                                                    : (scoutNativeSnapshot ?? .init()) },
                heartbeat: readingStartedAt != nil ? { ScoutExtractService.heartbeat(now: Date()) } : nil,
                // #1427: the reading phase predicts "~X remaining" from past completed runs; every other
                // phase (and a thin history) shows nothing. Loaded each tick so a run recorded moments ago
                // is already in the average.
                durationHistory: readingStartedAt != nil ? { RunDurationHistoryStore.load() } : { nil },
                onRetry: { retryScout() },
                onHide: { scoutSheetShown = false },
                onCancel: { cancelScout() },
                // #2201: parked on the read-budget question. Read live rather than captured, because the
                // panel re-renders every second and the answer can land between two ticks.
                waitingOnAnswer: { scoutReadAsk != nil })
            Spacer(minLength: 0)
        }
        .frame(minWidth: 460, minHeight: 280)
        .background(OVColor.canvas)
    }

    // #1130: the Prep run's takeover, the same shared component and chrome as the scout's, in the .prepping
    // phase. The count comes live from the run's own progress file (livePrepping); the still-alive/stalled
    // state from the run marker via PrepQueueService.isRunning, so a slow-but-living run never flips to
    // "looks stuck". Hide keeps the run going (the toolbar "Prepping" label remains the indicator); Cancel
    // stops it cooperatively. No Retry: a Prep run needs a which-shows selection, so restarting goes back
    // through the picker rather than a one-click retry.
    #if DEBUG
    // Lifted out of the toolbar's `Menu` builder (#2760's edits pushed that whole modifier chain past the
    // Swift type-checker's limit for one expression, the same move #1822 made for `prepToolbarLabel`).
    // Nothing about the menu changed in the move.
    @ViewBuilder
    private var debugMenuItems: some View {
        Button("Seed dev data from live") { debugSeedFromLive() }
        Button("Connect Gmail from live") { debugSeedGmailFromLive() }
        Button("Clear dev data") { debugClearDevData() }
        Button("Mark first as sent") { debugStageFirstAsSent() }
        Button("Stage reminder-due lead") { debugStageReminderLead() }
        Button("Stage self-send test lead") { debugStageSelfSendLead() }
        Button("Stage multi-recipient self-send lead") { debugStageMultiRecipientSelfSendLead() }
        Button("Stage visual-QA scenario (draft + signature + double-booking)") { debugStageVisualQAScenario() }
        Button("Stage warm-register returning-client draft") { debugStageWarmRegisterDraft() }
        Button("Stage re-prep-queued draft") { debugStageReprepQueuedDraft() }
        Button("Stage reachability competition (best-contact highlight)") { debugStageReachabilityCompetition() }
        Button("Stage form-pitch shows (copy-and-confirm, and one already recorded)") { debugStageFormPitchScenario() }
        Button("Clear debug leads") { debugClearDebugLeads() }
    }
    #endif

    // #2760: one sheet over per-slot state. It is up while ANY slot has a takeover, and dismissing it
    // closes only the one on screen, so a run still going keeps its own.
    private var runTakeoverBinding: Binding<Bool> {
        Binding(get: { takeover.presented != nil },
                set: { shown in if !shown { takeover.hidePresented() } })
    }

    private var prepProgressModal: some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            // #2761: ONE LINE PER LIVE RUN, each named, each with its own Cancel. Dan's call, 2026-08-15.
            //
            // Until #3015 the two runs excluded each other, so "the run on screen" was the only run and a
            // single block was the whole truth. Now both can be going, and macOS will not present a second
            // sheet over the first, so one block meant the other run worked entirely unseen. A shared
            // control also cannot say which run it stops, and stopping the wrong paid run is the expensive
            // mistake here.
            //
            // `takeover.shown` rather than `presented`, so the sheet is the sum of what is live rather than
            // whichever got there first.
            ForEach(takeover.shown, id: \.self) { slot in
                runProgressBlock(for: slot)
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 460, minHeight: 280)
        .background(OVColor.canvas)
    }

    // #2761: one run's block. Everything in it was already per slot (#2760); what changed is that the
    // caller now renders one of these for EVERY live run instead of only the first.
    @ViewBuilder private func runProgressBlock(for slot: RunSlot) -> some View {
            // #1824: the launch's own first phase, the app rendering each kept show's listing page. It has
            // no marker file (it runs in process), so its still-alive evidence is the same as the scout
            // sweep's: a count that keeps advancing.
            // #2760: everything below is about the slot on screen, so a check's takeover reads the check's
            // own count, its own marker and its own start.
            if let reading = takeover.listingProgress(slot) {
                RunProgressView(phase: .readingListings,
                                since: takeover.listingStartedAt(slot),
                                snapshot: { reading },
                                onHide: { takeover.hide(slot) })
            } else {
                RunProgressView(
                    // #1322: a probe reuses this same takeover, so it labels itself "Checking reachability"
                    // instead of "Prepping". #2760: the slot says which it is, except in the upgrade window
                    // where a legacy check sits in the prep slot, which is what isProbeRunning still asks.
                    phase: slot == .check || PrepQueueService.isProbeRunning(now: Date())
                        ? .probing : .prepping,
                    since: PrepQueueService.lastRunStartedAt(slot: slot),
                    snapshot: {
                        RunProgressView.Snapshot.livePrepping(
                            progressURL: PrepProgressDecoder.progressURL(for: slot))
                    },
                    heartbeat: { PrepQueueService.heartbeat(slot: slot, now: Date()) },
                    onHide: { takeover.hide(slot) },
                    onCancel: { cancelPrep(slot: slot) },
                    // #1684: the panel acknowledges the click the instant the sentinel lands, rather than
                    // sitting on a spinner identical to a working run until the marker goes stale.
                    cancelRequested: { PrepQueueService.cancelRequested(slot: slot) })
        }
    }

    // Reconcile bookings on launch (#41/#99): auto-book on an exact Downbeat booking match,
    // suggest otherwise, so a booking made in Downbeat shows up without running a scout first.
    // Not gated on a non-empty client list: bookings are an independent array, so an export
    // with bookings but no clients must still reconcile; reconcileBooked gates on export health.
    // Push due conversation reminders into OmniFocus (#176/#231). The desired set is computed here
    // on the main actor (it reads prospects); the slow AppleScript I/O runs off-main in a detached
    // task so a hung Apple event never stalls the UI or the rest of launch. Best-effort: any error,
    // including a denied Automation permission, is swallowed. `force` runs it on an explicit user
    // action regardless of the opt-in (which gates only the automatic launch/data-change syncs).
    private func syncOmniFocus(force: Bool = false) {
        let config = OmniFocusSyncConfig.loaded()
        guard force || config.enabled else { return }
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let desired = OmniFocusSync.desired(from: all, now: Date(), horizonDays: config.horizonDays)
        omniFocusSyncStartedAt = Date()   // #469: drives the live "Syncing…" state on the toolbar item
        // NSAppleScript must run on the main thread. Use a (non-awaited) main-actor task so this
        // doesn't block the launch sequence, but still runs where AppleScript works. The work is a
        // handful of Apple events, so the brief main-actor occupancy is acceptable.
        Task { @MainActor in
            do {
                let result = try OmniFocusSync.apply(desired: desired, client: AppleScriptOmniFocusClient())
                // #2899: carry back what Dan ticked off over there. On the main actor, where the model is.
                if OmniFocusSync.recordCompletions(result.handled, in: all, now: Date()) > 0 {
                    try? context.save()
                }
                // #2882: some tasks refused is neither a clean run nor a dead one. Recorded and shown the
                // same way at both sync sites, through the same message builder, so the launch sync and
                // the scheduled sync cannot describe one state two ways.
                if let message = OmniFocusSync.partialFailureMessage(
                    failures: result.failures,
                    attempted: result.created + result.completed + result.failures.count) {
                    OmniFocusSyncStatus.recordFailure(message, at: Date())
                    if force { reportError(message) }
                    omniFocusSyncStartedAt = nil
                    return
                }
                OmniFocusSyncStatus.recordSuccess(at: Date())   // clears any prior failure warning (#239)
                // Dan (2026-07-18): no routine "N due, N created" receipt here anymore. The OmniFocus toolbar menu
                // already shows "last synced" when opened, and the only thing worth the shared status
                // slot is a failure, handled below.
            } catch {
                // #239: record even the swallowed automatic failure so it stays visible in the masthead.
                OmniFocusSyncStatus.recordFailure("\(error)", at: Date())
                if force { reportError(OmniFocusSync.failureMessage(reason: "\(error)")) }
            }
            omniFocusSyncStartedAt = nil
        }
    }

    // Ingest a Prep results file (found contacts + drafts) if one is present, filling
    // kept prospects and moving them to .drafted for review. Surfaces results that
    // matched no prospect instead of letting them vanish (a separate fallible run).
    private func ingestPrep() {
        // #884: consumed ONCE. This used to re-read whatever results file was still on disk on every
        // single launch, which re-announced an old run's shortfall ("2 didn't come back") days after the
        // fact, re-announced its drafts, and (the real damage) knocked an approved-but-unsent draft back
        // to "needs review", silently undoing Dan's own approval. Nothing to consume, nothing to say.
        let outcome = PrepImporter.consumeIfNew(slot: .prep, into: context)
        // #1940: give back every re-prep this run was carrying and did not serve, so a show whose queued
        // re-prep took it out of the Review count returns to it. AFTER the importer, never before: the
        // importer reads the same two flags to decide which half of a result is in scope, so clearing them
        // first would let a contacts-only re-prep's run overwrite the draft it was told to leave alone.
        // Outside the guard below for the same reason it exists at all: a run that produced nothing new
        // still ended, and the request it was carrying still has to come back.
        // #2760: the prep run's own shows. Over the whole store this reaches shows the check slot is
        // carrying, which is the same defect as the empty-run path's.
        ReprepRelease.releaseAfterRun(in: context, carrying: keysCarriedBy(.prep))
        guard let outcome else { return }
        // #876: every sentence derived from the run's own outcome now lives in PrepRunSummary, where a
        // test can read it. Built here in the view body, this copy was unreachable by any test, which is
        // exactly the shape #863 warns about.
        // #249: fail closed if the distiller leaked a real name into the voice guidance; quarantine
        // the contaminated section so it can't feed a future draft, and warn Dan.
        let leaks = VoiceGuidanceGuard.audit(fileURL: VoiceGuidanceGuard.defaultURL,
                                             prospects: (try? context.fetch(FetchDescriptor<Prospect>())) ?? [])
        // #251: if the run altered or dropped Dan's hand-written notes, restore them from the pre-run
        // backup (the fresh auto section is kept).
        let restored = VoiceNotesProtector.restoreIfNeeded(fileURL: VoiceGuidanceGuard.defaultURL,
                                                           backupURL: VoiceNotesProtector.defaultBackupURL)
        // #885: the WHOLE sentence, including the two notes above and the prefix, now comes from
        // PrepRunSummary. #876 extracted half of it and left the rest here, so a green test of that type
        // said nothing about the line Dan actually reads.
        // Dan (2026-07-18): only what needs Dan's attention lands here now; the routine "N drafted" tally is dropped
        // (the queue already shows it), and what remains is promoted to .warning so it can't be silently
        // overwritten by a later routine receipt the way an .info write could be.
        if let message = PrepRunSummary.attentionMessage(for: outcome, voiceGuidanceLeaked: !leaks.isEmpty,
                                                          guidanceNotesRestored: restored) {
            status.set(message, priority: .warning)
        }
    }
}
