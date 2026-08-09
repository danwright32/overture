import Testing
import Foundation
import SwiftData
import SQLite3

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

    // #1734: the container is HELD across the read, rather than discarded with `_ =`.
    //
    // Discarded, its lifetime past that statement was whatever ARC decided, so the store could be torn
    // down at an unpredictable moment relative to the read below. That is the one genuinely
    // nondeterministic thing in this test, and this test failed once during #1721 with SwiftData "fatal
    // logic error in DefaultStore" noise in the same log.
    //
    // Reproducing it in isolation did not work (150 consecutive rounds all passed on 2026-08-08, with the
    // WAL already checkpointed and the schema in the main file), so this removes the nondeterminism rather
    // than claiming to have caught the flake in the act. The finding that IS proven sits in the guard:
    // a file it cannot read was reported as a file belonging to another app.
    @Test func trueForARealOvertureShapedStore() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try makeSandboxDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let storeURL = dir.appendingPathComponent("default.store")
            let schema = Schema([Prospect.self, Recipient.self])
            let container = try ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, url: storeURL, cloudKitDatabase: .none)])

            withExtendedLifetime(container) {
                #expect(StoreSchemaGuard.hasExpectedSchema(at: storeURL))
                #expect(StoreSchemaGuard.identity(of: storeURL) == .overtures)
            }
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // #1734: the three answers that used to be one `false`, each named.
    //
    // "This is another app's database" and "I could not open this file at all" have different
    // consequences: the first is evidence worth keeping under a label meaning never restore from this,
    // and the second may be Dan's own store having a bad day. The app said the first while having
    // measured only the second.
    @Test func anUnreadableStoreIsNotAccusedOfBelongingToAnotherApp() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try makeSandboxDirectory()
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
                try? FileManager.default.removeItem(at: dir)
            }
            let storeURL = dir.appendingPathComponent("default.store")
            // Built with sqlite3 directly rather than a ModelContainer, so nothing in this test holds the
            // file open. A live container was enough to let the read below succeed through permissions
            // that should have refused it, which would make this test pass while proving nothing.
            var db: OpaquePointer?
            #expect(sqlite3_open(storeURL.path, &db) == SQLITE_OK)
            #expect(sqlite3_exec(db, "CREATE TABLE ZPROSPECT (Z_PK INTEGER PRIMARY KEY);",
                                 nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)
            #expect(StoreSchemaGuard.identity(of: storeURL) == .overtures,
                    "the file must read as Overture's own before it is made unreadable")

            // The same file, Overture's own, that cannot be opened.
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: storeURL.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: storeURL.path)
            }

            let identity = StoreSchemaGuard.identity(of: storeURL)
            guard case .unreadable = identity else {
                Issue.record("an unreadable Overture store reported \(identity), not unreadable")
                await RealStoreTestLock.shared.release()
                return
            }

            // Still refused: a guard protecting Dan's data fails closed whatever it could not read.
            #expect(!StoreSchemaGuard.hasExpectedSchema(at: storeURL))

            let reason = StoreSchemaGuard.refusalReason(storeURL: storeURL, dataDirectory: dir, now: Date())
            #expect(reason == StoreSchemaGuard.unreadableFileReason(path: storeURL.path))
            #expect(reason != StoreSchemaGuard.foreignFileReason(path: storeURL.path),
                    "an unreadable file must not be reported as another app's")
            await RealStoreTestLock.shared.release()
        } catch {
            await RealStoreTestLock.shared.release()
            throw error
        }
    }

    // The 2026-07-23 incident's shape: a real, readable CoreData database that is somebody else's. This
    // is the ONLY answer that means a foreign file, and it keeps its evidence snapshot.
    @Test func aReadableDatabaseWithoutOvertuesTableIsStillCalledForeign() async throws {
        await RealStoreTestLock.shared.acquire()
        do {
            let dir = try makeSandboxDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let storeURL = dir.appendingPathComponent("default.store")
            var db: OpaquePointer?
            #expect(sqlite3_open(storeURL.path, &db) == SQLITE_OK)
            #expect(sqlite3_exec(db, "CREATE TABLE ZAPIREQUESTMODEL (Z_PK INTEGER PRIMARY KEY);",
                                 nil, nil, nil) == SQLITE_OK)
            sqlite3_close(db)

            #expect(StoreSchemaGuard.identity(of: storeURL) == .notOvertures)
            let reason = StoreSchemaGuard.refusalReason(storeURL: storeURL, dataDirectory: dir, now: Date())
            #expect(reason == StoreSchemaGuard.foreignFileReason(path: storeURL.path))
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
            // #1734: a file that is not a database at all was READ, and what it is was established. That
            // is a finding about the file, not a failure to look, so it keeps the evidence snapshot the
            // 2026-07-08 and 2026-07-23 collisions are the reason for.
            #expect(StoreSchemaGuard.identity(of: storeURL) == .notOvertures)
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
            // #1410: the snapshot lands in a MARKED folder. It is a copy of a file that was not
            // Overture's, and under a plain dated name it read as the most recent good backup.
            let backedUpStore = backupsDirectory
                .appendingPathComponent("20231114-171320.foreign/\(StoreLocation.storeFilename)")
            #expect(FileManager.default.fileExists(atPath: backedUpStore.path))
            #expect(!FileManager.default.fileExists(
                atPath: backupsDirectory.appendingPathComponent("20231114-171320").path))
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
