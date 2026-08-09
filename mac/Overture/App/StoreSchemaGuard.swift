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

    // #1734: what the file at the store path actually IS, as four answers rather than a yes/no.
    //
    // Three of these used to be one `false`. "This is another app's database" and "I could not open this
    // file at all" are different findings with different consequences, and collapsing them meant the app
    // told Dan the first while having measured only the second (L11). Proven on 2026-08-08: an Overture
    // store made unreadable reported exactly the sentence about another app having written to it, and the
    // refusal then snapshotted Dan's own data into a folder labelled `.foreign`, which AGENTS.md defines
    // as a copy that must never be restored from.
    //
    // It is also the likeliest mechanism behind #1734's flake. A transient failure to open is, to this
    // guard, indistinguishable from a foreign file, and a store the test had just built read as foreign
    // once with SwiftData "fatal logic error" noise in the same log.
    enum Identity: Equatable {
        case absent                     // nothing at the path yet, which is a legitimate fresh install
        case overtures                  // Overture's own table is there
        case notOvertures               // opened and queried fine, and Overture's table is not in it
        case unreadable(detail: String) // could not be opened or queried at all, so whose it is is unknown
    }

    static func identity(of storeURL: URL, fileManager: FileManager = .default) -> Identity {
        guard fileManager.fileExists(atPath: storeURL.path) else { return .absent }
        return readIdentity(inSQLiteFileAt: storeURL.path)
    }

    // Pure/testable given a store path: true means safe to proceed (nothing exists yet, or the
    // existing file already has Overture's table); false means refuse to open.
    //
    // #1734 deliberately did NOT change this contract. Every caller that only needs "is it safe to open"
    // still gets one answer, and an unreadable file still counts as not safe: a guard protecting Dan's
    // data fails closed. What changed is only what the app SAYS, not what it is willing to open.
    static func hasExpectedSchema(at storeURL: URL, fileManager: FileManager = .default) -> Bool {
        switch identity(of: storeURL, fileManager: fileManager) {
        case .absent, .overtures: return true
        case .notOvertures, .unreadable: return false
        }
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
        switch identity(of: storeURL, fileManager: fileManager) {
        case .absent, .overtures:
            return nil

        case .notOvertures:
            // #1410: taken as .foreignFile, so the log and the folder name both say this is a copy of a
            // file that was not Overture's rather than a backup of Dan's data, and so it stays out of the
            // rotation it would otherwise count against. Worth keeping precisely BECAUSE it is not his
            // data: it is the evidence of whatever landed at his path.
            _ = StoreBackup.performLaunchBackup(
                dataDirectory: dataDirectory, now: now, keep: 10, reason: .foreignFile,
                fileManager: fileManager
            ) { () -> Bool? in nil }
            return foreignFileReason(path: storeURL.path)

        case .unreadable(let detail):
            // #1734: still snapshotted, because a file at this path that nothing can read is exactly as
            // worth keeping evidence of, but under its OWN label. `.foreign` is a claim, and a file that
            // could not be read may be Dan's own store having a bad day: marking his only copy as one to
            // never restore from is the opposite of what that label is for. sqlite's own words for why go
            // into backup.log, so the refusal can be diagnosed afterwards.
            _ = StoreBackup.performLaunchBackup(
                dataDirectory: dataDirectory, now: now, keep: 10, reason: .unreadableFile(detail: detail),
                fileManager: fileManager
            ) { () -> Bool? in nil }
            return unreadableFileReason(path: storeURL.path)
        }
    }

    // The one sentence for "the file at this path isn't Overture's database". Shared with
    // StoreRelocation, which reaches the same conclusion about the pre-move path, so the two cannot
    // drift into two nearly-identical sentences saying the same thing (#843).
    static func foreignFileReason(path: String) -> String {
        "Overture's data file doesn't look like Overture's own database. Another app may "
            + "have written to \(path). Nothing has been opened or changed. Check that "
            + "file before reopening Overture."
    }

    // The one sentence for "Overture could not READ the file", which is not a claim about whose file it
    // is. It deliberately does not mention another app having written anything, because nothing here
    // measured that (#1734).
    static func unreadableFileReason(path: String) -> String {
        "Overture could not open its data file to check it at \(path). Nothing has been "
            + "opened or changed. The file may be in use by another program, or its permissions may have "
            + "changed. Check that file before reopening Overture."
    }

    // copy-inventory:ignore-start  sqlite's own error text, for backup.log, never shown on screen
    private static func readIdentity(inSQLiteFileAt path: String) -> Identity {
        var db: OpaquePointer?
        // Read-only, no implicit creation: a missing/foreign/corrupt file must never be silently
        // turned into a fresh Overture store by this check itself.
        let openResult = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db else {
            let detail = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed (\(openResult))"
            sqlite3_close(db)
            return .unreadable(detail: detail)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1;"
        // sqlite3_open_v2 is lazy: it does not touch the header until the first statement, so this is
        // where a file that is not a database at all lands.
        //
        // SQLITE_NOTADB is the one error here that is a FINDING rather than a failure. It means the file
        // was read and is not a database, so it is certainly not Overture's store, and it keeps the
        // evidence snapshot. Every other error means the read did not happen, which says nothing about
        // whose file it is.
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            let message = String(cString: sqlite3_errmsg(db))
            return prepared == SQLITE_NOTADB ? .notOvertures : .unreadable(detail: message)
        }
        defer { sqlite3_finalize(statement) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, expectedTable, -1, sqliteTransient)

        switch sqlite3_step(statement) {
        case SQLITE_ROW: return .overtures
        // The query ran and found nothing. This is the ONLY answer that means somebody else's file.
        case SQLITE_DONE: return .notOvertures
        default: return .unreadable(detail: String(cString: sqlite3_errmsg(db)))
        }
    }
    // copy-inventory:ignore-end
}
