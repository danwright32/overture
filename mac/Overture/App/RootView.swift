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
    @State private var gmailConnected = GmailAuthManager.shared.isConnected
    @State private var isConnectingGmail = false
    @State private var gmailConnectStartedAt: Date?   // for the live elapsed counter + stuck timeout (#436)
    @State private var warningMessage: String?
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

    private var followUpsDue: Int {
        FollowUp.dueRecipients(from: allProspects, now: Date()).count
            + ConversationReminder.dueRecipients(from: allProspects, now: Date(), config: .loaded()).count
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
        if let last = OmniFocusSyncStatus.lastSuccessAt() {
            return "Synced \(PrepStatus.relative(from: last, to: Date()))"
        }
        return "Not yet synced"
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
                  })
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
                            .disabled(isScanning)
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
                        if isScanning {
                            LiveRunLabel(base: "Scouting", since: scoutStartedAt,
                                         timeout: RunTimeouts.scout)
                        } else if PrepQueueService.isRunning(now: Date()) {
                            // #354: real "N of M" progress from the run's own progress file,
                            // instead of a bare indefinite spinner.
                            LiveRunLabel(base: "Prepping", since: PrepQueueService.lastRunStartedAt,
                                         timeout: RunTimeouts.prep,
                                         progressDetail: PrepProgressDecoder.label(for: PrepProgressDecoder.loadCurrent()))
                        } else {
                            ToolbarHoverLabel(title: "Scout & Prep", systemImage: "binoculars")
                        }
                    }
                    // No primaryAction: a plain click always opens the dropdown instead of
                    // guessing which of Scout or Prep was meant.
                    .help("Scout the venue calendars for new performances (⌘R), then find contacts and draft emails for the ones you keep (⌘P). Auto-scouts about daily.")
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
                        ToolbarHoverLabel(title: followUpsDue == 0 ? "Due" : "Due (\(followUpsDue))",
                                          systemImage: "arrow.uturn.right")
                    }
                    .help("Follow-ups and active conversations due for a touch")
                }
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
                // #800: read-only for now. Phase 4 adds a source, Phase 5 lets Dan stop watching one.
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showSources = true
                    } label: {
                        ToolbarHoverLabel(title: "Sources", systemImage: "list.bullet.rectangle")
                    }
                    .help("The calendars Overture re-checks on every scout, and how each one is doing")
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
                            ToolbarHoverLabel(title: "Connect Gmail", systemImage: "link")
                        }
                    }
                    .disabled(gmailConnected || isConnectingGmail)
                    .help(gmailConnected ? "Gmail is connected for sending" : "Authorize your photography Gmail so you can send approved emails")
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
            .alert("Past-client list", isPresented: warningBinding) {
                Button("OK", role: .cancel) { warningMessage = nil }
            } message: {
                Text(warningMessage ?? "")
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
            .sheet(isPresented: $showSources) { SourcesView() }
            .actionFeedbackBanner()
            // Injected outermost so the sheets above inherit it too (#285).
            .environment(feedback)
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
            let tail = RunLog.tail(8, from: RunLog.prepURL)
            errorMessage = "The Prep run finished but didn't produce any results. It may have hit an error or found no contacts."
                + (tail.isEmpty ? "" : "\n\nLast lines of the run log:\n\(tail)")
        case .idle:
            break
        }
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
            let tail = RunLog.tail(8, from: RunLog.replyClassifyURL)
            errorMessage = "The reply drafter finished but didn't produce a draft. It may have hit an error."
                + (tail.isEmpty ? "" : "\n\nLast lines of the run log:\n\(tail)")
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

    private var warningBinding: Binding<Bool> {
        Binding(get: { warningMessage != nil }, set: { if !$0 { warningMessage = nil } })
    }

    // Run a scout automatically when the daily schedule says one is due and auto-scout is
    // on (#33). Safe to trigger unattended: the scout only reads/extracts, never sends.
    // Ingest classifications a prior reply-classify run wrote (suggests states, auto). No-op if the
    // results file isn't there yet.
    private func ingestReplyClassifications() {
        guard let outcome = try? ReplyClassifyImporter.ingestFile(at: ReplyClassifyImporter.defaultURL, into: context) else { return }
        // #499: this run's intent hints/drafts were written in memory but never persisted.
        if outcome.saveFailed { statusMessage = "Reply-classify results couldn't save. Try again." }
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

    private func runScout(auto: Bool = false, depth: ScoutDepth = .readChanged) {
        isScanning = true
        scoutStartedAt = Date()
        scoutSummary = nil
        Task {
            do {
                let outcome = try await ScoutService.runScout(into: context, depth: depth)
                var parts = ["\(outcome.found) found"]
                if outcome.inserted > 0 { parts.append("\(outcome.inserted) new") }
                if outcome.uncertain > 0 { parts.append("\(outcome.uncertain) unsure") }
                scoutSummary = parts.joined(separator: " · ")
                // Surface a scout warning if any: zero events extracted (#27) or a
                // missing/stale past-client export (#22/#23). Silent degradation is the
                // thing we are avoiding.
                warningMessage = outcome.warning
            } catch {
                // A scheduled run failing stays quiet (a status line); a manual run shows
                // the modal Dan expects after clicking (#77).
                let p = ScoutFailure.presentation(auto: auto, message: String(describing: error))
                errorMessage = p.alert
                if let status = p.status { scoutSummary = status }
            }
            isScanning = false
            scoutStartedAt = nil
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
                let r = try OmniFocusSync.apply(desired: desired, client: AppleScriptOmniFocusClient())
                OmniFocusSyncStatus.recordSuccess(at: Date())   // clears any prior failure warning (#239)
                if force {
                    statusMessage = "OmniFocus: \(desired.count) due · existing \(r.existing) · created \(r.created) · completed \(r.completed)"
                }
            } catch {
                // #239: record even the swallowed automatic failure so it stays visible in the masthead.
                OmniFocusSyncStatus.recordFailure("\(error)", at: Date())
                if force { errorMessage = "OmniFocus sync failed: \(error)" }
            }
            omniFocusSyncStartedAt = nil
        }
    }

    // Ingest a Prep results file (found contacts + drafts) if one is present, filling
    // kept prospects and moving them to .drafted for review. Surfaces results that
    // matched no prospect instead of letting them vanish (a separate fallible run).
    private func ingestPrep() {
        let url = PrepImporter.defaultURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard let outcome = try? PrepImporter.ingestFile(at: url, into: context) else { return }
        var notes: [String] = []
        if outcome.drafted > 0 { notes.append("\(outcome.drafted) drafted") }
        if outcome.skippedEdited > 0 { notes.append("\(outcome.skippedEdited) kept your edits") }
        if !outcome.unmatchedKeys.isEmpty { notes.append("\(outcome.unmatchedKeys.count) didn't match") }
        if outcome.saveFailed { notes.append("couldn't save, try again") }
        // #754: the performer matcher ran against missing or unreadable reference data, so a past
        // client may have read as a cold lead. Silent here means invisible forever.
        if let matchDataWarning = outcome.matchDataWarning { notes.append(matchDataWarning) }
        // #249: fail closed if the distiller leaked a real name into the voice guidance; quarantine
        // the contaminated section so it can't feed a future draft, and warn Dan.
        let leaks = VoiceGuidanceGuard.audit(fileURL: VoiceGuidanceGuard.defaultURL,
                                             prospects: (try? context.fetch(FetchDescriptor<Prospect>())) ?? [])
        if !leaks.isEmpty { notes.append("⚠ voice guidance leaked a name, quarantined") }
        // #251: if the run altered or dropped Dan's hand-written notes, restore them from the pre-run
        // backup (the fresh auto section is kept).
        if VoiceNotesProtector.restoreIfNeeded(fileURL: VoiceGuidanceGuard.defaultURL,
                                               backupURL: VoiceNotesProtector.defaultBackupURL) {
            notes.append("restored your guidance notes")
        }
        if !notes.isEmpty { statusMessage = "Prep: " + notes.joined(separator: " · ") }
    }
}
