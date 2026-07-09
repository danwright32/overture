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
