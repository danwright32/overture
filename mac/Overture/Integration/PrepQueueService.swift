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
    static func buildQueue(from context: ModelContext, generatedAt: String) -> PrepQueue {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let items: [PrepQueueItem] = all
            .filter { PrepQueueBuilder.needsPrep(status: $0.status, hasDraft: $0.hasDraft) }
            .map { p in
                PrepQueueItem(
                    naturalKey: p.naturalKey,
                    groupName: p.groupName,
                    venue: p.venue,
                    performanceDate: p.performanceDate,
                    discipline: p.discipline,
                    websiteURL: p.websiteURL,
                    sourceListingURL: p.sourceListingURL,
                    possibleMatchName: p.possibleMatchName,
                    priorRelationship: p.priorRelationship
                )
            }
        return PrepQueueBuilder.build(from: items, generatedAt: generatedAt)
    }

    enum PrepLaunchError: LocalizedError {
        case nothingToPrep
        case runnerUnavailable

        var errorDescription: String? {
            switch self {
            case .nothingToPrep:
                return "No kept prospects need prepping. Keep some prospects first."
            case .runnerUnavailable:
                return "Couldn't find the Prep runner. Make sure Claude Code is installed and the Overture project is set up."
            }
        }
    }

    // Writes the work-list and launches the detached run. Returns the count queued.
    // The queue URL is injectable for testing; production uses the default location.
    @discardableResult
    static func startPrep(from context: ModelContext, now: Date,
                          queueURL: URL = PrepQueueBuilder.defaultURL) throws -> Int {
        let stamp = ISO8601DateFormatter().string(from: now)
        let queue = buildQueue(from: context, generatedAt: stamp)
        guard !queue.items.isEmpty else { throw PrepLaunchError.nothingToPrep }

        let data = try PrepQueueBuilder.encode(queue)
        try FileManager.default.createDirectory(at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: queueURL, options: .atomic)

        try launchRunner()
        UserDefaults.standard.set(now, forKey: lastRunKey)
        return queue.items.count
    }

    static let lastRunKey = "prepLastRunStartedAt"

    static var lastRunStartedAt: Date? {
        UserDefaults.standard.object(forKey: lastRunKey) as? Date
    }

    // Launches the Prep runner script detached. The script (docs/prep-runbook) drives
    // a Claude Code run that reads the queue and writes overture-prep-results.json.
    // Resolved from a known location so the app never blocks on it.
    private static func launchRunner() throws {
        guard let script = runnerScriptURL(), FileManager.default.isExecutableFile(atPath: script.path) else {
            throw PrepLaunchError.runnerUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "'\(script.path)' >/dev/null 2>&1 &"]
        try process.run()
        // Detached: do not wait. The run writes the results file when done.
    }

    // The runner script (mac/scripts/prep-run.sh in the repo). Path is configured once
    // via a string default so it is not hardcoded into the binary:
    //   defaults write com.danwright.overture prepRunnerScriptPath "/abs/path/to/mac/scripts/prep-run.sh"
    // Returns nil when unset, so startPrep fails gracefully with "runner unavailable".
    static func runnerScriptURL() -> URL? {
        guard let path = UserDefaults.standard.string(forKey: "prepRunnerScriptPath"), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }
}
