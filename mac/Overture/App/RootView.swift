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
    @State private var statusMessage: String?
    // #346: the scout outcome ("N found · N unsure", or a failure status) gets its own state so
    // it can render next to the Scout control instead of the unrelated center status slot.
    @State private var scoutSummary: String?
    @State private var errorMessage: String?
    // #285: the shared acknowledgment surface for this window and its sheets, so a control whose
    // effect isn't otherwise visible still shows it ran.
    @State private var feedback = ActionFeedback()
    @State private var dayOffOffer = DayOffOfferRequest()   // #924: dismiss-to-day-off picker request
    @State private var gmailConnected = GmailAuthManager.shared.isConnected
    @State private var isConnectingGmail = false
    @State private var gmailConnectStartedAt: Date?   // for the live elapsed counter + stuck timeout (#436)
    // #1027: the finished scout's warnings, as one branded popup shown ONCE at the true end of a manual
    // run. Replaces the plain warningMessage alert that fired after the native sweep, before the read.
    @State private var scoutWarnings: ScoutWarnings?
    // #1034: the takeover progress modal, shown while a scout Dan STARTED runs (never the scheduled
    // watch-only run, which keeps its quiet toolbar label). One presented sheet carries the whole run:
    // it shows ScoutProgressView while scoutWarnings is nil, then swaps to #1027's ScoutSummaryView once
    // the run finishes with something to say, so the takeover becomes the results without a dismiss/
    // re-present flicker between two sheets.
    @State private var scoutIsManual = false          // this run is one Dan started (drives the modal)
    @State private var scoutSheetShown = false        // the sheet is presented (vs hidden while it runs)
    @State private var scoutNativeSnapshot: ScoutProgressView.Snapshot?   // latest native-phase heartbeat
    // Supersedes an abandoned run's completion after a stalled-state Retry, so the old Task cannot
    // clobber the fresh run's state when it finally returns (CLAUDE.md: assume it runs twice).
    @State private var scoutGeneration = 0
    @State private var scoutTask: Task<Void, Never>?
    // #1037: Dan asked to stop this run. The native sweep reads it between sources; the detached read is
    // stopped via a cancel file the runner checks; and finishScout reads it to close quietly instead of
    // popping a summary for a run he chose to abandon.
    @State private var scoutCancelRequested = false
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
    @State private var showArchive = false
    @State private var archiveJumpKey: String?
    // #685: which contact on the jumped-to show to highlight (nil when the jump only identifies
    // the show, e.g. a plain search pick or the toolbar Archive button).
    @State private var archiveJumpRecipientId: String?
    @State private var searchQuery: String = ""
    @State private var showPatterns = false
    @State private var showFollowUps = false
    // #682: the recipient Dan clicked "Send a follow-up" from on the Reached Out row, handed to
    // FollowUpsView so it opens with that same entry highlighted instead of a plain list.
    @State private var followUpsHighlightRecipientId: String?
    @State private var showVoiceGuidance = false
    @State private var showSources = false
    @State private var showDaysOff = false      // #901
    @State private var showReminderSettings = false   // #931: rehomed reminder-timing settings
    // #803: when the DETACHED reading half began, so it has a visible working / still-alive / stalled
    // state of its own. It had none: runScout returned, the spinner went out, and Overture then sat
    // reading calendars for minutes with nothing on screen at all, and nothing to say if that run hung.
    // CLAUDE.md's rule is binding, and this was a straight violation of it.
    @State private var readingStartedAt: Date?

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

    private var noBookedShootData: Bool {
        DaysOffAttention.needsALook(
            ScoutService.blockedCalendar(export: DownbeatBridge.loadedExport(), context: context))
    }

    private var nonDismissedProspects: [Prospect] { allProspects.filter { $0.status != .dismissed } }

    private var searchableItems: [QueueItem] { allProspects.map(QueueItem.init) }

    // Whether picking a global search result, or an OmniFocus follow-up tap (#628), should jump
    // into the Queue (#236's existing deep link mechanism) or open Archive with that row forced
    // into view instead. A dismissed show, or one otherwise absent from both Queue pipelines
    // (closed, past its window), never renders in the Queue, so it routes to Archive instead of
    // silently landing nowhere.
    private func handleSearchSelection(_ item: QueueItem) {
        let reachedOutKeys = Set(ReachedOutQueue.active(from: nonDismissedProspects, now: Date()).map(\.prospect.naturalKey))
        if QueueModel.isReachableForDeepLink(item, reachedOutKeys: reachedOutKeys, today: QueueModel.easternToday()) {
            deepLinkedKey = item.id
        } else {
            archiveJumpKey = item.id
            archiveJumpRecipientId = nil
            showArchive = true
        }
    }

    // Same routing as handleSearchSelection, but starting from a natural key (from an OmniFocus
    // deep link) instead of an already-resolved QueueItem. A key with no matching prospect at all
    // (shouldn't happen in practice) is treated the same as unreachable.
    private func routeDeepLink(toKey key: String) {
        guard let item = searchableItems.first(where: { $0.id == key }) else {
            archiveJumpKey = key
            archiveJumpRecipientId = nil
            showArchive = true
            return
        }
        handleSearchSelection(item)
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
            ShowSearchField(query: $searchQuery, allItems: searchableItems) { result in
                handleSearchSelection(result)
            }
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
                      archiveJumpKey = key
                      archiveJumpRecipientId = recipientId
                      showArchive = true
                  },
                  onRetryOmniFocusSync: { syncOmniFocus(force: true) })
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
                ToolbarItem(placement: .status) {
                    if omniFocusFailedAt > 0 {
                        Label("OmniFocus sync failing", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .help("The automatic OmniFocus sync last failed, so follow-up tasks may not be getting created. Click \"Sync to OmniFocus\" to retry, and check that OmniFocus is installed and has Automation permission. A successful sync clears this.")
                    } else if let statusMessage {
                        Text(statusMessage)
                            .font(.system(size: 11))
                            .foregroundStyle(OVColor.inkFaint)
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
                        Toggle("Auto-scout daily", isOn: $autoScoutEnabled)
                        Divider()
                        Button {
                            startPrep()
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
                    } label: {
                        if isScanning && !scoutIsManual {
                            // #1034: the compact toolbar label is now ONLY the scheduled watch-only
                            // scout's treatment. A scout Dan STARTED takes over the screen with the
                            // ScoutProgressView modal instead (both the native "Scouting" sweep and the
                            // detached "Reading calendars" read), so its progress never shows here. The
                            // detached-read branch that used to live here moved into the modal wholesale:
                            // a watch-only run never reads, so readingStartedAt is only ever set by a
                            // manual run, which the modal owns.
                            LiveRunLabel(base: ScoutProgressCopy.title(.scouting), since: scoutStartedAt,
                                         timeout: RunTimeouts.scout, compact: true)
                        } else if PrepQueueService.isRunning(now: Date()) {
                            // #354: real "N of M" progress from the run's own progress file,
                            // instead of a bare indefinite spinner.
                            LiveRunLabel(base: "Prepping", since: PrepQueueService.lastRunStartedAt,
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
                        archiveJumpKey = nil
                        archiveJumpRecipientId = nil
                        showArchive = true
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

                    // #901: the days Overture won't pitch him for, and (Dan's call, 2026-07-14) a standing
                    // gold mark while it holds no booked shoots at all.
                    //
                    // That state is the trap this issue was written about: the conflict guard has never
                    // once fired, because Downbeat exports no bookings and nothing ever wrote the local
                    // override file, and a guard protecting nothing looked exactly like one that worked. It
                    // may sit marked for a long time (bookings only accrue going forward), and that is the
                    // honest reading: until he blocks those days himself, Overture cannot keep clear of them.
                    Button {
                        showDaysOff = true
                    } label: {
                        ToolbarHoverLabel(title: DaysOffAttention.badgeTitle(needsALook: noBookedShootData),
                                          systemImage: "calendar.badge.clock",
                                          showsTitle: noBookedShootData)
                            .foregroundStyle(noBookedShootData ? OVColor.gold : Color.primary)
                    }
                    .help(DaysOffAttention.help(needsALook: noBookedShootData))
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
                    await watchPrepRun()
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
            // #1034/#1027: ONE presented sheet for a manual scout, from click to results. While the run
            // is in flight (scoutWarnings still nil) it is the ScoutProgressView takeover; the instant the
            // run finishes with something to say it becomes #1027's ScoutSummaryView, in the same sheet,
            // so there is no dismiss-then-present flicker between two separate sheets. A run with nothing
            // to report just closes it.
            .sheet(isPresented: $scoutSheetShown, onDismiss: { scoutWarnings = nil }) {
                if let scoutWarnings {
                    // Fires once, at the true end of a manual run; lets Dan fix or confirm a source inline.
                    ScoutSummaryView(warnings: scoutWarnings,
                                     onReadFixed: { ids in runScout(only: ids) })
                } else {
                    scoutProgressModal
                }
            }
            .sheet(isPresented: $showArchive) {
                ArchiveView(initialHighlightKey: archiveJumpKey, initialHighlightRecipientId: archiveJumpRecipientId,
                           onConnectGmail: connectGmail)
            }
            .sheet(isPresented: $showPatterns) { OutcomePatternsView() }
            .sheet(isPresented: $showFollowUps) {
                FollowUpsView(onOpenInArchive: { key, recipientId in
                    showFollowUps = false
                    archiveJumpKey = key
                    archiveJumpRecipientId = recipientId
                    showArchive = true
                }, initialHighlightRecipientId: followUpsHighlightRecipientId,
                onHighlightConsumed: { followUpsHighlightRecipientId = nil })
            }
            .sheet(isPresented: $showVoiceGuidance) { VoiceGuidanceView() }
            .sheet(isPresented: $showSources) { SourcesView(readOne: { runScout(only: [$0.sourceId]) }) }
            .sheet(isPresented: $showDaysOff) { DaysOffView() }
            .sheet(isPresented: $showReminderSettings) { ReminderSettingsView() }
            // #924: the date picker a multi-night dismissal opens, pre-filled with the run's dates.
            .sheet(item: Bindable(dayOffOffer).pending) { pending in BlockDaysSheet(pending: pending) }
            .actionFeedbackBanner()
            // Injected outermost so the sheets above inherit it too (#285).
            .environment(feedback)
            .environment(dayOffOffer)
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
            statusMessage = "DEBUG seed failed: \(error.localizedDescription)"
            return
        }
        ingestPrep()
        ingestReplyClassifications()
        statusMessage = "DEBUG: seeded \(result.copied.count) file\(result.copied.count == 1 ? "" : "s")"
            + (result.copied.isEmpty ? " (none found in live)" : ": " + result.copied.joined(separator: ", "))
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
            statusMessage = "DEBUG Gmail connect failed: \(error.localizedDescription)"
            return
        }
        if result.missing.contains("gmail-tokens.json") {
            statusMessage = "DEBUG: live Gmail isn't connected. Connect it in the release app first, then retry."
            return
        }
        statusMessage = GmailAuthManager.shared.isConnected
            ? "DEBUG: Gmail connected from live (\(result.copied.joined(separator: ", ")))"
            : "DEBUG: copied \(result.copied.count) file(s) but Gmail still reads as not connected"
    }

    // DEBUG ONLY (#318): targeted reset of the isolated Overture-Debug dev environment: empties the
    // store and removes the seeded handoff inputs, so seed/test/reset is repeatable. Only ever
    // touches the Debug location; leaves the dev Gmail login intact.
    private func debugClearDevData() {
        DebugSeed.clearStore(in: context)
        do {
            try context.save()
        } catch {
            statusMessage = "DEBUG clear failed: \(error.localizedDescription)"
            return
        }
        let removed: [String]
        do {
            removed = try DebugSeed.clearHandoffInputs(debugBase: DebugSeed.debugHandoffDirectory)
        } catch {
            statusMessage = "DEBUG clear failed: \(error.localizedDescription)"
            return
        }
        syncOmniFocus(force: true)   // completes the now-orphaned OmniFocus tasks
        statusMessage = "DEBUG: cleared dev data (store + \(removed.count) file\(removed.count == 1 ? "" : "s"))"
    }

    private func debugStageFirstAsSent() {
        guard let target = allProspects.first(where: { $0.sentAt == nil }) else {
            statusMessage = "DEBUG: no un-sent prospect to stage"
            return
        }
        DebugStaging.stageAsSent(target, now: Date())
        do {
            try context.save()
            statusMessage = "DEBUG: staged \(target.groupName) as sent"
        } catch {
            statusMessage = "DEBUG stage failed: \(error.localizedDescription)"
        }
    }

    private func debugStageReminderLead() {
        let p = DebugStaging.stageReminderDueLead(in: context, now: Date())
        do {
            try context.save()
            statusMessage = "DEBUG: staged \(p.groupName) as reminder-due"
        } catch {
            statusMessage = "DEBUG stage failed: \(error.localizedDescription)"
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
            statusMessage = "DEBUG: staged self-send lead to \(p.recipients.first?.email ?? "?"). Approve it, then Send"
        } catch {
            statusMessage = "DEBUG stage failed: \(error.localizedDescription)"
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
            statusMessage = "DEBUG: staged multi-recipient self-send lead (\(p.recipients.count) recipients). Approve it, then Send twice"
        } catch {
            statusMessage = "DEBUG stage failed: \(error.localizedDescription)"
        }
    }

    private func debugClearDebugLeads() {
        DebugStaging.clearDebugLeads(in: context)
        do {
            try context.save()
        } catch {
            statusMessage = "DEBUG clear failed: \(error.localizedDescription)"
            return
        }
        syncOmniFocus(force: true)   // completes the now-orphaned OmniFocus tasks
        statusMessage = "DEBUG: cleared debug leads"
    }
    #endif

    private func connectGmail() {
        isConnectingGmail = true
        gmailConnectStartedAt = Date()   // #436: drives the live elapsed counter + the "looks stuck" warning
        statusMessage = nil
        // connect() self-aborts after a hard internal timeout (GmailAuthManager.timeoutTask, 120s) and
        // throws, so the failure path below always resolves; the LiveRunLabel surfaces a "looks stuck"
        // warning a bit earlier so Dan can check the browser sign-in window before it gives up.
        Task {
            do {
                try await GmailAuthManager.shared.connect()
                gmailConnected = true
                statusMessage = "Gmail connected. You can now send approved emails."
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnectingGmail = false
            gmailConnectStartedAt = nil
        }
    }

    private func startPrep() {
        do {
            // #353: no separate "started" message. The button's own "Prepping…" state and
            // QueueView's masthead count already say a run is in progress; a second message
            // saying the same thing was redundant.
            _ = try PrepQueueService.startPrep(from: context, now: Date())
            // Watch this run so Dan sees the outcome (drafts ingested, or a clear notice
            // that it finished without producing anything) rather than silent waiting (#48).
            Task { await watchPrepRun() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // Wait for the in-flight run to finish, then report what it produced. Tied to a run
    // we know is live (just launched, or in flight at launch), so an old failed run
    // never re-nags on a normal open.
    private func watchPrepRun() async {
        while PrepQueueService.isRunning(now: Date()) {
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
        }
        let started = PrepQueueService.lastRunStartedAt
        let resultsMod = try? PrepImporter.defaultURL
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        switch DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: resultsMod ?? nil) {
        case .producedResults:
            ingestPrep()
        case .finishedEmpty:
            errorMessage = DetachedRunOutcome.finishedEmptyMessage(
                .prep, tail: RunLog.tail(8, from: RunLog.prepURL))
        case .idle:
            break
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
    private func watchScoutExtractRun() async -> (outcome: ScoutService.Outcome?, finishedEmpty: String?) {
        while ScoutExtractService.isRunning(now: Date()) {
            try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
        }
        let started = ScoutExtractService.lastRunStartedAt
        let resultsMod = try? ScoutExtractResultsDecoder.defaultURL
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        switch DetachedRunOutcome.phase(runStartedAt: started, resultsModifiedAt: resultsMod ?? nil) {
        case .producedResults:
            return (ingestScoutExtract(), nil)
        case .finishedEmpty:
            return (nil, DetachedRunOutcome.finishedEmptyMessage(
                .scoutExtract, tail: RunLog.tail(8, from: RunLog.scoutExtractURL)))
        case .idle:
            return (nil, nil)
        }
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

    // Run a scout automatically when the daily schedule says one is due and auto-scout is
    // on (#33). Safe to trigger unattended: the scout only reads/extracts, never sends.
    // Ingest classifications a prior reply-classify run wrote (suggests states, auto). No-op if the
    // results file isn't there yet.
    private func ingestReplyClassifications() {
        guard let outcome = try? ReplyClassifyImporter.ingestFile(at: ReplyClassifyImporter.defaultURL, into: context) else { return }
        // #499: this run's intent hints/drafts were written in memory but never persisted. The save
        // failure is the actionable one, so it wins the single status line.
        if outcome.saveFailed {
            statusMessage = "Reply-classify results couldn't save. Try again."
        } else if let message = ReplyClassifyRunSummary.statusMessage(for: outcome) {
            // #1018: replies the run never came back with, so a silently dropped reply is no longer invisible.
            statusMessage = message
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
                        scoutNativeSnapshot = .init(sourceName: name, completed: index, total: total)
                    },
                    // #1037: the native sweep stops between sources when Dan cancels, and launches no read.
                    isCancelled: { scoutCancelRequested })
                guard gen == scoutGeneration else { return }   // superseded by a Retry / newer run
                scoutSummary = ScoutRunSummary.summary(for: outcome)   // #885

                // #802, Dan's 3rd decision: SHOW him the do-not-contact guard working. An org that asked
                // him to stop can still turn up on a venue's calendar he legitimately watches, and #769
                // suppresses each of those silently. Silent is the problem: on the one mistake that
                // cannot be taken back he would rather see the guard working than trust that it is.
                //
                // Deliberately the STATUS line and not the warning line. Nothing is wrong, nothing needs
                // fixing, and putting a receipt in the warning slot would teach him to dismiss warnings.
                statusMessage = SuppressionReport.summary(for: outcome.suppressedOrgs)

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
                    scoutNativeSnapshot = nil
                    let read = await watchScoutExtractRun()
                    guard gen == scoutGeneration else { return }
                    extract = read.outcome
                    finishedEmpty = read.finishedEmpty
                    readingStartedAt = nil
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
            statusMessage = line
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
        scoutSheetShown = true
        let read = await watchScoutExtractRun()
        guard gen == scoutGeneration else { return }
        readingStartedAt = nil
        finishScout(ScoutWarnings.from(native: ScoutService.Outcome(found: 0, inserted: 0, updated: 0,
                                                                    skipped: 0, uncertain: 0),
                                       extract: read.outcome, finishedEmpty: read.finishedEmpty),
                    auto: false)
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
    // per-second ticking happens inside ScoutProgressView's own TimelineView. The reading phase reads its
    // source name and count live from the files the app owns via the shared ScoutProgressView.Snapshot
    // .liveReading() (#1036 uses the same in AddLeadSheet). The chrome (fixed frame + canvas, centered) is
    // applied HERE because the component itself is sized to content so it can also render inline.
    private var scoutProgressModal: some View {
        VStack {
            Spacer(minLength: 0)
            ScoutProgressView(
                phase: readingStartedAt != nil ? .reading : .scouting,
                since: readingStartedAt ?? scoutStartedAt,
                snapshot: { readingStartedAt != nil ? ScoutProgressView.Snapshot.liveReading()
                                                    : (scoutNativeSnapshot ?? .init()) },
                runAlive: readingStartedAt != nil ? { ScoutExtractService.isRunning(now: Date()) } : nil,
                onRetry: { retryScout() },
                onHide: { scoutSheetShown = false },
                onCancel: { cancelScout() })
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
                let r = try OmniFocusSync.apply(desired: desired, client: AppleScriptOmniFocusClient())
                OmniFocusSyncStatus.recordSuccess(at: Date())   // clears any prior failure warning (#239)
                if force {
                    statusMessage = OmniFocusSync.receipt(due: desired.count, existing: r.existing,
                                                          created: r.created, completed: r.completed)
                }
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
        statusMessage = PrepRunSummary.statusMessage(for: outcome, voiceGuidanceLeaked: !leaks.isEmpty,
                                                     guidanceNotesRestored: restored) ?? statusMessage
    }
}
