import Testing
import Foundation
import SwiftData
import SQLite3
@testable import Overture

// #663: caught by the Downbeat store-path collision incident (2026-07-08). A different app's
// SwiftData store landing at Overture's exact path doesn't make ModelContainer throw. CoreData
// just creates Overture's missing tables fresh inside the existing file and opens "successfully"
// as if it were a normal empty store, silently discarding the fact the file was never Overture's.
// This suite covers the pure, read-only check that runs BEFORE ModelContainer ever touches the
// file, so that silent fresh-table creation never gets the chance to happen.
@Suite("Store schema guard (#663)")
struct StoreSchemaGuardTests {
    private func makeSandboxDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-schemaguard-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // #1006: every test below builds a real, disk-backed file (ModelContainer or raw sqlite3), so
    // each runs between an acquire()/release() pair and never overlaps another suite's, in the
    // whole process.

    @Test func trueWhenNoFileExistsYet() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try makeSandboxDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let storeURL = dir.appendingPathComponent("default.store")

            #expect(StoreSchemaGuard.hasExpectedSchema(at: storeURL))
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    @Test func trueForARealOvertureShapedStore() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try makeSandboxDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let storeURL = dir.appendingPathComponent("default.store")
            let schema = Schema([Prospect.self, Recipient.self])
            _ = try ModelContainer(for: schema,
                                   configurations: [ModelConfiguration(schema: schema, url: storeURL,
                                                                       cloudKitDatabase: .none)])

            #expect(StoreSchemaGuard.hasExpectedSchema(at: storeURL))
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // Simulates the actual incident: a foreign app's SwiftData/CoreData store (some other entity,
    // never Overture's ZPROSPECT) sitting at the shared path.
    @Test func falseForAForeignSQLiteFileWithoutOvertuesTable() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try makeSandboxDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let storeURL = dir.appendingPathComponent("default.store")
            var db: OpaquePointer?
            #expect(sqlite3_open(storeURL.path, &db) == SQLITE_OK)
            #expect(sqlite3_exec(db, "CREATE TABLE ZCLIENT (Z_PK INTEGER PRIMARY KEY);", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)

            #expect(!StoreSchemaGuard.hasExpectedSchema(at: storeURL))
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    @Test func falseForANonSQLiteFile() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try makeSandboxDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let storeURL = dir.appendingPathComponent("default.store")
            try "not a sqlite file".write(to: storeURL, atomically: true, encoding: .utf8)

            #expect(!StoreSchemaGuard.hasExpectedSchema(at: storeURL))
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // #663 follow-up: OvertureApp.init() can never be unit-tested directly (the test host always
    // takes the isRunningUnderTests branch, so this decision never runs under XCTest), so the
    // refusal-with-backup decision is extracted into this pure function instead, mirroring how
    // StoreBackup.performLaunchBackup was already extracted for the same reason.
    @Test func refusalReasonIsNilWhenNoFileExistsYet() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try makeSandboxDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let storeURL = dir.appendingPathComponent("default.store")

            let reason = StoreSchemaGuard.refusalReason(storeURL: storeURL, dataDirectory: dir, now: Date())

            #expect(reason == nil)
            #expect(!FileManager.default.fileExists(atPath: StoreBackup.backupsDirectory(dataDirectory: dir).path))
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    @Test func refusalReasonIsNilForARealOvertureShapedStore() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try makeSandboxDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let storeURL = dir.appendingPathComponent("default.store")
            let schema = Schema([Prospect.self, Recipient.self])
            _ = try ModelContainer(for: schema,
                                   configurations: [ModelConfiguration(schema: schema, url: storeURL,
                                                                       cloudKitDatabase: .none)])

            let reason = StoreSchemaGuard.refusalReason(storeURL: storeURL, dataDirectory: dir, now: Date())

            #expect(reason == nil)
            // This function owns only the refusal path; a matching schema is backed up elsewhere
            // (OvertureApp's own launch-backup call), not by this function.
            #expect(!FileManager.default.fileExists(atPath: StoreBackup.backupsDirectory(dataDirectory: dir).path))
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    @Test func refusalReasonBacksUpAForeignFileAndNamesItsPathInTheReason() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try makeSandboxDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let storeURL = dir.appendingPathComponent(StoreLocation.storeFilename)
            var db: OpaquePointer?
            #expect(sqlite3_open(storeURL.path, &db) == SQLITE_OK)
            #expect(sqlite3_exec(db, "CREATE TABLE ZCLIENT (Z_PK INTEGER PRIMARY KEY);", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)
            let now = Date(timeIntervalSince1970: 1_700_000_000)

            let reason = try #require(StoreSchemaGuard.refusalReason(storeURL: storeURL, dataDirectory: dir, now: now))

            #expect(reason.contains(storeURL.path))
            let backupsDirectory = StoreBackup.backupsDirectory(dataDirectory: dir)
            let backedUpStore = backupsDirectory
                .appendingPathComponent("20231114-171320/\(StoreLocation.storeFilename)")
            #expect(FileManager.default.fileExists(atPath: backedUpStore.path))
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // #602 red-team behavior must hold here too: a refusal is not a success, so it must never
    // cause older, still-good backups to be rotated away.
    @Test func refusalReasonNeverPrunesOldBackups() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try makeSandboxDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let storeURL = dir.appendingPathComponent("default.store")
            var db: OpaquePointer?
            #expect(sqlite3_open(storeURL.path, &db) == SQLITE_OK)
            #expect(sqlite3_exec(db, "CREATE TABLE ZCLIENT (Z_PK INTEGER PRIMARY KEY);", nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)
            let backupsDirectory = StoreBackup.backupsDirectory(dataDirectory: dir)
            try FileManager.default.createDirectory(at: backupsDirectory.appendingPathComponent("20200101-090000"),
                                                     withIntermediateDirectories: true)
            let now = Date(timeIntervalSince1970: 1_700_000_000)   // sorts after 20200101-090000

            _ = StoreSchemaGuard.refusalReason(storeURL: storeURL, dataDirectory: dir, now: now)

            let remaining = try FileManager.default.contentsOfDirectory(atPath: backupsDirectory.path)
            #expect(remaining.contains("20200101-090000"))
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }
}
