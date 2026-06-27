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
