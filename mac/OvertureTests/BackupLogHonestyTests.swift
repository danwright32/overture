import Testing
import Foundation
import SQLite3
@testable import Overture

// #1410: the backup log has to be able to tell a real backup from a snapshot of somebody else's file.
//
// This is not hypothetical. On 2026-07-23 the #663 guard correctly refused to open the file at the
// store path (icloudmailagent had replaced Overture's tables with its own ZAPIREQUESTMODEL), but the
// snapshot it took first was logged as `20260723-113732 success`, character for character the same as
// the healthy launch backup logged an hour earlier. The log is the one place to look when
// reconstructing what happened to the store, and read at face value it said the most recent backup
// was good.
//
// Two more ways the same log could lie, fixed here with it: a copy that failed outright was still
// logged as a success, and a refusal snapshot counted toward the rotation, so a run of refusals could
// push all ten real backups off the end.
@Suite("The backup log says what actually happened (#1410)")
struct BackupLogHonestyTests {

    private func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-backuplog-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func seedStore(_ dataDirectory: URL, bytes: String = "store-bytes") throws {
        try bytes.write(to: dataDirectory.appendingPathComponent("Overture.store"),
                        atomically: true, encoding: .utf8)
    }

    private func log(_ dataDirectory: URL) throws -> String {
        try String(contentsOf: StoreBackup.backupsDirectory(dataDirectory: dataDirectory)
            .appendingPathComponent("backup.log"), encoding: .utf8)
    }

    private func entries(_ dataDirectory: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: StoreBackup.backupsDirectory(dataDirectory: dataDirectory).path).sorted()
    }

    private let when = Date(timeIntervalSince1970: 1_700_000_000)   // 20231114-171320

    // MARK: - A refusal snapshot is not a backup

    @Test("a snapshot taken because the file was not Overture's is not logged as a success")
    func refusalIsNotLoggedAsSuccess() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedStore(dir)

        _ = StoreBackup.makeBackup(dataDirectory: dir, now: when, reason: .foreignFile)

        let text = try log(dir)
        #expect(text.contains("20231114-171320"))
        #expect(!text.contains("success"))
        #expect(text.contains(StoreBackup.foreignFileLogNote))
    }

    @Test("a normal launch backup still says success")
    func launchStillSaysSuccess() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedStore(dir)

        _ = StoreBackup.makeBackup(dataDirectory: dir, now: when)

        #expect(try log(dir).contains("20231114-171320 success"))
    }

    // Visible in the folder listing too, not only in the log. Someone looking for a backup to restore
    // reads the folder names first, and a refusal snapshot sitting there under a plain date is exactly
    // as misleading there as it was in the log.
    @Test("a refusal snapshot is named so it cannot be mistaken for a backup")
    func refusalFolderIsMarked() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedStore(dir)

        let destination = try #require(StoreBackup.makeBackup(dataDirectory: dir, now: when, reason: .foreignFile))

        #expect(destination.lastPathComponent == "20231114-171320.foreign")
        #expect(try entries(dir).contains("20231114-171320.foreign"))
    }

    // MARK: - A refusal snapshot never ages out a real backup

    @Test("pruning ignores refusal snapshots entirely, keeping them and never counting them")
    func pruneIgnoresRefusalSnapshots() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let backups = StoreBackup.backupsDirectory(dataDirectory: dir)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        for name in ["20260101-090000", "20260102-090000", "20260103-090000",
                     "20260102-120000.foreign", "20260103-120000.foreign"] {
            try FileManager.default.createDirectory(at: backups.appendingPathComponent(name),
                                                    withIntermediateDirectories: true)
        }

        StoreBackup.pruneOldBackups(in: backups, keep: 2)

        // The two newest REAL backups survive (the refusals did not count toward the two), and both
        // refusal snapshots are still there: they are evidence, and deleting them is not this
        // function's business.
        #expect(try entries(dir) == ["20260102-090000", "20260102-120000.foreign",
                                     "20260103-090000", "20260103-120000.foreign"])
    }

    // MARK: - A backup that copied nothing

    private final class RefusingFileManager: FileManager, @unchecked Sendable {
        override func copyItem(at srcURL: URL, to dstURL: URL) throws {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    @Test("a backup whose copy failed is logged as a failure, not a success")
    func failedCopyIsLoggedAsFailure() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        try seedStore(dir)

        let result = StoreBackup.makeBackup(dataDirectory: dir, now: when, fileManager: RefusingFileManager())

        // nil, because there is no backup: a caller must not be handed a folder path implying one.
        #expect(result == nil)
        let text = try log(dir)
        #expect(!text.contains("success"))
        #expect(text.contains(StoreBackup.nothingCopiedLogNote))
        // And the empty folder is not left behind to be counted as one of the ten kept.
        #expect(try !entries(dir).contains("20231114-171320"))
    }

    // MARK: - The 2026-07-23 incident, end to end

    // Builds a real SQLite file with icloudmailagent's table and none of Overture's, puts it exactly
    // where Overture's store lives, and runs the launch decision over it. This is the path that
    // produced the misleading log line, driven by a genuine foreign database rather than a stand-in.
    @Test("the guard's refusal over a real foreign database logs a refusal, not a success")
    func realForeignDatabaseIsLoggedHonestly() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("Overture.store")

        var db: OpaquePointer?
        #expect(sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE ZAPIREQUESTMODEL (Z_PK INTEGER PRIMARY KEY);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        let reason = StoreSchemaGuard.refusalReason(storeURL: storeURL, dataDirectory: dir, now: when)

        #expect(reason != nil)   // it still refuses to open the file
        let text = try log(dir)
        #expect(!text.contains("success"))
        #expect(text.contains(StoreBackup.foreignFileLogNote))
        #expect(try entries(dir).contains("20231114-171320.foreign"))
    }
}
