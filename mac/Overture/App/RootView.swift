import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var isScanning = false
    @AppStorage("autoScoutEnabled") private var autoScoutEnabled = true
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var gmailConnected = GmailAuthManager.shared.isConnected
    @State private var isConnectingGmail = false
    @State private var warningMessage: String?

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

    private var followUpsDue: Int {
        FollowUp.due(from: allProspects, now: Date()).count
            + ConversationReminder.due(from: allProspects, now: Date()).count
    }

    private var canStartPrep: Bool {
        !toPrep.isEmpty && !PrepQueueService.isRunning(now: Date())
    }

    var body: some View {
        QueueView()
            .toolbar {
                ToolbarItem(placement: .status) {
                    if let statusMessage {
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
                #if DEBUG
                // DEBUG ONLY (#196): stage a prospect as already sent so post-send flows can be
                // tested without a live Gmail send. Compiled out of release builds entirely.
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        debugStageFirstAsSent()
                    } label: {
                        Label("DEBUG: Mark as sent", systemImage: "ladybug")
                    }
                    .help("DEBUG ONLY: mark the first un-sent prospect as approved-and-sent so booking detection, follow-ups, reminders, and reply handling can be tested without sending mail")
                }
                #endif
            }
            .task {
                // Skip the app's launch-time background work when the app is only running as
                // the unit suite's test host, so the suite doesn't pay the ~30s startup tax (#195).
                guard AppEnvironment.shouldStartBackgroundServices else { return }
                ingestIfEmpty()
                reconcileBookings()
                // Detect replies on sent threads and auto-mark .replied (#40). Read-only;
                // skips silently if Gmail isn't connected.
                await GmailReplyChecker().checkReplies(in: context)
                // Ingest any classifications from a prior run, then (after replies are saved above)
                // launch a classify run for replies still needing an intent (#112). Both no-op
                // gracefully when there's nothing to do or the runner isn't configured.
                ingestReplyClassifications()
                startReplyClassifyIfNeeded()
                // If a run is in flight at launch, watch it to completion; otherwise just
                // ingest any results already on disk (a past success), without nagging
                // about an old failed run (#48).
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
            .task {
                guard AppEnvironment.shouldStartBackgroundServices else { return }
                // Re-reconcile when Downbeat rewrites its export while we're open (#197), so a
                // booking made in Downbeat surfaces as Booked without a relaunch or scout. Same
                // path as the launch reconcile above. The watcher tears down when this task ends
                // (view gone or cancelled) via the stream's onTermination.
                var lastSeen = exportModifiedAt()
                for await _ in DownbeatExportWatcher.changes() {
                    let current = exportModifiedAt()
                    if DownbeatExportWatcher.shouldReconcile(previous: lastSeen, current: current) {
                        lastSeen = current
                        reconcileBookings()
                    }
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
    }

    #if DEBUG
    // DEBUG ONLY (#196): stage the first not-yet-sent prospect as approved-and-sent so the
    // post-send lifecycle can be exercised end to end without a real send or store surgery.
    private func debugStageFirstAsSent() {
        guard let target = allProspects.first(where: { $0.sentAt == nil }) else {
            statusMessage = "DEBUG: no un-sent prospect to stage"
            return
        }
        DebugStaging.stageAsSent(target, now: Date())
        try? context.save()
        statusMessage = "DEBUG: staged \(target.groupName) as sent"
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
    private func reconcileBookings() {
        let loaded = DownbeatBridge.loadWithHealth(now: Date())
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        if DownbeatBooking.reconcileBooked(prospects: all, clients: loaded.clients, bookings: loaded.bookings, health: loaded.health, now: Date()) > 0 {
            try? context.save()
        }
    }

    // Last-modified time of the Downbeat export, used to gate the live re-reconcile (#197)
    // so a spurious filesystem event on an unchanged file doesn't trigger redundant work.
    private func exportModifiedAt() -> Date? {
        (try? DownbeatBridge.defaultURL
            .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
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
        if !notes.isEmpty { statusMessage = "Prep: " + notes.joined(separator: " · ") }
    }
}
