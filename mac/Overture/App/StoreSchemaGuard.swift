import Foundation
import SQLite3

// #663: before Overture opens its SwiftData store, confirm the file at that path already looks
// like Overture's own database, or doesn't exist yet (a legitimate fresh install). A different
// app's SwiftData/CoreData store landing at Overture's exact path (the Downbeat store-path
// collision incident, 2026-07-08) doesn't make ModelContainer throw: CoreData just creates
// Overture's missing tables fresh inside the existing file and "successfully" opens it as an
// empty store, silently discarding the fact the file was never Overture's. This is a read-only,
// best-effort check run BEFORE SwiftData ever touches the file, so a foreign file gets caught
// instead of silently turned into a fresh, near-empty store.
enum StoreSchemaGuard {
    // The table SwiftData/CoreData creates for the Prospect entity (Z<ENTITYNAME>, confirmed
    // against Dan's real live store via `sqlite3 .tables`). Any store Overture has ever opened
    // has this table, even when empty; a store some other app owns won't.
    private static let expectedTable = "ZPROSPECT"

    // Pure/testable given a store path: true means safe to proceed (nothing exists yet, or the
    // existing file already has Overture's table); false means refuse to open.
    static func hasExpectedSchema(at storeURL: URL, fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: storeURL.path) else { return true }
        return tableExists(expectedTable, inSQLiteFileAt: storeURL.path)
    }

    // #663 follow-up: OvertureApp.init() can never be unit-tested directly (the test host always
    // takes the isRunningUnderTests branch under XCTest, so this decision never runs there), so
    // the refusal-with-backup decision lives here instead, mirroring how StoreBackup.
    // performLaunchBackup was already extracted out of the same initializer for testability.
    // Returns nil when it's safe to proceed. Returns a reason (after snapshotting the file, the
    // same way #602 always snapshots before opening, but without pruning old backups, matching
    // the existing failed-open behavior since nothing here succeeded either) when it isn't.
    static func refusalReason(
        storeURL: URL, dataDirectory: URL, now: Date, fileManager: FileManager = .default
    ) -> String? {
        guard !hasExpectedSchema(at: storeURL, fileManager: fileManager) else { return nil }
        _ = StoreBackup.performLaunchBackup(
            dataDirectory: dataDirectory, now: now, keep: 10, fileManager: fileManager
        ) { () -> Bool? in nil }
        return foreignFileReason(path: storeURL.path)
    }

    // The one sentence for "the file at this path isn't Overture's database". Shared with
    // StoreRelocation, which reaches the same conclusion about the pre-move path, so the two cannot
    // drift into two nearly-identical sentences saying the same thing (#843).
    static func foreignFileReason(path: String) -> String {
        "Overture's data file doesn't look like Overture's own database. Another app may "
            + "have written to \(path). Nothing has been opened or changed. Check that "
            + "file before reopening Overture."
    }

    private static func tableExists(_ table: String, inSQLiteFileAt path: String) -> Bool {
        var db: OpaquePointer?
        // Read-only, no implicit creation: a missing/foreign/corrupt file must never be silently
        // turned into a fresh Overture store by this check itself.
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return false
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, table, -1, sqliteTransient)

        return sqlite3_step(statement) == SQLITE_ROW
    }
}
