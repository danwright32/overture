import Testing
import Foundation

// #1011. A run that wrote nothing used to inherit the PREVIOUS run's results file wholesale:
// ensure_every_queued_source_reported appended its not_read entries to whatever was lying there and
// carried that file's generatedAt across. On 2026-07-16 the app ingested a results file stamped 4.5
// hours before the queue it was answering, carrying two real-looking sources the run had never been
// asked about, and reported them to Dan as the model having rebuilt an id. It had not: they were
// simply the last run's leftovers.
//
// Drives the REAL shell functions, because the bug was in the shell and a Swift reimplementation of
// it would prove nothing about the file that actually runs.
@Suite("A previous run's results cannot survive into this one (#1011)")
struct StaleResultsGuardTests {
    private static let repoRoot = RepoRoot.url

    private static var lib: String {
        repoRoot.appendingPathComponent("mac/scripts/lib/results-guard.sh").path
    }

    /// Runs `body` in a shell with results-guard.sh sourced. Returns (exitStatus, stdout).
    @discardableResult
    private func sh(_ body: String) throws -> (status: Int32, out: String) {
        let script = ". \"\(Self.lib)\"\n" + body
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        // node lives in the homebrew prefix; the guard degrades to a no-op without it, which would
        // make every expectation below pass for the wrong reason.
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("StaleResultsGuardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func discardsAResultsFileLeftByTheLastRun() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let results = dir.appendingPathComponent("results.json")
        try #"{"version":1,"results":[]}"#.write(to: results, atomically: true, encoding: .utf8)

        try sh("discard_previous_results \"\(results.path)\"")

        #expect(!FileManager.default.fileExists(atPath: results.path))
    }

    @Test func discardingIsSilentWhenThereIsNothingToDiscard() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let missing = dir.appendingPathComponent("nope.json")

        let r = try sh("discard_previous_results \"\(missing.path)\" && echo SURVIVED")

        #expect(r.out.contains("SURVIVED"))
    }

    // The actual 2026-07-16 shape: last run's results still on disk, this run writes nothing. The
    // stale sources must not reach the app, and the surviving file must answer THIS queue.
    @Test func aStaleFilesSourcesNeverReachTheApp() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = dir.appendingPathComponent("queue.json")
        let results = dir.appendingPathComponent("results.json")
        let log = dir.appendingPathComponent("run.log")

        try #"{"version":2,"generatedAt":"2026-07-17T00:44:20Z","items":[{"sourceId":"asked-org"}]}"#
            .write(to: queue, atomically: true, encoding: .utf8)
        // Hours older than the queue, and about a source this run was never given.
        try #"{"version":2,"generatedAt":"2026-07-16T20:09:10Z","results":[{"sourceId":"leftover-org","verdict":"upcoming_listings","events":[{"title":"ghost"}]}]}"#
            .write(to: results, atomically: true, encoding: .utf8)
        try "boot\n".write(to: log, atomically: true, encoding: .utf8)

        // What the runner now does: bin the last run's file, then let the model write nothing at all.
        try sh("""
        discard_previous_results "\(results.path)"
        ensure_every_queued_source_reported "\(queue.path)" "\(results.path)" "\(log.path)" 0
        """)

        let body = try String(contentsOf: results, encoding: .utf8)
        #expect(!body.contains("leftover-org"))
        #expect(!body.contains("ghost"))
        #expect(!body.contains("2026-07-16T20:09:10Z"))
        #expect(body.contains("asked-org"))
        #expect(body.contains("not_read"))
    }

    // Fail loud: claude exiting 0 while writing nothing is a FAILED run, and the guard has to say so
    // rather than let the runner log success over it.
    @Test func aRunThatCameBackWithNothingIsReportedAsMissing() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = dir.appendingPathComponent("queue.json")
        let results = dir.appendingPathComponent("results.json")
        let log = dir.appendingPathComponent("run.log")
        try #"{"version":2,"items":[{"sourceId":"asked-org"}]}"#
            .write(to: queue, atomically: true, encoding: .utf8)
        try "boot\n".write(to: log, atomically: true, encoding: .utf8)

        let r = try sh("""
        ensure_every_queued_source_reported "\(queue.path)" "\(results.path)" "\(log.path)" 0
        echo "MISSING=${RESULTS_MISSING_SOURCES}"
        """)

        #expect(r.out.contains("MISSING=1"))
    }

    // The other half of that claim: a run that DID come back must not be flagged, or the runner would
    // start reporting every healthy scout as a failure and the signal would be worth nothing.
    @Test func aRunThatReportedEverySourceIsNotFlagged() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let queue = dir.appendingPathComponent("queue.json")
        let results = dir.appendingPathComponent("results.json")
        let log = dir.appendingPathComponent("run.log")
        try #"{"version":2,"items":[{"sourceId":"asked-org"}]}"#
            .write(to: queue, atomically: true, encoding: .utf8)
        try #"{"version":2,"generatedAt":"2026-07-17T00:50:00Z","results":[{"sourceId":"asked-org","verdict":"all_past","events":[]}]}"#
            .write(to: results, atomically: true, encoding: .utf8)
        try "boot\n".write(to: log, atomically: true, encoding: .utf8)

        let r = try sh("""
        ensure_every_queued_source_reported "\(queue.path)" "\(results.path)" "\(log.path)" 0
        echo "MISSING=${RESULTS_MISSING_SOURCES}"
        """)

        #expect(r.out.contains("MISSING=0"))
    }

    // #1013: PR #1011 wired discard_previous_results into scout-extract-run.sh only. prep-run.sh and
    // reply-classify-run.sh still left the last run's results file on disk, the exact #1011 bug in the
    // two runners that find contacts and draft Dan's actual emails.
    //
    // Written to FIND every runner that drives a headless claude, not to check the three we happen to
    // know about today: a careful list is exactly what missed prep and reply-classify the first time
    // (mirrors DetachedRunCeremonyGuardTests.everyClaudeRunnerSourcesTheSharedSetup).
    @Test func everyClaudeRunnerDiscardsItsPreviousResultsFirst() throws {
        let scripts = RepoRoot.mac
            .appendingPathComponent("scripts")

        let names = try FileManager.default.contentsOfDirectory(atPath: scripts.path)
            .filter { $0.hasSuffix(".sh") }
            .sorted()

        var drivers: [String] = []
        for name in names {
            let body = try String(contentsOf: scripts.appendingPathComponent(name), encoding: .utf8)
            guard body.contains("\"$CLAUDE\" -p") || body.contains("$CLAUDE -p") else { continue }
            drivers.append(name)

            guard let discardRange = body.range(of: "discard_previous_results \"$RESULTS\"") else {
                Issue.record("""
                    \(name) drives a headless claude but never discards the previous run's results, so a \
                    run that writes nothing inherits stale data from hours ago (#1011's bug, in a runner \
                    that missed the fix).
                    """)
                continue
            }
            // NOT just present: it must run BEFORE claude is launched, or the stale file is still there
            // while the run starts, which is exactly the bug's timing.
            guard let claudeRange = body.range(of: "\"$CLAUDE\" -p") ?? body.range(of: "$CLAUDE -p")
            else { continue }
            #expect(discardRange.lowerBound < claudeRange.lowerBound,
                    "\(name) discards the previous results AFTER launching claude, which is too late.")
        }

        // If this trips, a runner was renamed or removed: re-point the guard rather than deleting it.
        #expect(drivers.contains("scout-extract-run.sh"))
        #expect(drivers.contains("prep-run.sh"))
        #expect(drivers.contains("reply-classify-run.sh"))
    }
}
