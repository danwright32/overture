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
        case nothingToExtract, runnerUnavailable, alreadyRunning

        var errorDescription: String? {
            switch self {
            case .nothingToExtract:
                return "No sources need re-reading right now."
            case .runnerUnavailable:
                // Named and actionable, never silence. This is the FIRST thing Dan hits, before he has
                // pointed the app at the script, and the failure it replaces (an unset defaults key
                // making scriptURL nil) is a feature that quietly never runs.
                return "The scout-extract runner isn't set up yet. See docs/scout-extract-runbook.md: point Overture at scout-extract-run.sh and make it executable."
            case .alreadyRunning:
                return "A scout-extract run is already in progress. Wait for it to finish."
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

    static func isRunning(markerURL: URL = defaultMarkerURL, now: Date) -> Bool {
        DetachedRunner.isRunning(markerURL: markerURL, now: now, staleAfter: markerStaleAfter)
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
                             launch: @MainActor () throws -> Void = launchRunner) throws -> Int {
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

    private static func launchRunner() throws {
        guard let script = DetachedRunner.scriptURL(defaultsKey: "scoutExtractRunnerScriptPath"),
              FileManager.default.isExecutableFile(atPath: script.path) else {
            throw ExtractLaunchError.runnerUnavailable
        }
        try DetachedRunner.launch(scriptPath: script.path,
                                  supportDirectory: StoreLocation.handoffDirectory)
    }
}
