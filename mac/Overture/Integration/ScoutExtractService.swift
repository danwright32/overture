import Foundation

// #799 slice 3b: hand a batch of already-pinned listings pages to ONE detached Claude run, and get out
// of the way. Mirrors ReplyClassifyService and shares DetachedRunner's launch + marker machinery, so
// there is one convention for these runs and not two. The app does not supervise the run; it ingests
// the results file later.
//
// ONE run for the whole batch, never one per source. "N sources means N subprocesses" is a defect: a
// single hung source would block the marker guard, and an unbounded fan of subprocesses behind a bare
// spinner is what CLAUDE.md's progress rule exists to forbid (working, still-alive, and failed must be
// visibly different states). One run also gives a real "3 of 9" progress file.
@MainActor
enum ScoutExtractService {
    enum ExtractLaunchError: LocalizedError, Equatable {
        case nothingToExtract, alreadyRunning
        // #2838: it CARRIES its reason. The setting it reads lives outside the repo and holds an absolute
        // path, so the interesting question is always which setting is wrong and what it points at, and a
        // fixed sentence cannot say either (L11, L80).
        case runnerUnavailable(String)
        // #849: a test tried to launch a REAL detached Claude run. Refused, loudly.
        case refusedUnderTest

        var errorDescription: String? {
            switch self {
            case .nothingToExtract:
                return "No sources need re-reading right now."
            case .runnerUnavailable(let reason):
                // Named and actionable, never silence. This is the FIRST thing Dan hits, before he has
                // pointed the app at the script, and the failure it replaces (an unset defaults key
                // making scriptURL nil) is a feature that quietly never runs. #2838: the reason is built
                // by RunnerScripts, which is what knows which of the routes failed and what each one was.
                return reason
            case .alreadyRunning:
                return "A scout-extract run is already in progress. Wait for it to finish."
            case .refusedUnderTest:
                // Dan will never see this. It is for whoever wrote the test that tried it.
                return "A test tried to launch a real Claude run. Inject the launch seam instead."
            }
        }
    }

    // A detached run that reads several pages and follows each event's detail page runs far past the
    // scout's own 3-minute in-process ceiling. Matched to replyClassify, the other heavy detached run.
    // The atomic marker lock below is the real guard against a double run; this window only frees a
    // run that genuinely died.
    static let markerStaleAfter: TimeInterval = RunTimeouts.scoutExtract

    static var defaultMarkerURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("scout-extract-running")
    }

    // #1037: the cooperative-cancel sentinel. The detached read has no trackable PID (DetachedRunner
    // backgrounds it via `sh -c '... &'` and keeps no handle), so a hard kill is impossible; instead the
    // app writes this file and the runner checks for it on each heartbeat tick and stops cleanly. See
    // docs/contracts.md and scripts/lib/scout-cancel.sh (the reader).
    static var defaultCancelURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("scout-extract-cancel")
    }

    // Ask a running read to stop. Writing the sentinel IS the request; the runner reads only its
    // presence, never its contents. Best-effort: if the run has already finished, the next startExtract
    // clears the file so it can never affect a later run.
    static func requestCancel(cancelURL: URL = defaultCancelURL) {
        try? FileManager.default.createDirectory(at: cancelURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data().write(to: cancelURL)
    }

    // #2104: sweep a read that DIED rather than finished. Same shape and same shared implementation as
    // Prep's (#1613): the runner removes its own marker on the way out, so a marker still there when the
    // read stops being live means it stopped somewhere it never reached that exit, and Cancel (which
    // writes a sentinel only a live runner reads) can no longer do anything. Judged against THIS run's
    // own window, because a calendar read and a reply draft take nothing like the same time.
    @discardableResult
    static func clearDeadRun(markerURL: URL = defaultMarkerURL, cancelURL: URL = defaultCancelURL,
                             now: Date) -> Bool {
        DetachedRunner.sweepDeadRun(markerURL: markerURL, cancelURL: cancelURL, now: now,
                                    staleAfter: markerStaleAfter)
    }

    static func isRunning(markerURL: URL = defaultMarkerURL, now: Date) -> Bool {
        DetachedRunner.isRunning(markerURL: markerURL, now: now, staleAfter: markerStaleAfter)
    }

    // #1822: the same marker, read for whether it is beating, stale, or gone. A progress screen needs
    // the difference between the last two; `isRunning` cannot carry it.
    static func heartbeat(markerURL: URL = defaultMarkerURL, now: Date) -> RunHeartbeat {
        DetachedRunner.heartbeat(markerURL: markerURL, now: now, staleAfter: markerStaleAfter)
    }

    static let lastRunKey = "scoutExtractLastRunStartedAt"

    static var lastRunStartedAt: Date? {
        PrepQueueService.sanitizedLastRun(UserDefaults.standard.object(forKey: lastRunKey) as? Date)
    }

    // The items are pages the app has ALREADY fetched, normalized, hashed and pinned (SourceFetcher /
    // ScoutPagePin). A source whose page hash was unchanged since the last successful check never gets
    // here at all: that skip is the entire cost model, so it belongs upstream of the run, not inside it.
    @discardableResult
    static func startExtract(items: [ScoutExtractQueueItem], now: Date,
                             queueURL: URL = ScoutExtractQueueBuilder.defaultURL,
                             markerURL: URL = defaultMarkerURL,
                             defaults: UserDefaults = .standard,
                             cancelURL: URL = defaultCancelURL,
                             launch: @MainActor () throws -> Void = launchRunner) throws -> Int {
        // #849: refused BEFORE anything is written, when a test is about to use the LIVE handoff paths.
        // Precise on purpose: a test that injects temp paths and a fake launcher is safe, and several
        // legitimately do exactly that. What must never happen is the suite writing a real queue file
        // into the directory the running app reads (a stale one from a test called "fine" is what later
        // hung Dan's Add-a-lead sheet on a source it had never asked about).
        //
        // The real launcher carries the same guard, as defence in depth: this one stops the file, that
        // one stops the process.
        if AppEnvironment.isRunningUnderTests, queueURL == ScoutExtractQueueBuilder.defaultURL {
            throw ExtractLaunchError.refusedUnderTest
        }
        guard !isRunning(markerURL: markerURL, now: now) else { throw ExtractLaunchError.alreadyRunning }
        guard !items.isEmpty else { throw ExtractLaunchError.nothingToExtract }

        // Take the lock ATOMICALLY: clear a stale marker, then exclusive-create, so two near-
        // simultaneous starts cannot both proceed and clobber the shared results file (a lost update
        // there silently drops every source the first run had read).
        try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: markerURL)
        do {
            try Data().write(to: markerURL, options: .withoutOverwriting)
        } catch {
            throw ExtractLaunchError.alreadyRunning
        }

        // #1037: clear any leftover cancel sentinel before this run starts, so a stale one from a
        // previously cancelled run can never make the new run's heartbeat stop on its first tick. The
        // runner clears it too, as defence in depth.
        try? FileManager.default.removeItem(at: cancelURL)

        do {
            let stamp = ISO8601DateFormatter().string(from: now)
            let queue = ScoutExtractQueueBuilder.build(items: items, generatedAt: stamp)
            let data = try ScoutExtractQueueBuilder.encode(queue)
            try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: queueURL, options: .atomic)
            try launch()   // the script heartbeats and clears the marker from here on
            defaults.set(now, forKey: lastRunKey)
        } catch {
            // Release the lock if we never actually launched. Without this, a misconfigured runner
            // (the first thing Dan will hit) would take the marker and then refuse every future
            // attempt with "already running", forever, with no run alive to clear it.
            try? FileManager.default.removeItem(at: markerURL)
            throw error
        }
        return items.count
    }

    // #849: the guard lives HERE, in the one function that actually spawns a process, and not in
    // startExtract around it. A test that injects a fake launcher and temp paths is perfectly safe and
    // several legitimately do exactly that; what must never happen is the REAL launcher running under
    // test. The suite was doing it on every run, including CI, because tests that injected the extractor
    // and the fetch but not the launch got this one by default.
    //
    // It THROWS rather than quietly no-opping: a silent success would let a test believe it had launched
    // a run and then assert against a results file nobody asked for, which is a subtler version of the
    // same bug.
    private static func launchRunner() throws {
        guard !AppEnvironment.isRunningUnderTests else { throw ExtractLaunchError.refusedUnderTest }
        // #2838: the stored setting if it still names a runnable script, otherwise derived from the
        // checkout the installed build recorded. The refusal carries what was tried, so it can name the
        // setting and the path rather than saying only that something is missing.
        let script: URL
        switch DetachedRunner.resolveRunner(.scoutExtract) {
        case .configured(let url), .derivedFromInstalledRepo(let url):
            script = url
        case .unavailable(let configuredPath, let derivedPath):
            throw ExtractLaunchError.runnerUnavailable(
                RunnerScripts.unavailableMessage(.scoutExtract, configuredPath: configuredPath,
                                                 derivedPath: derivedPath))
        }
        try DetachedRunner.launch(scriptPath: script.path,
                                  supportDirectory: StoreLocation.handoffDirectory)
    }
}
