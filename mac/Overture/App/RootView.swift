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
    @State private var followUpsHighlightRecipientId: String?
    @State private var showVoiceGuidance = false
    // #1435/#1436: the "Log an inquiry" intake sheet, opened from the same grouped menu as "Add a lead".
    @State private var showInquiryIntake = false
    @State private var showPrepSelection = false   // #953: the per-run "which kept shows to prep" picker
    @State private var prepSheetShown = false      // #1130: the Prep run's takeover progress screen
    // #1824: the app's own listing-page read, which runs before the detached Prep run launches. Non-nil
    // only while that phase is in flight, which is also what routes the takeover to it.
    @State private var listingReadProgress: RunProgressView.Snapshot?
    @State private var listingReadStartedAt: Date?
    @State private var showSources = false
    @State private var showDaysOff = false      // #901
    @State private var showExcludedTowns = false   // #1118: review and un-exclude skipped towns
    @State private var showOrganisations = false   // #1731: what Overture reads as a building
    @State private var showReminderSettings = false   // #931: rehomed reminder-timing settings
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
        DueWork.counts(prospects: allProspects, now: Date(), reminder: .loaded()).total
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

    private var daysOffReason: DaysOffAttention.Reason {
        DaysOffAttention.reason(
            ScoutService.blockedCalendar(export: DownbeatBridge.loadedExport(), context: context),
            feedStalled: DownbeatFeedFreshness.isStalled(lastNewAt: feedLastNewAt, now: Date()))
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
        let scope = StageNavigation.stagedKeys(in: nonDismissedProspects, reachedOutKeys: reachedOutKeys, geo: geo)
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
                                        reachedOutKeys: reachedOutKeys, geo: geo) {
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

    private var canStartPrep: Bool {
        !toPrep.isEmpty && !PrepQueueService.isRunning(now: Date())
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

    var body: some View {
        // The search bar lives here in the window body, not the toolbar: confirmed against the
        // running app that a native NSToolbar item cannot anchor a SwiftUI .popover at all (the
        // results dropdown silently never appeared), while the identical field embedded in
        // Archive's own body works correctly. This still reads as "persistent" per the design
        // (always visible above the Queue, not tucked into a menu), just not toolbar-hosted.
        VStack(spacing: 0) {
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

    private var queueContent: some View {
        QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys, onConnectGmail: connectGmail,
                  onShowFollowUps: { showFollowUps = true },
                  onShowFollowUpsFor: { recipientId in
                      followUpsHighlightRecipientId = recipientId
                      showFollowUps = true
                  },
                  onOpenInArchive: { key, recipientId in
                      openArchive(key: key, recipientId: recipientId)
                  },
                  // #1129: the Prep stage's discoverable "Prep these N" button opens the same #953 per-run
                  // selection sheet the toolbar menu and Cmd+P do, so there is one Prep-start path, not two.
                  onStartPrep: { showPrepSelection = true },
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
                // #1411: both branches hand macOS a BARE view (a Label, a Text), and macOS sizes the
                // capsule it draws to exactly that. Every other toolbar item is a Button or a Menu and
                // brings its own control insets, which is why this was the only slot whose text sat hard
                // against the edge. The inset is the app's ordinary pill inset, applied through one
                // modifier so the two branches cannot drift.
                ToolbarItem(placement: .status) {
                    if omniFocusFailedAt > 0 {
                        Label("OmniFocus sync failing", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .toolbarStatusInset()
                            .help("The automatic OmniFocus sync last failed, so follow-up tasks may not be getting created. Click \"Sync to OmniFocus\" to retry, and check that OmniFocus is installed and has Automation permission. A successful sync clears this.")
                    } else if let text = status.text {
                        Text(text)
                            .font(.system(size: 11))
                            .foregroundStyle(OVColor.inkFaint)
                            .toolbarStatusInset()
                    }
                }
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
                        .disabled(!canStartPrep)
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
                        if PrepQueueService.isRunning(now: Date()) {
                            Divider()
                            Button("Cancel prep", role: .destructive) { cancelPrep() }
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
                        } else if PrepQueueService.isRunning(now: Date()) {
                            // #354: real "N of M" progress from the run's own progress file,
                            // instead of a bare indefinite spinner. #1322: a probe reuses this same run
                            // slot, so the compact label names it "Checking reachability" not "Prepping".
                            LiveRunLabel(base: RunProgressCopy.title(
                                            PrepQueueService.isProbeRunning(now: Date()) ? .probing : .prepping),
                                         since: PrepQueueService.lastRunStartedAt,
                                         timeout: RunTimeouts.prep,
                                         // #1003: a closure so the count is re-read every tick, not
                                         // captured whenever RootView last happened to re-render.
                                         progressDetail: { PrepProgressDecoder.label(for: PrepProgressDecoder.loadCurrent()) },
                                         compact: true)
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
                    Button {
                        showDaysOff = true
                    } label: {
                        ToolbarHoverLabel(title: DaysOffAttention.badgeTitle(daysOffReason),
                                          systemImage: "calendar.badge.clock")
                            .foregroundStyle(daysOffReason != .none ? OVColor.inkSoft : Color.primary)
                    }
                    .help(DaysOffAttention.help(daysOffReason))

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
                        Button("Reminder timing…") { showReminderSettings = true }
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
                    Menu {
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
                    } label: {
                        Label("DEBUG", systemImage: "ladybug")
                    }
                }
                #endif
            }
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
                // If a run is in flight at launch, watch it to completion; otherwise just ingest any
                // results already on disk, without nagging about an old failed run (#48).
                if PrepQueueService.isRunning(now: Date()) {
                    // #1130: a detached Prep run outlives the app, so one can still be going at launch.
                    // Reopen the takeover so a live run is never invisible; the continuous watchPrepRuns
                    // task (below) follows it to completion, so this no longer awaits here (which also
                    // stops an in-flight Prep from blocking the scout reattach that follows).
                    prepSheetShown = true
                } else if let report = PrepQueueService.settleOrphanedProbe(into: context, now: Date()) {
                    // #1809: a check that finished while Overture was CLOSED. The run watcher below only
                    // settles a run it is watching, and the detached runner removes its own marker on
                    // exit, so without this the check is never settled at all: its paid answers never
                    // land, and the marker it leaves behind makes the next Prep run read as a check and
                    // discard every draft it wrote. #1765 is what made that likely, since a check is no
                    // longer capped at about eleven minutes.
                    reportReachabilityRun(report)
                } else {
                    ingestPrep()
                }
                // #1035: the same reattach, for the scout's detached read. A scout-extract run outlives
                // the app, so one can still be going at launch (a relaunch over a live run, or the window
                // scene torn down and rebuilt mid-read). Reopen the takeover and follow it to completion
                // so a live run is never invisible now that the modal is the primary progress signal.
                if ScoutExtractService.isRunning(now: Date()) {
                    await reattachScoutExtractRun()
                }
                autoScoutIfDue()   // run a scheduled scout on launch if one is due (#33)
            }
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
                await watchPrepRuns()
            }
            .task {
                guard AppEnvironment.shouldStartBackgroundServices else { return }
                // Keep the daily scout schedule honored while the app stays open (#33).
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)  // hourly
                    autoScoutIfDue()
                }
            }
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
                }, initialHighlightRecipientId: followUpsHighlightRecipientId,
                onHighlightConsumed: { followUpsHighlightRecipientId = nil })
            }
            .sheet(isPresented: $showVoiceGuidance) { VoiceGuidanceView() }
            // #953: pick which kept shows this Prep run covers. Defaults by performance date; the run
            // fires with exactly the rows Dan leaves checked.
            .sheet(isPresented: $showPrepSelection) {
                PrepSelectionSheet(prospects: toPrep, sources: watchedSources,
                                   clients: DownbeatBridge.loadWithHealth(now: Date()).clients,
                                   allItems: allProspects.map(QueueItem.init)) { includedKeys in startPrep(includedKeys: includedKeys) }
            }
            // #1130: the Prep run's takeover, mirroring the scout's (#1034). A detached Prep run takes
            // minutes, so it gets the same prominent working/still-alive/stalled screen instead of only a
            // subtle toolbar label. Shown while the run is in flight (set by startPrep and on launch-reattach)
            // and cleared by watchPrepRun when the run ends; Hide keeps the run going, Cancel stops it.
            .sheet(isPresented: $prepSheetShown) { prepProgressModal }
            .sheet(isPresented: $showSources) { SourcesView(readOne: { runScout(only: [$0.sourceId]) }) }
            .sheet(isPresented: $showDaysOff) { DaysOffView() }
            .sheet(isPresented: $showExcludedTowns) { ExcludedTownsView() }
            .sheet(isPresented: $showOrganisations) { OrganisationsView() }
            .sheet(isPresented: $showReminderSettings) { ReminderSettingsView() }
            // #924: the date picker a multi-night dismissal opens, pre-filled with the run's dates.
            .sheet(item: Bindable(dayOffOffer).pending) { pending in
                BlockDaysSheet(pending: pending, undo: undoStack)
            }
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
            status.set("DEBUG: staged re-prep-queued draft. Open '\(p.groupName)' in Review for the 'Re-prep queued' badge")
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
                gmailConnectError = error.localizedDescription
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
        prepSheetShown = true
        listingReadProgress = .init(completed: 0, total: 0, advancedAt: Date())
        listingReadStartedAt = Date()
        Task { @MainActor in
            defer { listingReadProgress = nil }
            do {
                _ = try await PrepQueueService.startReachabilityProbe(
                    keys: keys, from: context, now: Date(),
                    onListingProgress: { done, total in
                        listingReadProgress = .init(completed: done, total: total, advancedAt: Date())
                    })
            } catch {
                // The check never started, so the takeover must not sit there implying it did.
                prepSheetShown = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startPrep(includedKeys: Set<String>) {
        // #1130: show the takeover so the run's working state is unmistakable from the moment it starts,
        // the same as a manual scout, rather than a subtle toolbar label a first-time user misses.
        // #1824: raised to BEFORE the launch, because the launch now renders each kept show's listing page
        // first (seconds of real work). Left where it was, that whole phase happened behind a button that
        // looked like it had done nothing.
        prepSheetShown = true
        listingReadProgress = .init(completed: 0, total: 0, advancedAt: Date())
        listingReadStartedAt = Date()
        Task { @MainActor in
            defer { listingReadProgress = nil }
            do {
                // #1809: the orphan settle lives in PrepQueueService.startPrep, so every way a Prep run
                // begins is covered (a per-row Re-prep never reaches this function). This only supplies
                // somewhere to SAY what that settle found.
                // #353: no separate "started" message. The button's own "Prepping…" state and
                // QueueView's masthead count already say a run is in progress; a second message
                // saying the same thing was redundant.
                // #1143: the continuous watchPrepRuns task follows this run to completion (ingest, or a
                // clear empty-run notice), so it is not started per-launch here; one watcher owns every run.
                _ = try await PrepQueueService.startPrep(
                    from: context, now: Date(), includedKeys: includedKeys,
                    onOrphanSettled: { reportReachabilityRun($0) },
                    onListingProgress: { done, total in
                        // A fresh stamp on every step: it is what tells the takeover this phase is still
                        // alive, since an in-process read has no marker file to heartbeat.
                        listingReadProgress = .init(completed: done, total: total, advancedAt: Date())
                    })
            } catch {
                // The run never started, so the takeover must not sit there implying it did.
                prepSheetShown = false
                errorMessage = error.localizedDescription
            }
        }
    }

    // #1038: stop a Prep run in flight, cooperatively. The detached run has no trackable PID, so this
    // writes the sentinel the runner checks on its heartbeat; the runner stops the claude process it
    // recorded and exits at the next tick (never mid-write, so no draft is corrupted). watchPrepRun keeps
    // polling and ingests whatever the run had already written once the marker clears.
    private func cancelPrep() {
        PrepQueueService.requestCancel()
    }

    // Wait for the in-flight run to finish, then report what it produced. Tied to a run
    // we know is live (just launched, or in flight at launch), so an old failed run
    // never re-nags on a normal open.
    private func watchPrepRun() async {
        while PrepQueueService.isRunning(now: Date()) {
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
        }
        // #1130: the run has ended (the marker cleared). Close the takeover so it does not sit showing a
        // finished run; the outcome surfaces below via ingest / the empty-run notice.
        prepSheetShown = false
        let started = PrepQueueService.lastRunStartedAt
        let resultsMod = try? PrepImporter.defaultURL
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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
        switch DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: resultsMod ?? nil) {
        case .producedResults:
            if let report = PrepQueueService.settleReachabilityProbe(into: context, now: Date()) {
                reportReachabilityRun(report)
            } else {
                ingestPrep()
            }
        case .finishedEmpty:
            if let report = PrepQueueService.settleReachabilityProbe(into: context, now: Date()) {
                reportReachabilityRun(report)
            } else {
                errorMessage = DetachedRunOutcome.finishedEmptyMessage(
                    .prep, tail: RunLog.tail(8, from: RunLog.prepURL))
            }
        case .idle:
            break
        }
    }

    // #1769: a check that came home partial says so. The sentence itself lives in ReachabilityRunSummary,
    // where a test can read it (#863): assembled here in the view body it would be unreachable by any test,
    // which is how the shortfall came to be computed and discarded in the first place.
    //
    // .warning for the same reason a Prep run's shortfall is: an .info write can be silently overwritten by
    // a later routine receipt, and this is the one thing about a 21-minute run Dan has to see.
    private func reportReachabilityRun(_ report: ReachabilityRunReport) {
        guard let message = report.attentionMessage else { return }
        status.set(message, priority: .warning)
    }

    // #1143: continuously watch for a Prep run to begin (a per-row Re-prep click, an explicit "Prep kept"
    // run, or one in flight at launch) and follow it to completion. Mirrors watchReplyClassifyRuns exactly:
    // it polls the run marker and only enters watchPrepRun when a run is genuinely live, so an old failed
    // run never re-nags on a normal open (#48). One watcher owns every run, so there is a single ingest/
    // takeover path rather than a per-launch Task at each start site.
    private func watchPrepRuns() async {
        while !Task.isCancelled {
            if PrepQueueService.isRunning(now: Date()) {
                prepSheetShown = true
                await watchPrepRun()
            }
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
        }
    }

    // #802: the scout's reading half. The extract run is detached, so without this the pages it read
    // would sit in a results file nobody opens until the next launch, and Dan's scout would look like it
    // had found nothing. Mirrors watchPrepRun deliberately: wait for the live run, then ingest at once,
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
        let started = ScoutExtractService.lastRunStartedAt
        let resultsMod = try? ScoutExtractResultsDecoder.defaultURL
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
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
        guard let data = try? Data(contentsOf: ScoutExtractResultsDecoder.defaultURL),
              let results = try? ScoutExtractResultsDecoder.decode(data) else { return 0 }
        return results.usableEventCount
    }

    @discardableResult
    private func ingestScoutExtract() -> ScoutService.Outcome? {
        guard let data = try? Data(contentsOf: ScoutExtractResultsDecoder.defaultURL),
              let results = try? ScoutExtractResultsDecoder.decode(data) else { return nil }
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
    // watchPrepRun: wait for the live run, then ingest immediately (clearing the per-recipient spinner)
    // or report that it finished without a draft. A single continuous watcher (below) drives this so it
    // covers every launch source: the at-launch auto run, an in-flight run, AND a "Draft a reply" click.
    private func watchReplyClassifyRun() async {
        while ReplyClassifyService.isRunning(now: Date()) {
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
        }
        let started = ReplyClassifyService.lastRunStartedAt
        let resultsMod = try? ReplyClassifyImporter.defaultURL
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        switch DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: resultsMod ?? nil) {
        case .producedResults:
            ingestReplyClassifications()
        case .finishedEmpty:
            errorMessage = DetachedRunOutcome.finishedEmptyMessage(
                .replyClassify, tail: RunLog.tail(8, from: RunLog.replyClassifyURL))
        case .idle:
            break
        }
    }

    // Continuously watch for a reply-classify run to begin (a click, the at-launch auto run, or one in
    // flight at open) and follow it to completion. Polls the run marker; only enters watchReplyClassifyRun
    // when a run is genuinely live, so an old failed run never re-nags on a normal open (#48). Cheap: a
    // file stat every few seconds on a resident desktop app.
    private func watchReplyClassifyRuns() async {
        while !Task.isCancelled {
            if ReplyClassifyService.isRunning(now: Date()) {
                await watchReplyClassifyRun()
            }
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    // #1163: drives the Gmail-connect failure alert, which unlike the shared error alert offers a Try again.
    private var gmailConnectErrorBinding: Binding<Bool> {
        Binding(get: { gmailConnectError != nil }, set: { if !$0 { gmailConnectError = nil } })
    }

    // #1054: presents the keep-or-discard alert while a cancelled read is awaiting Dan's choice.
    private var cancelledReadBinding: Binding<Bool> {
        Binding(get: { cancelledScoutRead != nil }, set: { if !$0 { cancelledScoutRead = nil } })
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
                })
    }

    // Answer, then clear. Clearing goes through the binding above, so the one-shot on ScoutReadAsk is what
    // stops the dismissal that follows from resuming the continuation a second time.
    private func answerReadAsk(_ ask: ScoutReadAsk, _ choice: ScoutReadBudget.Choice) {
        ask.reply(choice)
        scoutReadAsk = nil
    }

    // Run a scout automatically when the daily schedule says one is due and auto-scout is
    // on (#33). Safe to trigger unattended: the scout only reads/extracts, never sends.
    // Ingest classifications a prior reply-classify run wrote (suggests states, auto). No-op if the
    // results file isn't there yet.
    private func ingestReplyClassifications() {
        guard let outcome = try? ReplyClassifyImporter.ingestFile(at: ReplyClassifyImporter.defaultURL, into: context) else { return }
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
                            scoutReadAsk = ScoutReadAsk(pending: pending) { continuation.resume(returning: $0) }
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
                errorMessage = p.alert
                if let status = p.status { scoutSummary = status }
                // Close the takeover so the error alert is what Dan sees.
                scoutSheetShown = false
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
        scoutSheetShown = false
        scoutIsManual = false
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
        cancelledScoutRead = count
    }

    // #1054: Dan kept the cancelled read's shows. Import the partial file the normal way (dedup and
    // classify still apply); they join the queue like any other find.
    private func keepCancelledRead() {
        ingestScoutExtract()
        cancelledScoutRead = nil
    }

    // #1054: Dan discarded them. Delete the partial file so the reattach path cannot re-import it on a
    // later launch, and clear the prompt. Nothing enters the queue.
    private func discardCancelledRead() {
        ScoutExtractResultsDecoder.discard()
        cancelledScoutRead = nil
    }

    // #1034: the stalled-state Retry. A stalled modal means the run's heartbeat has gone dead, so abandon
    // this watch (its Task's completion is guarded by the generation token) and start a fresh scout,
    // which re-shows the takeover from the top.
    private func retryScout() {
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
                runAlive: readingStartedAt != nil ? { ScoutExtractService.isRunning(now: Date()) } : nil,
                // #1427: the reading phase predicts "~X remaining" from past completed runs; every other
                // phase (and a thin history) shows nothing. Loaded each tick so a run recorded moments ago
                // is already in the average.
                durationHistory: readingStartedAt != nil ? { RunDurationHistoryStore.load() } : { nil },
                onRetry: { retryScout() },
                onHide: { scoutSheetShown = false },
                onCancel: { cancelScout() })
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
    private var prepProgressModal: some View {
        VStack {
            Spacer(minLength: 0)
            // #1824: the launch's own first phase, the app rendering each kept show's listing page. It has
            // no marker file (it runs in process), so its still-alive evidence is the same as the scout
            // sweep's: a count that keeps advancing.
            if let reading = listingReadProgress {
                RunProgressView(phase: .readingListings,
                                since: listingReadStartedAt,
                                snapshot: { reading },
                                onHide: { prepSheetShown = false })
            } else {
                RunProgressView(
                    // #1322: a probe reuses this same takeover, so it labels itself "Checking reachability"
                    // instead of "Prepping" when the in-flight run is a probe (its marker is present).
                    phase: PrepQueueService.isProbeRunning(now: Date()) ? .probing : .prepping,
                    since: PrepQueueService.lastRunStartedAt,
                    snapshot: { RunProgressView.Snapshot.livePrepping() },
                    runAlive: { PrepQueueService.isRunning(now: Date()) },
                    onHide: { prepSheetShown = false },
                    onCancel: { cancelPrep() })
            }
            Spacer(minLength: 0)
        }
        .frame(minWidth: 460, minHeight: 280)
        .background(OVColor.canvas)
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
                _ = try OmniFocusSync.apply(desired: desired, client: AppleScriptOmniFocusClient())
                OmniFocusSyncStatus.recordSuccess(at: Date())   // clears any prior failure warning (#239)
                // Dan (2026-07-18): no routine "N due, N created" receipt here anymore. The OmniFocus toolbar menu
                // already shows "last synced" when opened, and the only thing worth the shared status
                // slot is a failure, handled below.
            } catch {
                // #239: record even the swallowed automatic failure so it stays visible in the masthead.
                OmniFocusSyncStatus.recordFailure("\(error)", at: Date())
                if force { errorMessage = OmniFocusSync.failureMessage(reason: "\(error)") }
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
        guard let outcome = PrepImporter.consumeIfNew(into: context) else { return }
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
