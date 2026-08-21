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
// brings a store into existence or writes to one.
//
// #2930: it answers a READING, never an optional count. Six different refusals used to be one nil, so
// "no row carries a value" and "this could not be read at all" were the same answer to every caller, and
// zero is what a clean store looks like: a rehearsal could pass while measuring nothing (L11, L90). Worse,
// the condition that produced the refusal was the busy machine, which is exactly when the count matters:
// measured twice, 2026-08-17 and 2026-08-20, one full-suite run each, passing on a scoped re-run both
// times. Every refusal now names itself, and the two that come from SQLite carry SQLite's own code and
// message, so the next occurrence is evidence rather than an absence.
enum StoreColumnCensus {
    /// What one census answered.
    enum Reading: Equatable {
        case rows(Int)
        case unreadable(Unreadable)
    }

    /// Why a census could not be taken. Distinct causes, distinct cases (L11): each one is a different
    /// problem with a different fix, and collapsing any two of them is what #2930 was.
    enum Unreadable: Equatable {
        /// A table or column name that is not a plain identifier, refused before anything is opened.
        case notAPlainIdentifier(String)
        case noFileAtPath(String)
        /// SQLite would not open the file. The common cause here is a WAL-mode database with no `-shm`
        /// beside it: a read-only connection is not allowed to create the shared-memory file it needs,
        /// and that state exists on disk for a moment every time a writer closes.
        case couldNotOpen(SQLiteFailure)
        /// The schema itself could not be read. Kept apart from the two cases below on purpose: a query
        /// that FAILED is not evidence that a table or column is absent, and reporting it as absence is
        /// the same defect at one remove. A WAL-mode store missing its `-shm` opens fine and then fails
        /// here with a disk I/O error, which is how this was found (#2930).
        case couldNotReadTheSchema(SQLiteFailure)
        case tableNotInStore(table: String)
        case columnNotInTable(column: String, table: String)
        /// The count query itself faulted, at prepare or at step. ONE case rather than one per call:
        /// both mean the same thing to a caller (the number is not known), and SQLite's own code, which
        /// is carried here, is what separates a lock from an I/O fault from a malformed statement.
        case couldNotRunTheCount(SQLiteFailure)

        /// SQLite's own answer, where there was one. The refusals this reader DECIDED (a name that is
        /// not an identifier, a file that is not there, a column the schema really does not carry) have
        /// none, and that difference is the point: one is a fact about the store, the other is a fault.
        var sqliteFailure: SQLiteFailure? {
            switch self {
            case .couldNotOpen(let failure), .couldNotReadTheSchema(let failure),
                 .couldNotRunTheCount(let failure):
                return failure
            case .notAPlainIdentifier, .noFileAtPath, .tableNotInStore, .columnNotInTable:
                return nil
            }
        }
    }

    /// SQLite's own answer, kept whole. A code with no message says as little as the nil did.
    struct SQLiteFailure: Error, Equatable, CustomStringConvertible {
        let code: Int32
        let message: String

        var description: String { "SQLite \(code): \(message)" }
    }

    static func nonNullRows(table: String, column: String, inSQLiteFileAt path: String) -> Reading {
        // Table and column names cannot be bound as statement parameters, so they are interpolated. They
        // are only ever Overture's own constants today, but the check keeps that true.
        guard isPlainIdentifier(table) else { return .unreadable(.notAPlainIdentifier(table)) }
        guard isPlainIdentifier(column) else { return .unreadable(.notAPlainIdentifier(column)) }
        guard FileManager.default.fileExists(atPath: path) else { return .unreadable(.noFileAtPath(path)) }

        var db: OpaquePointer?
        let opened = sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil)
        guard opened == SQLITE_OK, let db else {
            let failure = SQLiteFailure(code: opened, message: errorMessage(db, fallbackCode: opened))
            sqlite3_close(db)
            return .unreadable(.couldNotOpen(failure))
        }
        defer { sqlite3_close(db) }

        // Deliberately NO busy timeout. A lock (SQLITE_BUSY) is a plausible thing for a read of a store
        // somebody is writing to meet, but it is not what was measured: the failure behind #2930 is a
        // disk I/O FAULT, which no amount of waiting clears. A timeout added on the strength of the
        // reasoning alone would be an untested line that reads as protection (L188), and it is not needed
        // to find out: a lock now comes back as couldNotRunTheCount carrying SQLITE_BUSY by name, which
        // is the evidence that would justify adding one.

        // The column has to be confirmed to exist before it can be counted, and NOT by letting the count
        // query fail: SQLite resolves a double-quoted name that matches no column as a STRING LITERAL
        // instead of erroring, so `WHERE "ZRENAMEDAWAY" IS NOT NULL` is true of every row and a renamed
        // column would report a full house rather than "could not count".
        //
        // The table is asked about separately from the column, because a store with no ZPROSPECT at all is
        // a different thing from Overture's store missing one attribute, and the pragma answers no rows to
        // both (L11).
        switch countOfRows("SELECT COUNT(*) FROM pragma_table_info(?);", binding: [table], db: db) {
        case .failure(let failure): return .unreadable(.couldNotReadTheSchema(failure))
        case .success(0): return .unreadable(.tableNotInStore(table: table))
        case .success: break
        }
        switch countOfRows("SELECT COUNT(*) FROM pragma_table_info(?) WHERE name = ?;",
                           binding: [table, column], db: db) {
        case .failure(let failure): return .unreadable(.couldNotReadTheSchema(failure))
        case .success(0): return .unreadable(.columnNotInTable(column: column, table: table))
        case .success: break
        }

        var statement: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM \"\(table)\" WHERE \"\(column)\" IS NOT NULL;"
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            return .unreadable(.couldNotRunTheCount(
                SQLiteFailure(code: prepared, message: errorMessage(db, fallbackCode: prepared))))
        }
        defer { sqlite3_finalize(statement) }

        let stepped = sqlite3_step(statement)
        guard stepped == SQLITE_ROW else {
            return .unreadable(.couldNotRunTheCount(
                SQLiteFailure(code: stepped, message: errorMessage(db, fallbackCode: stepped))))
        }
        return .rows(Int(sqlite3_column_int64(statement, 0)))
    }

    /// SQLite's message for the last failure on this connection, or the code's own name when there is no
    /// connection to ask (a failed open can leave nothing to read it from).
    private static func errorMessage(_ db: OpaquePointer?, fallbackCode: Int32) -> String {
        if let db, let raw = sqlite3_errmsg(db) {
            let message = String(cString: raw)
            if !message.isEmpty, message != "not an error" { return message }
        }
        if let raw = sqlite3_errstr(fallbackCode) { return String(cString: raw) }
        return "sqlite error \(fallbackCode)"
    }

    /// The single number a COUNT query answers, or SQLite's refusal to answer it.
    ///
    /// It returns the failure rather than a zero, which is the whole of #2930 at the level below: a
    /// helper that answers 0 for "the query failed" hands its caller a definite fact ("no such column")
    /// built out of not knowing.
    private static func countOfRows(_ sql: String, binding values: [String],
                                    db: OpaquePointer) -> Result<Int, SQLiteFailure> {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else {
            return .failure(SQLiteFailure(code: prepared, message: errorMessage(db, fallbackCode: prepared)))
        }
        defer { sqlite3_finalize(statement) }

        let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(i + 1), value, -1, sqliteTransient)
        }

        let stepped = sqlite3_step(statement)
        guard stepped == SQLITE_ROW else {
            return .failure(SQLiteFailure(code: stepped, message: errorMessage(db, fallbackCode: stepped)))
        }
        return .success(Int(sqlite3_column_int64(statement, 0)))
    }

    private static func isPlainIdentifier(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
