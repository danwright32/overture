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
