import Foundation
import SQLite3

// #2054: how many rows in one table carry a non-null value in one column, read from a store's own SQLite
// WITHOUT going through SwiftData.
//
// Going around SwiftData is the whole point. The joint-send rehearsal needs to know what a store held
// BEFORE a ModelContainer opened it, because the failure it guards (a migration handing every existing row
// a value nobody chose) happens during that open. Anything measured after it is measured through the very
// step under test.
//
// Read-only and non-creating, on StoreSchemaGuard's precedent (#663): a check must never be the thing that
// brings a store into existence or writes to one. Returns nil, never zero, for anything it could not
// actually count, because zero is what a clean store looks like and would let a rehearsal pass while
// measuring nothing (L11).
enum StoreColumnCensus {
    static func nonNullCount(table: String, column: String, inSQLiteFileAt path: String) -> Int? {
        // Table and column names cannot be bound as statement parameters, so they are interpolated. They
        // are only ever Overture's own constants today, but the check keeps that true.
        guard isPlainIdentifier(table), isPlainIdentifier(column) else { return nil }
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        // The column has to be confirmed to exist before it can be counted, and NOT by letting the count
        // query fail: SQLite resolves a double-quoted name that matches no column as a STRING LITERAL
        // instead of erroring, so `WHERE "ZRENAMEDAWAY" IS NOT NULL` is true of every row and a renamed
        // column would report a full house rather than "could not count". A missing table makes this
        // return no rows at all, so both cases come back as nil.
        guard columnExists(column, in: table, db: db) else { return nil }

        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM \"\(table)\" WHERE \"\(column)\" IS NOT NULL;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func columnExists(_ column: String, in table: String, db: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return false
        }
        defer { sqlite3_finalize(statement) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, table, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, column, -1, sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int64(statement, 0) > 0
    }

    private static func isPlainIdentifier(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
