import Testing
import Foundation
@testable import Overture

// #601: rotating, launch-time backups of the live SwiftData store, so an app bug or accidental
// wipe doesn't cost every prospect/contact/outreach record. See docs/ or the milestone (#18) for
// the full design; this is the pure, testable copy/prune/log logic, independent of app wiring.
@Suite("Store backup (#601)")
struct StoreBackupTests {
    @Test func backupsDirectoryIsADedicatedSubfolderOfDataDirectory() {
        let dataDirectory = URL(fileURLWithPath: "/tmp/some-data-dir")

        let result = StoreBackup.backupsDirectory(dataDirectory: dataDirectory)

        #expect(result == dataDirectory.appendingPathComponent("overture-store-backups", isDirectory: true))
    }

    // Isolated real-filesystem sandbox per test, cleaned up after: this is genuine file I/O
    // (FileManager.copyItem), not something worth mocking away, mirroring the temp-directory
    // pattern already used for SwiftData's file-backed store tests elsewhere in this suite.
    private func makeSandboxDataDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-storebackup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - backup.log is bounded (#608)
    //
    // The log gains one line per launch and nothing ever trimmed it, so on an app that is opened
    // every day it grew without limit forever. Tiny in practice (a few dozen bytes a launch), which
    // is exactly why it would never have been noticed until it was large. It now rotates through the
    // SAME copytruncate helper the main app log uses (LogRotation), rather than a second copy of that
    // logic living here.

    private func backupLogURL(_ dataDirectory: URL) -> URL {
        StoreBackup.backupsDirectory(dataDirectory: dataDirectory)
            .appendingPathComponent("backup.log")
    }

    private func seedStore(_ dataDirectory: URL) throws {
        try Data("store".utf8).write(to: dataDirectory.appendingPathComponent("Overture.store"))
    }

    @Test func anOversizeBackupLogIsRotatedAndTheLiveFileStaysBounded() throws {
        let dataDirectory = try makeSandboxDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        try seedStore(dataDirectory)

        // A log left oversize by earlier launches.
        let backupsDirectory = StoreBackup.backupsDirectory(dataDirectory: dataDirectory)
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        let log = backupLogURL(dataDirectory)
        try Data(String(repeating: "x", count: StoreBackup.maxLogBytes + 1).utf8).write(to: log)

        _ = StoreBackup.makeBackup(dataDirectory: dataDirectory, now: Date())

        // The old content is preserved in the .1 backup, and the live file restarted from empty and
        // now holds only this launch's line.
        let rotated = log.appendingPathExtension("1")
        #expect(FileManager.default.fileExists(atPath: rotated.path))
        let live = try String(contentsOf: log, encoding: .utf8)
        #expect(live.contains("success"))
        #expect(live.count < StoreBackup.maxLogBytes)
    }

    @Test func aBackupLogUnderTheCapIsNotRotated() throws {
        let dataDirectory = try makeSandboxDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        try seedStore(dataDirectory)

        _ = StoreBackup.makeBackup(dataDirectory: dataDirectory, now: Date())
        _ = StoreBackup.makeBackup(dataDirectory: dataDirectory, now: Date().addingTimeInterval(60))

        #expect(!FileManager.default.fileExists(atPath: backupLogURL(dataDirectory).appendingPathExtension("1").path))
        // Both launches are still recorded: rotation must not cost history it didn't need to.
        let live = try String(contentsOf: backupLogURL(dataDirectory), encoding: .utf8)
        #expect(live.split(separator: "\n").count == 2)
    }

    // The failure path: capping a log that does not exist yet (the very first launch) must be a
    // silent no-op, not a crash and not a stray empty .1 file.
    @Test func cappingAMissingBackupLogIsAHarmlessNoOp() throws {
        let dataDirectory = try makeSandboxDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        try seedStore(dataDirectory)

        _ = StoreBackup.makeBackup(dataDirectory: dataDirectory, now: Date())

        #expect(FileManager.default.fileExists(atPath: backupLogURL(dataDirectory).path))
        #expect(!FileManager.default.fileExists(atPath: backupLogURL(dataDirectory).appendingPathExtension("1").path))
    }

    @Test func makeBackupReturnsNilWhenThereIsNoStoreYet() throws {
        let dataDirectory = try makeSandboxDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }

        let result = StoreBackup.makeBackup(dataDirectory: dataDirectory, now: Date())

        #expect(result == nil)
    }

    @Test func makeBackupCopiesTheStoreAndItsSidecarsIntoADatedFolder() throws {
        let dataDirectory = try makeSandboxDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        try "store-bytes".write(to: dataDirectory.appendingPathComponent("Overture.store"),
                                atomically: true, encoding: .utf8)
        try "wal-bytes".write(to: dataDirectory.appendingPathComponent("Overture.store-wal"),
                              atomically: true, encoding: .utf8)
        // No -shm file this time: a real store doesn't always have one (e.g. after a clean
        // checkpoint), so the copy must not require it.
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let result = try #require(StoreBackup.makeBackup(dataDirectory: dataDirectory, now: now))

        #expect(FileManager.default.fileExists(atPath: result.appendingPathComponent("Overture.store").path))
        #expect(try String(contentsOf: result.appendingPathComponent("Overture.store"), encoding: .utf8)
                == "store-bytes")
        #expect(try String(contentsOf: result.appendingPathComponent("Overture.store-wal"), encoding: .utf8)
                == "wal-bytes")
        #expect(!FileManager.default.fileExists(atPath: result.appendingPathComponent("Overture.store-shm").path))
        #expect(result.deletingLastPathComponent()
                == StoreBackup.backupsDirectory(dataDirectory: dataDirectory))
    }

    // #601 red-team finding: the app itself anticipates rapid automatic crash-relaunch loops, so
    // two backups requested in the same second (same dated folder name) is a real case, not a
    // hypothetical. It must be treated as "already backed up this instant", not an error.
    @Test func makeBackupTreatsASameSecondCollisionAsAlreadyDone() throws {
        let dataDirectory = try makeSandboxDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        try "first-version".write(to: dataDirectory.appendingPathComponent("Overture.store"),
                                  atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try #require(StoreBackup.makeBackup(dataDirectory: dataDirectory, now: now))
        // The live store changes between the two calls (simulating a second launch moments
        // later); the second call must NOT overwrite the first snapshot it already took.
        try "second-version".write(to: dataDirectory.appendingPathComponent("Overture.store"),
                                   atomically: true, encoding: .utf8)

        let second = StoreBackup.makeBackup(dataDirectory: dataDirectory, now: now)

        #expect(second == first)
        #expect(try String(contentsOf: first.appendingPathComponent("Overture.store"), encoding: .utf8)
                == "first-version")
    }

    // There is no existing app-wide event log to hook into (AgentLogLocation only manages the
    // process's own launchd stdout/stderr redirection); a backup attempt's outcome needs its own
    // record, or a silently-failing backup is invisible until the day it's actually needed.
    @Test func makeBackupAppendsASuccessLineToItsOwnLog() throws {
        let dataDirectory = try makeSandboxDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        try "store-bytes".write(to: dataDirectory.appendingPathComponent("Overture.store"),
                                atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        _ = StoreBackup.makeBackup(dataDirectory: dataDirectory, now: now)

        let log = try String(contentsOf: StoreBackup.backupsDirectory(dataDirectory: dataDirectory)
            .appendingPathComponent("backup.log"), encoding: .utf8)
        #expect(log.contains("20231114-171320"))
        #expect(log.contains("success"))
    }

    private func makeDatedBackupFolders(_ names: [String], in backupsDirectory: URL) throws {
        try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.createDirectory(at: backupsDirectory.appendingPathComponent(name),
                                                     withIntermediateDirectories: true)
        }
    }

    @Test func pruneOldBackupsDeletesAllButTheNewestKept() throws {
        let dataDirectory = try makeSandboxDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let backupsDirectory = StoreBackup.backupsDirectory(dataDirectory: dataDirectory)
        // Names sort chronologically as strings (yyyyMMdd-HHmmss), same as the real folders.
        try makeDatedBackupFolders(["20260101-090000", "20260102-090000", "20260103-090000"],
                                   in: backupsDirectory)

        StoreBackup.pruneOldBackups(in: backupsDirectory, keep: 2)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path).sorted()
        #expect(remaining == ["20260102-090000", "20260103-090000"])
    }

    @Test func pruneOldBackupsIsANoOpWhenAtOrUnderTheLimit() throws {
        let dataDirectory = try makeSandboxDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        let backupsDirectory = StoreBackup.backupsDirectory(dataDirectory: dataDirectory)
        try makeDatedBackupFolders(["20260101-090000", "20260102-090000"], in: backupsDirectory)

        StoreBackup.pruneOldBackups(in: backupsDirectory, keep: 2)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path).sorted()
        #expect(remaining == ["20260101-090000", "20260102-090000"])
    }

    // #602: the launch-time policy. Generic over whatever "open the store" returns, so the
    // sequencing/conditional-prune decision is testable without touching a real ModelContainer.
    @Test func performLaunchBackupPrunesOldBackupsWhenOpenSucceeds() throws {
        let dataDirectory = try makeSandboxDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        try "store-bytes".write(to: dataDirectory.appendingPathComponent("Overture.store"),
                                atomically: true, encoding: .utf8)
        try makeDatedBackupFolders(["20200101-090000", "20200102-090000"],
                                   in: StoreBackup.backupsDirectory(dataDirectory: dataDirectory))
        let now = Date(timeIntervalSince1970: 1_700_000_000)  // "20231114-171320", after both of the above

        let result = StoreBackup.performLaunchBackup(dataDirectory: dataDirectory, now: now, keep: 1) {
            "opened"
        }

        #expect(result == "opened")
        let remaining = try FileManager.default
            .contentsOfDirectory(atPath: StoreBackup.backupsDirectory(dataDirectory: dataDirectory).path)
            .filter { $0 != "backup.log" }
        #expect(remaining == ["20231114-171320"])
    }

    // #602 red-team fix: an undetected corrupted store must never cause its own last-good
    // backups to be pruned away just because this launch's open attempt failed.
    @Test func performLaunchBackupSkipsPruningWhenOpenFails() throws {
        let dataDirectory = try makeSandboxDataDirectory()
        defer { try? FileManager.default.removeItem(at: dataDirectory) }
        try "store-bytes".write(to: dataDirectory.appendingPathComponent("Overture.store"),
                                atomically: true, encoding: .utf8)
        try makeDatedBackupFolders(["20260101-090000", "20260102-090000"],
                                   in: StoreBackup.backupsDirectory(dataDirectory: dataDirectory))
        let now = Date(timeIntervalSince1970: 1_700_000_000)  // "20231114-171320"

        let result = StoreBackup.performLaunchBackup(dataDirectory: dataDirectory, now: now, keep: 1) {
            () -> String? in nil
        }

        #expect(result == nil)
        // The new backup still happened (a failed open doesn't mean don't-back-up-what's-there),
        // but nothing got pruned: both old folders plus the new one are all still present.
        let remaining = try FileManager.default
            .contentsOfDirectory(atPath: StoreBackup.backupsDirectory(dataDirectory: dataDirectory).path)
            .filter { $0 != "backup.log" }.sorted()
        #expect(remaining == ["20231114-171320", "20260101-090000", "20260102-090000"])
    }
}
