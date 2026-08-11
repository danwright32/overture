import Testing
import Foundation

// DetachedRunner.launch() redirects the whole script invocation's stdout/stderr to /dev/null, and
// each runner script only starts appending to its own run log at the final `claude` invocation, so a
// script that exits at an earlier guard (no work-list, no claude CLI) leaves zero trace anywhere,
// indistinguishable from "ran and found nothing" (#485). Runs the real scripts the way the app does,
// with the queue guard forced to fail, to prove the failure now reaches the run log.
@Suite("Runner script early-failure logging")
struct RunnerScriptLoggingTests {
    private static let repoRoot = RepoRoot.url

    private func runScript(named scriptName: String, logName: String, expectedMessage: String) throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerScriptLoggingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        let scriptPath = Self.repoRoot.appendingPathComponent("mac/scripts/\(scriptName)").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        process.environment = ["OVERTURE_SUPPORT_DIR": supportDir.path, "PATH": "/usr/bin:/bin"]
        try process.run()
        process.waitUntilExit()

        let logURL = supportDir.appendingPathComponent(logName)
        let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        #expect(contents.contains(expectedMessage),
                "expected \(logName) under \(supportDir.path) to contain the early-guard failure, found: \(contents)")
    }

    @Test func prepRunnerLogsMissingQueueBeforeExiting() throws {
        try runScript(named: "prep-run.sh", logName: "prep-run.log", expectedMessage: "no prep queue at")
    }

    @Test func replyClassifyRunnerLogsMissingQueueBeforeExiting() throws {
        try runScript(named: "reply-classify-run.sh", logName: "reply-classify-run.log",
                      expectedMessage: "no reply-classify queue at")
    }

    // The app launches these scripts with a minimal PATH that omits fnm/nvm shim dirs. Once the
    // claude CLI resolved further down spawns its own hooks (e.g. the SessionEnd cleanup hook) as
    // child processes, those hooks inherit that same minimal PATH and silently fail to find node
    // (#636). Proves each script resolves node onto PATH itself, via a stub binary reachable only
    // through PATH lookup, before that minimal PATH ever reaches a child process.
    private func runScriptResolvingNode(named scriptName: String, logName: String) throws {
        let supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerScriptLoggingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDir) }

        let fakeBinDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RunnerScriptLoggingTests-bin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBinDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeBinDir) }
        let fakeNode = fakeBinDir.appendingPathComponent("node")
        try "#!/bin/sh\necho fake-node\n".write(to: fakeNode, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeNode.path)

        let scriptPath = Self.repoRoot.appendingPathComponent("mac/scripts/\(scriptName)").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        process.environment = [
            "OVERTURE_SUPPORT_DIR": supportDir.path,
            "PATH": "\(fakeBinDir.path):/usr/bin:/bin",
        ]
        try process.run()
        process.waitUntilExit()

        let logURL = supportDir.appendingPathComponent(logName)
        let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        #expect(contents.contains("node resolved: \(fakeNode.path)"),
                "expected \(logName) under \(supportDir.path) to record node resolution, found: \(contents)")
    }

    @Test func prepRunnerResolvesNodeOntoPathBeforeExiting() throws {
        try runScriptResolvingNode(named: "prep-run.sh", logName: "prep-run.log")
    }

    @Test func replyClassifyRunnerResolvesNodeOntoPathBeforeExiting() throws {
        try runScriptResolvingNode(named: "reply-classify-run.sh", logName: "reply-classify-run.log")
    }

    // #1711: a runner launched with no HOME in its environment. Every runner declares `set -eu`, so
    // reading $HOME directly aborted the script with "runner-setup.sh: line 26: HOME: unbound
    // variable" before it had opened its run log, which is the traceless early death #485 exists to
    // prevent: the app sends the invocation's stdout and stderr to /dev/null, so the shell's own
    // error reaches nobody and a dead run is indistinguishable from one that found nothing.
    //
    // This is the ONE guard whose message cannot reach the run log, because the run log's own folder
    // is what could not be resolved, so stderr is what it has and stderr is what this reads. The app
    // never launches a run this way; what is being pinned is that the failure explains itself at all.
    //
    // Deliberately runs with no OVERTURE_SUPPORT_DIR either, which is also what makes it safe: with
    // neither variable set there is no path by which this can reach Dan's live handoff folder (L2).
    private func runScriptWithoutHome(named scriptName: String) throws -> (stderr: String, status: Int32) {
        let scriptPath = Self.repoRoot.appendingPathComponent("mac/scripts/\(scriptName)").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptPath]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
    }

    private func expectOwnMessageWithoutHome(scriptName: String) throws {
        let (stderr, status) = try runScriptWithoutHome(named: scriptName)
        #expect(stderr.contains("neither OVERTURE_SUPPORT_DIR nor HOME is set"),
                "expected \(scriptName) to name what is missing, found: \(stderr)")
        #expect(stderr.contains("Set HOME to the account's home folder"),
                "expected \(scriptName) to say what to do about it, found: \(stderr)")
        #expect(!stderr.contains("unbound variable"),
                "expected \(scriptName) to refuse in its own words, not the shell's, found: \(stderr)")
        #expect(status == 1, "expected \(scriptName) to exit 1, got \(status)")
    }

    @Test func prepRunnerRefusesInItsOwnWordsWithNoHome() throws {
        try expectOwnMessageWithoutHome(scriptName: "prep-run.sh")
    }

    @Test func replyClassifyRunnerRefusesInItsOwnWordsWithNoHome() throws {
        try expectOwnMessageWithoutHome(scriptName: "reply-classify-run.sh")
    }

    @Test func scoutExtractRunnerRefusesInItsOwnWordsWithNoHome() throws {
        try expectOwnMessageWithoutHome(scriptName: "scout-extract-run.sh")
    }
}
