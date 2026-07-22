import Foundation
import SwiftData

// Phase A trigger: gather the kept-undrafted prospects into a work-list, write it,
// and launch the Prep run detached (Claude Code on Dan's Max plan). The app does NOT
// supervise the run; it writes the queue, kicks off the run, and later ingests the
// results file the run produces. Keeps the app responsive and avoids babysitting a
// long agentic process.

@MainActor
enum PrepQueueService {
    // Build the work-list from the local store: only kept (.queued) prospects that
    // have no draft yet, each carrying its EXACT stored naturalKey as an opaque token.
    //
    // #953: `includedKeys` is the per-run subset Dan chose in the Prep sheet. nil means "no subset
    // chosen", so every eligible prospect runs, exactly as before this change (every existing call site
    // relies on that). A non-nil set narrows the eligible prospects to only those keys; an empty set
    // therefore yields an empty queue, which startPrep reports as nothing to prep.
    // The kept-undrafted prospects a Prep run would actually draft: needs-prep-eligible, narrowed to the
    // per-run subset Dan chose. Shared by buildQueue (what to encode) and startPrep (what to stamp an
    // experiment arm onto), so the assigned set and the queued set can never disagree.
    static func eligibleProspects(from context: ModelContext, includedKeys: Set<String>?) -> [Prospect] {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return all
            .filter(PrepQueueBuilder.needsPrepEligible)
            .filter { includedKeys?.contains($0.naturalKey) ?? true }
    }

    static func buildQueue(from context: ModelContext, generatedAt: String,
                           includedKeys: Set<String>? = nil,
                           today: String = EasternDate.today()) -> PrepQueue {
        let items: [PrepQueueItem] = eligibleProspects(from: context, includedKeys: includedKeys)
            .map { p in
                PrepQueueItem(
                    naturalKey: p.naturalKey,
                    groupName: p.groupName,
                    venue: p.venue,
                    performanceDate: p.performanceDate,
                    // #1122: the run's closing night, so a draft can pitch the whole run.
                    runEndDate: p.runEndDate,
                    discipline: p.discipline,
                    websiteURL: p.websiteURL,
                    sourceListingURL: p.sourceListingURL,
                    possibleMatchName: p.possibleMatchName,
                    // #752: NOT p.priorRelationship. An unconfirmed performer match must not reach the
                    // drafter, or a guess Dan never agreed with picks the tone of a real email. This is
                    // the only writer of this field, so this is the only place the gate belongs.
                    priorRelationship: p.priorRelationshipForDrafting,
                    production: p.production,
                    // #1308 Phase 4: draft_only when a probe already found this show's contact, so a first
                    // prep skips the expensive hunt. An explicit re-prep still wins (inside prepMode).
                    reprepMode: PrepQueueBuilder.prepMode(
                        hasDraft: p.hasDraft,
                        reprepDraftRequested: p.reprepDraftRequested,
                        reprepContactsRequested: p.reprepContactsRequested,
                        probedWithContact: p.reachabilityProbedAt != nil
                            && p.recipients.contains(where: { !($0.email ?? "").isEmpty })),
                    // #1122: set only when the opening night has passed while later dates remain, so the
                    // drafter pitches only the remaining dates and never names the gone opening. Absent
                    // otherwise (single-night, or a run not yet started), so the common case is unchanged.
                    openingNightPassed: PrepQueueBuilder.openingNightPassed(
                        performanceDate: p.performanceDate, runEndDate: p.runEndDate, today: today)
                        ? true : nil
                )
            }
        return PrepQueueBuilder.build(from: items, generatedAt: generatedAt)
    }

    // #1308 Layer 2: build a reachability PROBE work-list DIRECTLY from Dan's hand-picked keys, bypassing
    // `needsPrepEligible` entirely. That gate never admits a Review-stage `.new` show (PrepQueue.needsPrep),
    // but a probe's whole point is to research contacts BEFORE keep/dismiss, so the keys Dan chose ARE the
    // authority here. Every item is contacts-only, which is what tells the runner not to draft (no new wire
    // field needed); the app tracks "this run is a probe" in its own run-type state, not in the queue JSON.
    // `needsPrep`/the prep pill are left completely untouched.
    static func buildProbeQueue(from context: ModelContext, generatedAt: String, keys: Set<String>) -> PrepQueue {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let items: [PrepQueueItem] = all
            .filter { keys.contains($0.naturalKey) }
            .map { p in
                PrepQueueItem(
                    naturalKey: p.naturalKey,
                    groupName: p.groupName,
                    venue: p.venue,
                    performanceDate: p.performanceDate,
                    runEndDate: p.runEndDate,
                    discipline: p.discipline,
                    websiteURL: p.websiteURL,
                    sourceListingURL: p.sourceListingURL,
                    possibleMatchName: p.possibleMatchName,
                    priorRelationship: p.priorRelationshipForDrafting,
                    production: p.production,
                    // Contacts-only: find the contact, never draft. The importer's code gate enforces the
                    // no-draft rule regardless, but the runner should not spend on drafting either.
                    reprepMode: "contacts_only")
            }
        return PrepQueueBuilder.build(from: items, generatedAt: generatedAt)
    }

    // #1308 Layer 2: the probe-run side marker (which shows a live probe is researching). Lives beside the
    // shared prep marker; its presence is how the completion path tells a probe from a normal prep run.
    static var defaultProbeRunURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("reachability-probe-run.json")
    }

    // Launch a reachability probe over Dan's hand-picked keys. Mirrors startPrep's lock dance exactly
    // (atomic marker acquire, so a probe and a prep can never both hold the single runner slot), but builds
    // a contacts-only probe queue and records the probed keys in the probe-run marker for the completion
    // path. A probe never drafts, so it skips the voice/openers handoffs startPrep refreshes.
    @discardableResult
    static func startReachabilityProbe(keys: Set<String>, from context: ModelContext, now: Date,
                                       queueURL: URL = PrepQueueBuilder.defaultURL,
                                       markerURL: URL = defaultMarkerURL,
                                       probeRunURL: URL = defaultProbeRunURL,
                                       cancelURL: URL = defaultCancelURL,
                                       launch: @MainActor () throws -> Void = launchRunner) throws -> Int {
        guard !isRunning(markerURL: markerURL, now: now) else { throw PrepLaunchError.alreadyRunning }

        let stamp = ISO8601DateFormatter().string(from: now)
        let queue = buildProbeQueue(from: context, generatedAt: stamp, keys: keys)
        guard !queue.items.isEmpty else { throw PrepLaunchError.nothingToPrep }

        // Atomic lock acquire, identical to startPrep (#480): clear a stale marker, then exclusive-create.
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: markerURL)
        do {
            try Data().write(to: markerURL, options: .withoutOverwriting)
        } catch {
            throw PrepLaunchError.alreadyRunning
        }
        try? FileManager.default.removeItem(at: cancelURL)

        do {
            let data = try PrepQueueBuilder.encode(queue)
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: queueURL, options: .atomic)
            // Record which shows this probe covers, so completion can mark them probed even on an empty run.
            try ReachabilityProbeMarker.write(
                ReachabilityProbeMarker(keys: Set(queue.items.map(\.naturalKey)), startedAt: stamp),
                to: probeRunURL)
            try launch()
            UserDefaults.standard.set(now, forKey: lastRunKey)
        } catch {
            try? FileManager.default.removeItem(at: markerURL)   // release the lock if we never launched
            ReachabilityProbeMarker.clear(at: probeRunURL)
            throw error
        }
        return queue.items.count
    }

    // #1308 Layer 2: mark every probed show probed on completion, whether or not the run found a contact,
    // so the Review badge resolves to email-found/not-found instead of sticking on the free heuristic. Runs
    // BEFORE the probe-safe ingest overlays any found contacts.
    static func markProbed(keys: Set<String>, in context: ModelContext, now: Date) {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        for p in all where keys.contains(p.naturalKey) {
            p.reachabilityProbedAt = now
        }
        try? context.save()
    }

    // #1308 Layer 2: settle a finished detached run. A probe and a real Prep share the runner and results
    // file, so the probe-run marker is what tells them apart. Returns true when the finished run was a
    // probe (and was settled): every probed show is marked probed (found or not), the results are ingested
    // probe-safely (never a draft), and the marker is cleared. Returns false when no probe marker is
    // present, so the caller ingests the run as a normal prep. Called on both producedResults and
    // finishedEmpty: a probe that found nothing is a valid "no email found" result, not a failure.
    @discardableResult
    static func settleReachabilityProbe(markerURL: URL = defaultProbeRunURL,
                                        resultsURL: URL = PrepImporter.defaultURL,
                                        into context: ModelContext, now: Date,
                                        defaults: UserDefaults = .standard) -> Bool {
        guard let marker = (try? ReachabilityProbeMarker.read(from: markerURL)) ?? nil else { return false }
        markProbed(keys: marker.keys, in: context, now: now)
        _ = PrepImporter.consumeIfNew(at: resultsURL, into: context, defaults: defaults,
                                      ingest: { try PrepImporter.ingestFile(at: $0, into: $1, isProbe: true, now: now) })
        ReachabilityProbeMarker.clear(at: markerURL)
        return true
    }

    enum PrepLaunchError: LocalizedError {
        case nothingToPrep
        case runnerUnavailable
        case alreadyRunning

        var errorDescription: String? {
            switch self {
            case .nothingToPrep:
                return "No kept prospects need prepping. Keep some prospects first."
            case .runnerUnavailable:
                return "Couldn't find the Prep runner. Make sure Claude Code is installed and the Overture project is set up."
            case .alreadyRunning:
                return "A Prep run is already in progress. Wait for it to finish."
            }
        }
    }

    // The in-flight marker the runner script drops on start and removes on exit. The
    // app also writes it on launch so the double-run guard is immediate (no race with
    // the detached script). While genuinely working the runner HEARTBEATS the marker
    // (touches it ~every 60s, see prep-run.sh), so a long multi-prospect batch never
    // looks stale (#47). The window is therefore a few-missed-beats crash detector, not
    // a guess at total run time: a marker untouched past it means the run died, so the
    // app can never get permanently stuck "running" yet also never falsely frees the
    // double-run guard mid-batch.
    static let markerStaleAfter: TimeInterval = RunTimeouts.prep

    static var defaultMarkerURL: URL {
        StoreLocation.handoffDirectory
            .appendingPathComponent("prep-running")
    }

    // #1038: the cooperative-cancel sentinel. Prep is launched through the same DetachedRunner as scout,
    // so its run has no trackable PID (backgrounded via `sh -c '... &'` with no handle) and a hard kill is
    // impossible; instead the app writes this file and the runner checks for it on each heartbeat tick and
    // stops cleanly. Same pattern and same predicates (`lib/scout-cancel.sh`) as ScoutExtractService.
    static var defaultCancelURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("prep-cancel")
    }

    // Ask a running Prep run to stop. Writing the sentinel IS the request; the runner reads only its
    // presence, never its contents. Best-effort: if the run has already finished, the next startPrep
    // clears the file so it can never affect a later run.
    static func requestCancel(cancelURL: URL = defaultCancelURL) {
        try? FileManager.default.createDirectory(at: cancelURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data().write(to: cancelURL)
    }

    static func isRunning(markerURL: URL = defaultMarkerURL, now: Date) -> Bool {
        DetachedRunner.isRunning(markerURL: markerURL, now: now, staleAfter: markerStaleAfter)
    }

    // #1322: whether the in-flight detached run is a reachability probe (its marker is present) rather than
    // a normal Prep. A probe and a prep share the single run lock, so isRunning alone can't tell them
    // apart; the probe-run marker, written on launch and cleared on settle, is what distinguishes them.
    // Requires the run to actually be live (a stale lock past a crash is not a running probe).
    static func isProbeRunning(probeRunURL: URL = defaultProbeRunURL,
                               markerURL: URL = defaultMarkerURL, now: Date) -> Bool {
        guard isRunning(markerURL: markerURL, now: now) else { return false }
        return ((try? ReachabilityProbeMarker.read(from: probeRunURL)) ?? nil) != nil
    }

    // Writes the work-list and launches the detached run. Returns the count queued.
    // URLs are injectable for testing; production uses the default locations.
    @discardableResult
    static func startPrep(from context: ModelContext, now: Date,
                          includedKeys: Set<String>? = nil,
                          queueURL: URL = PrepQueueBuilder.defaultURL,
                          markerURL: URL = defaultMarkerURL,
                          voiceFeedbackURL: URL = VoiceFeedbackBuilder.defaultURL,
                          recentOpenersURL: URL = RecentOpenersBuilder.defaultURL,
                          cancelURL: URL = defaultCancelURL,
                          launch: @MainActor () throws -> Void = launchRunner) throws -> Int {
        guard !isRunning(markerURL: markerURL, now: now) else { throw PrepLaunchError.alreadyRunning }

        let stamp = ISO8601DateFormatter().string(from: now)
        // #5 Phase 1: stamp an A/B arm onto each eligible prospect under the active experiment (sticky,
        // forward-only), and PERSIST it here, BEFORE the queue is built and encoded, so a later phase's
        // drafter instruction can never name an arm the store didn't record. No active experiment is a
        // no-op, so this changes nothing until Dan starts an experiment. Fail-loud: a save failure throws.
        // Assigned over the SAME eligible set buildQueue encodes (shared eligibleProspects), never the
        // probe path (buildProbeQueue), which must never consume an assignment.
        try ExperimentAssignment.assignArms(
            to: eligibleProspects(from: context, includedKeys: includedKeys), in: context)
        // #953: only the rows Dan checked in the Prep sheet. nil (the default) keeps every eligible
        // prospect, so nothing but the sheet ever narrows the run.
        let queue = buildQueue(from: context, generatedAt: stamp, includedKeys: includedKeys)
        guard !queue.items.isEmpty else { throw PrepLaunchError.nothingToPrep }

        // Take the lock ATOMICALLY (#480, mirrors ReplyClassifyService): clear any stale marker, then
        // exclusive-create so two near-simultaneous starts can't both proceed and clobber the shared
        // results file. If the exclusive create fails, a racer already holds the lock.
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: markerURL)
        do {
            try Data().write(to: markerURL, options: .withoutOverwriting)
        } catch {
            throw PrepLaunchError.alreadyRunning
        }

        // #1038: clear any leftover cancel sentinel before this run starts, so a stale one from a
        // previously cancelled run can never make the new run's heartbeat stop on its first tick. The
        // runner clears it too, as defence in depth.
        try? FileManager.default.removeItem(at: cancelURL)

        do {
            let data = try PrepQueueBuilder.encode(queue)
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: queueURL, options: .atomic)

            // Refresh the voice-learning handoff so the run drafts with Dan's latest edits (#241). Best
            // effort: a feedback-write failure must never block the Prep run itself.
            try? VoiceFeedbackService.export(from: context, generatedAt: stamp, url: voiceFeedbackURL)

            // Refresh the cross-run anti-repetition handoff so the run steers away from openers recent
            // runs already used (#730). Same best-effort contract: a write failure never blocks the run.
            try? RecentOpenersService.export(from: context, generatedAt: stamp, url: recentOpenersURL)

            // Back up the voice-guidance file so Dan's notes can be restored if the run drops them (#251).
            VoiceNotesProtector.backup(fileURL: VoiceGuidanceGuard.defaultURL,
                                       backupURL: VoiceNotesProtector.defaultBackupURL)

            try launch()
            UserDefaults.standard.set(now, forKey: lastRunKey)
        } catch {
            try? FileManager.default.removeItem(at: markerURL)   // release the lock if we never launched
            throw error
        }
        return queue.items.count
    }

    static let lastRunKey = "prepLastRunStartedAt"

    // Prep could not have run before Overture existed, so any persisted timestamp older than this
    // floor is a sentinel/epoch artifact (e.g. a fresh Debug store) and means "never ran".
    nonisolated static let earliestPlausibleRun = Date(timeIntervalSince1970: 1_577_836_800) // 2020-01-01 UTC

    // #333: collapse an implausibly-old stored date to nil so the header reads "never" (omits the
    // clause) instead of rendering a ~56-year "last prep 20632d ago".
    nonisolated static func sanitizedLastRun(_ stored: Date?) -> Date? {
        guard let stored, stored >= earliestPlausibleRun else { return nil }
        return stored
    }

    static var lastRunStartedAt: Date? {
        sanitizedLastRun(UserDefaults.standard.object(forKey: lastRunKey) as? Date)
    }

    // Launches the Prep runner script detached. The script (docs/prep-runbook) drives
    // a Claude Code run that reads the queue and writes overture-prep-results.json.
    // Resolved from a known location so the app never blocks on it.
    private static func launchRunner() throws {
        guard let script = runnerScriptURL(), FileManager.default.isExecutableFile(atPath: script.path) else {
            throw PrepLaunchError.runnerUnavailable
        }
        try DetachedRunner.launch(scriptPath: script.path,   // detached; never waits
                                  supportDirectory: StoreLocation.handoffDirectory)
    }

    // The runner script (mac/scripts/prep-run.sh in the repo). Path is configured once via a string
    // default so it is not hardcoded into the binary:
    //   defaults write com.danwright.overture prepRunnerScriptPath "/abs/path/to/mac/scripts/prep-run.sh"
    // Returns nil when unset, so startPrep fails gracefully with "runner unavailable".
    static func runnerScriptURL() -> URL? {
        DetachedRunner.scriptURL(defaultsKey: "prepRunnerScriptPath")
    }
}
