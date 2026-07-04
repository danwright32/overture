import Testing
import Foundation

// DetachedRunner.launch() redirects the whole script invocation's stdout/stderr to /dev/null, and
// each runner script only starts appending to its own run log at the final `claude` invocation, so a
// script that exits at an earlier guard (no work-list, no claude CLI) leaves zero trace anywhere,
// indistinguishable from "ran and found nothing" (#485). Runs the real scripts the way the app does,
// with the queue guard forced to fail, to prove the failure now reaches the run log.
@Suite("Runner script early-failure logging")
struct RunnerScriptLoggingTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // OvertureTests
        .deletingLastPathComponent() // mac
        .deletingLastPathComponent() // repo root

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
}
