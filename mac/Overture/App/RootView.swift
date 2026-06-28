import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.openWindow) private var openWindow
    @State private var isScanning = false
    @AppStorage("autoScoutEnabled") private var autoScoutEnabled = true
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    // #285: the shared acknowledgment surface for this window and its sheets, so a control whose
    // effect isn't otherwise visible still shows it ran.
    @State private var feedback = ActionFeedback()
    @State private var gmailConnected = GmailAuthManager.shared.isConnected
    @State private var isConnectingGmail = false
    @State private var warningMessage: String?
    // #239: reactively reflect a failed OmniFocus sync in the masthead (0 = no failure on record).
    @AppStorage(OmniFocusSyncStatus.failedAtKey) private var omniFocusFailedAt: Double = 0
    // #236: the natural key of a lead opened from an OmniFocus deep link, handed to the queue to
    // select and scroll to. Cleared by the queue once it has acted on it.
    @State private var deepLinkedKey: String?
    // #308: the natural keys of the new leads from a tapped multi-lead away alert, handed to the queue
    // to filter down to exactly them. Cleared by the queue once it has acted on it.
    @State private var deepLinkedKeys: [String]?

    // Kept prospects with no draft yet — what a Prep run would work on.
    @Query(filter: #Predicate<Prospect> { $0.statusRaw == "queued" && $0.draftBody == nil })
    private var toPrep: [Prospect]

    // Dismissed prospects, for the restore-from-dismissed view (#28).
    @Query(filter: #Predicate<Prospect> { $0.statusRaw == "dismissed" })
    private var dismissed: [Prospect]
    // All prospects, for the time-based follow-up due count (#45).
    @Query private var allProspects: [Prospect]
    @State private var showDismissed = false
    @State private var showPatterns = false
    @State private var showFollowUps = false
    @State private var showVoiceGuidance = false

    private var followUpsDue: Int {
        FollowUp.due(from: allProspects, now: Date()).count
            + ConversationReminder.due(from: allProspects, now: Date(), config: .loaded()).count
    }

    private var canStartPrep: Bool {
        !toPrep.isEmpty && !PrepQueueService.isRunning(now: Date())
    }

    var body: some View {
        QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys)
            .onOpenURL { url in
                // #282: `overture://show` (used by the build script) just surfaces the main window;
                // delivering the URL already reopens the resident copy's window, openWindow makes it
                // explicit and focuses it.
                if OvertureDeepLink.isShowCommand(url) { openWindow(id: "main"); return }
                // #308: a tapped multi-lead away alert opens overture://leads?key=…&key=…; hand the set
                // to the queue to filter down to exactly those new leads.
                if let keys = OvertureDeepLink.leadKeys(from: url) { deepLinkedKeys = keys; return }
                // #236: a tapped OmniFocus follow-up opens overture://lead?key=<naturalKey>; hand the
                // key to the queue to jump to that lead.
                if let key = OvertureDeepLink.leadKey(from: url) { deepLinkedKey = key }
            }
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        startPrep()
                    } label: {
                        if PrepQueueService.isRunning(now: Date()) {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Prepping…")
                            }
                        } else {
                            Label("Prep kept", systemImage: "envelope.badge")
                        }
                    }
                    .disabled(!canStartPrep)
                    .help(toPrep.isEmpty ? "Keep some prospects first" : "Find contacts and draft emails for the prospects you've kept")
                    .keyboardShortcut("p", modifiers: .command)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showDismissed = true
                    } label: {
                        Label(dismissed.isEmpty ? "Dismissed" : "Dismissed (\(dismissed.count))",
                              systemImage: "archivebox")
                    }
                    .help("See dismissed prospects and restore any you cut by mistake")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showFollowUps = true
                    } label: {
                        Label(followUpsDue == 0 ? "Due" : "Due (\(followUpsDue))",
                              systemImage: "arrow.uturn.right")
                    }
                    .help("Follow-ups and active conversations due for a touch")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showPatterns = true
                    } label: {
                        Label("What converts", systemImage: "chart.bar")
                    }
                    .help("Booking and response rates by production, discipline, and fit tier")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showVoiceGuidance = true
                    } label: {
                        Label("Voice guidance", systemImage: "text.quote")
                    }
                    .help("Read and edit how Overture drafts in your voice. Your notes stay yours; tendencies are learned from your edits.")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        connectGmail()
                    } label: {
                        if gmailConnected {
                            Label("Gmail connected", systemImage: "checkmark.circle.fill")
                        } else if isConnectingGmail {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Connecting…") }
                        } else {
                            Label("Connect Gmail", systemImage: "link")
                        }
                    }
                    .disabled(gmailConnected || isConnectingGmail)
                    .help(gmailConnected ? "Gmail is connected for sending" : "Authorize your photography Gmail so you can send approved emails")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Run scout now") { runScout() }
                        Toggle("Auto-scout daily", isOn: $autoScoutEnabled)
                    } label: {
                        if isScanning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Scouting…")
                            }
                        } else {
                            Label("Run scout", systemImage: "binoculars")
                        }
                    } primaryAction: {
                        runScout()
                    }
                    .disabled(isScanning)
                    .help("Scout the venue calendars for new performances (⌘R). Auto-runs about daily.")
                    .keyboardShortcut("r", modifiers: .command)
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        syncOmniFocus(force: true)
                    } label: {
                        Label("Sync to OmniFocus", systemImage: "checklist")
                    }
                    .help("Push your due follow-ups into the OmniFocus Outreach project now. The first time, macOS will ask permission to control OmniFocus.")
                }
                #if DEBUG
                // DEBUG ONLY (#196): test affordances, compiled out of release builds. Grouped into
                // one menu to stay under SwiftUI's toolbar item limit.
                ToolbarItem(placement: .secondaryAction) {
                    Menu {
                        Button("Seed dev data from live") { debugSeedFromLive() }
                        Button("Clear dev data") { debugClearDevData() }
                        Button("Mark first as sent") { debugStageFirstAsSent() }
                        Button("Stage reminder-due lead") { debugStageReminderLead() }
                        Button("Clear debug leads") { debugClearDebugLeads() }
                    } label: {
                        Label("DEBUG", systemImage: "ladybug")
                    }
                }
                #endif
            }
            .task {
                // The ATTENDED launch work (window present). The SAFE reconciles — booking detection,
                // reply detection, and the OmniFocus push — and the Downbeat-export watcher now live on
                // the app-owned ReconcileScheduler (#265) so they run independent of this window. What
                // stays here is the AI/scout work, which must stay attended (never run unattended).
                // Skip it entirely when running only as the unit suite's test host (#195).
                guard AppEnvironment.shouldStartBackgroundServices else { return }
                ingestIfEmpty()
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
            .sheet(isPresented: $showDismissed) { DismissedView() }
            .sheet(isPresented: $showPatterns) { OutcomePatternsView() }
            .sheet(isPresented: $showFollowUps) { FollowUpsView() }
            .sheet(isPresented: $showVoiceGuidance) { VoiceGuidanceView() }
            .actionFeedbackBanner()
            // Injected outermost so the sheets above inherit it too (#285).
            .environment(feedback)
    }

    #if DEBUG
    // DEBUG ONLY (#196): stage the first not-yet-sent prospect as approved-and-sent so the
    // post-send lifecycle can be exercised end to end without a real send or store surgery.
    // DEBUG ONLY (#281): copy the live handoff inputs into the isolated Overture-Debug folder, then
    // force a fresh re-ingest so scout/booking/reply features show realistic data without a relaunch.
    // ResultsImporter is idempotent (keep/dismiss decisions survive a re-run), so this is safe to run
    // repeatedly; booking reconcile reads the now-seeded Downbeat export on its next cycle.
    private func debugSeedFromLive() {
        let result: (copied: [String], missing: [String])
        do {
            result = try DebugSeed.seedFromLive()
        } catch {
            statusMessage = "DEBUG seed failed: \(error.localizedDescription)"
            return
        }
        let resultsURL = ResultsImporter.defaultResultsURL
        if FileManager.default.fileExists(atPath: resultsURL.path) {
            _ = try? ResultsImporter.ingestFile(at: resultsURL, into: context)
        }
        ingestPrep()
        ingestReplyClassifications()
        statusMessage = "DEBUG: seeded \(result.copied.count) file\(result.copied.count == 1 ? "" : "s")"
            + (result.copied.isEmpty ? " (none found in live)" : ": " + result.copied.joined(separator: ", "))
    }

    // DEBUG ONLY (#318): targeted reset of the isolated Overture-Debug dev environment — empties the
    // store and removes the seeded handoff inputs, so seed/test/reset is repeatable. Only ever
    // touches the Debug location; leaves the dev Gmail login intact.
    private func debugClearDevData() {
        DebugSeed.clearStore(in: context)
        try? context.save()
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
        try? context.save()
        statusMessage = "DEBUG: staged \(target.groupName) as sent"
    }

    private func debugStageReminderLead() {
        let p = DebugStaging.stageReminderDueLead(in: context, now: Date())
        try? context.save()
        statusMessage = "DEBUG: staged \(p.groupName) as reminder-due"
    }

    private func debugClearDebugLeads() {
        DebugStaging.clearDebugLeads(in: context)
        try? context.save()
        syncOmniFocus(force: true)   // completes the now-orphaned OmniFocus tasks
        statusMessage = "DEBUG: cleared debug leads"
    }
    #endif

    private func connectGmail() {
        isConnectingGmail = true
        statusMessage = nil
        Task {
            do {
                try await GmailAuthManager.shared.connect()
                gmailConnected = true
                statusMessage = "Gmail connected. You can now send approved emails."
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnectingGmail = false
        }
    }

    private func startPrep() {
        do {
            let count = try PrepQueueService.startPrep(from: context, now: Date())
            statusMessage = "Prep started for \(count) prospect\(count == 1 ? "" : "s")…"
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
        switch PrepRunOutcome.phase(runStartedAt: started, running: false, resultsModifiedAt: resultsMod ?? nil) {
        case .producedResults:
            ingestPrep()
        case .finishedEmpty:
            let tail = PrepLog.tail(8)
            errorMessage = "The Prep run finished but didn't produce any results. It may have hit an error or found no contacts."
                + (tail.isEmpty ? "" : "\n\nLast lines of the run log:\n\(tail)")
        case .idle, .running:
            break
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
        _ = try? ReplyClassifyImporter.ingestFile(at: ReplyClassifyImporter.defaultURL, into: context)
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
        runScout(auto: true)
    }

    private func runScout(auto: Bool = false) {
        isScanning = true
        statusMessage = nil
        Task {
            do {
                let outcome = try await ScoutService.runScout(into: context)
                var parts = ["\(outcome.found) found"]
                if outcome.inserted > 0 { parts.append("\(outcome.inserted) new") }
                if outcome.uncertain > 0 { parts.append("\(outcome.uncertain) unsure") }
                statusMessage = parts.joined(separator: " · ")
                // Surface a scout warning if any: zero events extracted (#27) or a
                // missing/stale past-client export (#22/#23). Silent degradation is the
                // thing we are avoiding.
                warningMessage = outcome.warning
            } catch {
                // A scheduled run failing stays quiet (a status line); a manual run shows
                // the modal Dan expects after clicking (#77).
                let p = ScoutFailure.presentation(auto: auto, message: String(describing: error))
                errorMessage = p.alert
                if let status = p.status { statusMessage = status }
            }
            isScanning = false
        }
    }

    // Reconcile bookings on launch (#41/#99): auto-book on an exact Downbeat booking match,
    // suggest otherwise, so a booking made in Downbeat shows up without running a scout first.
    // Not gated on a non-empty client list — bookings are an independent array, so an export
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
        // NSAppleScript must run on the main thread. Use a (non-awaited) main-actor task so this
        // doesn't block the launch sequence, but still runs where AppleScript works. The work is a
        // handful of Apple events, so the brief main-actor occupancy is acceptable.
        Task { @MainActor in
            do {
                let r = try OmniFocusSync.apply(desired: desired, client: AppleScriptOmniFocusClient())
                OmniFocusSyncStatus.recordSuccess()   // clears any prior failure warning (#239)
                if force {
                    statusMessage = "OmniFocus: \(desired.count) due · existing \(r.existing) · created \(r.created) · completed \(r.completed)"
                }
            } catch {
                // #239: record even the swallowed automatic failure so it stays visible in the masthead.
                OmniFocusSyncStatus.recordFailure("\(error)", at: Date())
                if force { errorMessage = "OmniFocus sync failed: \(error)" }
            }
        }
    }

    // First launch with an empty store: ingest a results file if one is present, so
    // there is something to see before the first live scout.
    private func ingestIfEmpty() {
        let count = (try? context.fetchCount(FetchDescriptor<Prospect>())) ?? 0
        guard count == 0 else { return }
        let url = ResultsImporter.defaultResultsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        _ = try? ResultsImporter.ingestFile(at: url, into: context)
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
        // #249: fail closed if the distiller leaked a real name into the voice guidance — quarantine
        // the contaminated section so it can't feed a future draft, and warn Dan.
        let leaks = VoiceGuidanceGuard.audit(fileURL: VoiceGuidanceGuard.defaultURL,
                                             prospects: (try? context.fetch(FetchDescriptor<Prospect>())) ?? [])
        if !leaks.isEmpty { notes.append("⚠ voice guidance leaked a name — quarantined") }
        // #251: if the run altered or dropped Dan's hand-written notes, restore them from the pre-run
        // backup (the fresh auto section is kept).
        if VoiceNotesProtector.restoreIfNeeded(fileURL: VoiceGuidanceGuard.defaultURL,
                                               backupURL: VoiceNotesProtector.defaultBackupURL) {
            notes.append("restored your guidance notes")
        }
        if !notes.isEmpty { statusMessage = "Prep: " + notes.joined(separator: " · ") }
    }
}
