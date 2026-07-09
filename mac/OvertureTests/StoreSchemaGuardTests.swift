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

    @Test func trueWhenNoFileExistsYet() throws {
        let dir = try makeSandboxDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("default.store")

        #expect(StoreSchemaGuard.hasExpectedSchema(at: storeURL))
    }

    @Test func trueForARealOvertureShapedStore() throws {
        let dir = try makeSandboxDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("default.store")
        let schema = Schema([Prospect.self, Recipient.self])
        _ = try ModelContainer(for: schema,
                               configurations: [ModelConfiguration(schema: schema, url: storeURL,
                                                                   cloudKitDatabase: .none)])

        #expect(StoreSchemaGuard.hasExpectedSchema(at: storeURL))
    }

    // Simulates the actual incident: a foreign app's SwiftData/CoreData store (some other entity,
    // never Overture's ZPROSPECT) sitting at the shared path.
    @Test func falseForAForeignSQLiteFileWithoutOvertuesTable() throws {
        let dir = try makeSandboxDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("default.store")
        var db: OpaquePointer?
        #expect(sqlite3_open(storeURL.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE ZCLIENT (Z_PK INTEGER PRIMARY KEY);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)

        #expect(!StoreSchemaGuard.hasExpectedSchema(at: storeURL))
    }

    @Test func falseForANonSQLiteFile() throws {
        let dir = try makeSandboxDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let storeURL = dir.appendingPathComponent("default.store")
        try "not a sqlite file".write(to: storeURL, atomically: true, encoding: .utf8)

        #expect(!StoreSchemaGuard.hasExpectedSchema(at: storeURL))
    }
}
