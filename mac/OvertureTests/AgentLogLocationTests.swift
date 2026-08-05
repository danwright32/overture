import Foundation
import Testing
import Darwin

@Suite("Agent log location (#279)")
struct AgentLogLocationTests {
    @Test func directoryLivesUnderUserLibraryLogsNotTmp() {
        let path = AgentLogLocation.directory.path
        #expect(path.contains("Library/Logs/Overture"))
        #expect(!path.hasPrefix("/tmp"))
    }

    @Test func logFilesSitInsideTheDirectoryWithStableNames() {
        let dir = AgentLogLocation.directory.path
        #expect(AgentLogLocation.standardOutURL.path.hasPrefix(dir))
        #expect(AgentLogLocation.standardErrorURL.path.hasPrefix(dir))
        #expect(AgentLogLocation.standardOutURL.lastPathComponent == "overture-agent.out.log")
        #expect(AgentLogLocation.standardErrorURL.lastPathComponent == "overture-agent.err.log")
        // #1689: the ledger sits beside them, so opening the agent logs reaches it in the same click.
        #expect(AgentLogLocation.problemsURL.path.hasPrefix(dir))
        #expect(AgentLogLocation.problemsURL.lastPathComponent == "overture-agent.problems.log")
    }

    // #1689/#295: the ledger is bounded like the other two, or an app that keeps naming one recurring
    // problem grows a file nothing ever trims.
    @Test func theProblemLedgerIsCappedAlongsideTheOtherLogs() {
        #expect(AgentLogLocation.cappedFiles.contains(AgentLogLocation.problemsURL))
    }

    @Test func prepareCreatesTheDirectoryOwnerOnly() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        let dir = base.appendingPathComponent("Overture", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        AgentLogLocation.prepareDirectory(at: dir)

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        #expect(isDir.boolValue)
        let perms = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o700)
    }

    // #296: the "Open agent logs" menu item ensures the directory exists, then hands Finder the log
    // directory — so the click never opens Finder to a missing folder.
    @Test func revealEnsuresTheDirectoryThenOpensIt() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        let dir = base.appendingPathComponent("Overture", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        var opened: URL?
        let returned = AgentLogLocation.revealInFinder(directory: dir, open: { opened = $0 })

        #expect(opened == dir)
        #expect(returned == dir)
        #expect(FileManager.default.fileExists(atPath: dir.path))
    }

    // #295: an always-resident agent's stdout/stderr would otherwise grow without bound. A file past
    // the cap is rotated logrotate-style: its contents move to a single ".1" backup and the live file
    // is truncated, so disk stays bounded at ~2x the cap.
    @Test func capLogsRotatesAFileOverTheCapAndKeepsABackup() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("overture-agent.err.log")
        let contents = String(repeating: "x", count: 4_096)
        try contents.write(to: file, atomically: true, encoding: .utf8)

        let rotated = AgentLogLocation.capLogs(maxBytes: 1_024, files: [file])

        #expect(rotated == [file])
        #expect((try Data(contentsOf: file)).isEmpty)   // live file truncated
        let backup = dir.appendingPathComponent("overture-agent.err.log.1")
        #expect(try String(contentsOf: backup, encoding: .utf8) == contents)   // old contents preserved
    }

    @Test func capLogsLeavesAFileUnderTheCapUntouched() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("overture-agent.err.log")
        try "small".write(to: file, atomically: true, encoding: .utf8)

        let rotated = AgentLogLocation.capLogs(maxBytes: 1_024, files: [file])

        #expect(rotated.isEmpty)
        #expect(try String(contentsOf: file, encoding: .utf8) == "small")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("overture-agent.err.log.1").path))
    }

    // The rotation MUST truncate in place, not replace the file: launchd opens these logs in append
    // mode before the agent starts and holds them open, so a new inode would orphan the agent's writes.
    @Test func capLogsTruncatesInPlacePreservingTheInode() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("overture-agent.err.log")
        try String(repeating: "x", count: 4_096).write(to: file, atomically: true, encoding: .utf8)
        let inodeBefore = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int

        AgentLogLocation.capLogs(maxBytes: 1_024, files: [file])

        let inodeAfter = try FileManager.default.attributesOfItem(atPath: file.path)[.systemFileNumber] as? Int
        #expect(inodeBefore != nil)
        #expect(inodeAfter == inodeBefore)
    }

    // #1689: the nudge reads the ledger of problems the app NAMED, so the very first one raises it.
    // There is no size threshold any more and there must not be one: a threshold existed to tolerate
    // routine chatter, and routine chatter no longer reaches this file, so the only thing a threshold
    // could still do is hide a single real problem behind its own smallness. The line that prompted
    // this issue ("1 of 5 shows answered") is about 130 bytes; the old threshold was 8,192.
    @Test func oneRecordedProblemIsEnoughToRaiseTheNudge() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("overture-agent.problems.log")
        try "2026-08-03 reachability probe settled with 1 of 5 shows answered\n"
            .write(to: file, atomically: true, encoding: .utf8)

        #expect(AgentLogLocation.hasUnreadProblems(viewedSize: 0, problemsLog: file))
    }

    // Opening the logs settles it: nothing new since, nothing to say.
    @Test func noUnreadProblemsWhenNothingWasAddedSinceDanLooked() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("overture-agent.problems.log")
        try String(repeating: "x", count: 1_500).write(to: file, atomically: true, encoding: .utf8)

        #expect(!AgentLogLocation.hasUnreadProblems(viewedSize: 1_500, problemsLog: file))
    }

    @Test func noUnreadProblemsWhenNothingHasEverGoneWrong() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("nope-\(UUID().uuidString).log")
        #expect(!AgentLogLocation.hasUnreadProblems(viewedSize: 0, problemsLog: file))
    }

    // #295 rotation truncates the live file, so a ledger smaller than the recorded view size holds
    // wholly new content: all of it counts, never a negative "growth" that would read as nothing new.
    @Test func treatsATruncatedLedgerAsAllNew() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("overture-agent.problems.log")
        try String(repeating: "x", count: 3_000).write(to: file, atomically: true, encoding: .utf8)

        #expect(AgentLogLocation.hasUnreadProblems(viewedSize: 5_000_000, problemsLog: file))
    }

    // ...but a rotation that leaves the ledger EMPTY is not a new problem. Nothing is in there to read.
    @Test func anEmptiedLedgerIsNotANewProblem() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("overture-agent.problems.log")
        try "".write(to: file, atomically: true, encoding: .utf8)

        #expect(!AgentLogLocation.hasUnreadProblems(viewedSize: 5_000_000, problemsLog: file))
    }

    @Test func recordViewedStoresCurrentProblemLedgerSize() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("overture-agent.problems.log")
        try String(repeating: "x", count: 2_048).write(to: file, atomically: true, encoding: .utf8)
        let defaults = UserDefaults(suiteName: "agentlog-test-\(UUID().uuidString)")!

        AgentLogLocation.recordViewed(problemsLog: file, into: defaults)

        #expect(defaults.double(forKey: AgentLogLocation.viewedProblemSizeKey) == 2_048)
    }

    @Test func prepareTightensAnAlreadyExistingDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        let dir = base.appendingPathComponent("Overture", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        // Pre-create the directory world-readable, as a stray earlier run might have left it.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])

        AgentLogLocation.prepareDirectory(at: dir)

        let perms = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o700)
    }

    @Test func prepareReportsSuccessWhenTheDirectoryEndsUpOwnerOnly() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        let dir = base.appendingPathComponent("Overture", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let result = AgentLogLocation.prepareDirectory(at: dir)

        #expect(result.isOwnerOnly)
    }

    // #524: the old best-effort `try? setAttributes` silently swallowed a failure to narrow an
    // already-existing directory an earlier run left too permissive, so nothing could ever tell a
    // genuinely-still-wide-open directory apart from a successfully-repaired one. Flagging the
    // directory immutable makes chmod fail deterministically (confirmed: chmod itself errors
    // "Operation not permitted" against a uchg-flagged directory even for its owner), so this is a
    // real failure, not a simulated one.
    @Test func prepareReportsFailureWhenAnExistingDirectoryCannotBeNarrowed() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("logs-\(UUID().uuidString)", isDirectory: true)
        let dir = base.appendingPathComponent("Overture", isDirectory: true)
        defer {
            _ = chflags(dir.path, 0)
            try? FileManager.default.removeItem(at: base)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        #expect(chflags(dir.path, UInt32(UF_IMMUTABLE)) == 0)

        let result = AgentLogLocation.prepareDirectory(at: dir)

        #expect(result.isOwnerOnly == false)
        let perms = (try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(perms == 0o755)   // truly unchanged, not silently "fixed"
    }

    // #2003: a test run must not be able to write into the ledger the menu bar reads.
    //
    // Measured on 2026-08-04, before any of this: that file held 443 KB and 112 lines reading
    // "the launch save failed, so no migration was persisted: SaveFailed()". SaveFailed is a stub
    // error type that exists only in the test target, so every one of those lines was written by a
    // test run and describes a launch that never happened.
    //
    // It is the alerting version of a false positive (L36). The ledger is the only thing carrying a
    // real problem to Dan, ANY new byte raises the nudge, and every test run pushes it past the mark,
    // so the reliable way to stop the nudge firing for nothing is to stop believing it. It also
    // destroys the ledger as evidence: nothing in the file records which lines a test wrote.
    //
    // The redirect is keyed on the DIRECTORY rather than the one file, because the fix has to cover
    // the class: every path the app writes diagnostics to lives in there, and a second one added
    // later would otherwise arrive unprotected.

    @Test func aTestRunsProblemGoesToItsOwnLedgerNotTheOneTheMenuBarReads() {
        let landed = AgentLogLocation.writableLedger(AgentLogLocation.problemsURL, isUnderTest: true)

        #expect(landed != AgentLogLocation.problemsURL)
        #expect(landed == AgentLogLocation.testRunLedgerURL)
    }

    @Test func theRealLedgerIsWrittenWhenThisIsNotATestRun() {
        #expect(AgentLogLocation.writableLedger(AgentLogLocation.problemsURL, isUnderTest: false)
                == AgentLogLocation.problemsURL)
    }

    // A test that hands AgentLog its own throwaway file is asserting on what it wrote there, so the
    // redirect must leave it exactly where it asked for. Redirecting everything would take the
    // existing ledger tests down with it.
    @Test func aLedgerATestChoseItselfIsLeftWhereItAskedFor() {
        let chosen = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentlog-\(UUID().uuidString)/problems.log")

        #expect(AgentLogLocation.writableLedger(chosen, isUnderTest: true) == chosen)
    }

    // The class, not the instance: anything inside the live agent log directory is Dan's, whichever
    // file it is.
    @Test func anySiblingFileInTheLiveLogDirectoryIsRedirectedToo() {
        let sibling = AgentLogLocation.directory.appendingPathComponent("overture-agent.err.log")

        #expect(AgentLogLocation.writableLedger(sibling, isUnderTest: true)
                == AgentLogLocation.testRunLedgerURL)
    }

    // The test run's own ledger is somewhere a person could actually go and read, and is nowhere
    // near the live directory, or the redirect would just move the pollution one file sideways.
    @Test func theTestRunLedgerSitsOutsideTheLiveLogDirectory() {
        #expect(!AgentLogLocation.testRunLedgerURL.path.hasPrefix(AgentLogLocation.directory.path))
    }
}
