import SwiftUI
import SwiftData

struct RootView: View {
    @Environment(\.modelContext) private var context
    @State private var isScanning = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var gmailConnected = GmailAuthManager.shared.isConnected
    @State private var isConnectingGmail = false
    @State private var warningMessage: String?

    // Kept prospects with no draft yet — what a Prep run would work on.
    @Query(filter: #Predicate<Prospect> { $0.statusRaw == "queued" && $0.draftBody == nil })
    private var toPrep: [Prospect]

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
                    Button {
                        runScout()
                    } label: {
                        if isScanning {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Scouting…")
                            }
                        } else {
                            Label("Run scout", systemImage: "binoculars")
                        }
                    }
                    .disabled(isScanning)
                    .help("Scout the venue calendars for new performances (⌘R)")
                    .keyboardShortcut("r", modifiers: .command)
                }
            }
            .task {
                ingestIfEmpty()
                // If a run is in flight at launch, watch it to completion; otherwise just
                // ingest any results already on disk (a past success), without nagging
                // about an old failed run (#48).
                if PrepQueueService.isRunning(now: Date()) {
                    await watchPrepRun()
                } else {
                    ingestPrep()
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
    }

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

    private func runScout() {
        isScanning = true
        statusMessage = nil
        Task {
            do {
                let outcome = try await ScoutService.runScout(into: context)
                var parts = ["\(outcome.found) found"]
                if outcome.inserted > 0 { parts.append("\(outcome.inserted) new") }
                if outcome.uncertain > 0 { parts.append("\(outcome.uncertain) unsure") }
                statusMessage = parts.joined(separator: " · ")
                // Past-client export was missing/stale/unreadable: warm matching ran
                // degraded, so tell Dan rather than letting it pass silently (#22/#23).
                warningMessage = outcome.clientListWarning
            } catch {
                errorMessage = String(describing: error)
            }
            isScanning = false
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
        if !notes.isEmpty { statusMessage = "Prep: " + notes.joined(separator: " · ") }
    }
}
