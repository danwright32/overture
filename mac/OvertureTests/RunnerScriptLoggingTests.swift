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
}
