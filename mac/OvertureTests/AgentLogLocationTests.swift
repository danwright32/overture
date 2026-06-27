import Foundation
import Testing
@testable import Overture

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
}
