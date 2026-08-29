import Foundation
import SQLite3

/// Reads a SwiftData store's real SQLite shape, for the rehearsals that have to know what is on disk
/// rather than what the current model declares (#1665).
///
/// A SUBTRACTIVE migration cannot be rehearsed the way the additive ones were. Those built a container
/// from the old model list and one from the new, and compared. Once a property is deleted from the model
/// there is no old list to build: the type simply does not have it any more, and the only place the
/// column still exists is the file. So the before-reading comes from the file itself.
///
/// That is also what makes the rehearsal honest rather than a formality. Opening a clone under the new
/// schema and finding the rows intact proves nothing if the clone never carried the columns being
/// dropped: an empty result and a successful subtraction look identical (L98). So the rehearsal asserts
/// the columns ARE there first, and that they hold nothing, before it drops them.
///
/// Read-only, with no implicit creation, on the same terms as `StoreSchemaGuard`: a rehearsal must not be
/// able to create or alter the file it is reading, and it is pointed at a CLONE in any case.
enum StoreColumns {

    /// The columns of a table, as SQLite itself reports them, or nil when the file could not be read.
    static func columns(ofTable table: String, in storeURL: URL) -> [String]? {
        query("SELECT name FROM pragma_table_info(?);", bind: table, in: storeURL) { statement in
            String(cString: sqlite3_column_text(statement, 0))
        }
    }

    /// How many rows a table holds, or nil when the file could not be read.
    static func rowCount(ofTable table: String, in storeURL: URL) -> Int? {
        // The table name is interpolated because SQLite does not bind identifiers, and it is never
        // caller-supplied text: every call site names a constant. Guarded anyway, so a future one cannot
        // make this the place a name reaches the parser.
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return query("SELECT COUNT(*) FROM \(table);", bind: nil, in: storeURL) { statement in
            String(sqlite3_column_int64(statement, 0))
        }?.first.flatMap(Int.init)
    }

    /// How many rows hold something OTHER than the column's declared default: the number that decides
    /// whether dropping it destroys anything. nil when the file or the column could not be read, which is
    /// NOT zero and must never be read as one.
    ///
    /// The default has to be passed in, and asking for "not null" instead is the mistake this signature
    /// exists to prevent. Measured 2026-08-27 on the live store: `ZCLASSIFICATIONCONFIDENCE` and
    /// `ZCONFIDENCEREVIEWEDBYDAN` are non-null on all 1018 prospect rows, because a Swift property with a
    /// default is written to every row whether anybody set it or not. Read as "not null" that reports
    /// 1018 rows of data about to be destroyed, when the truth is 1018 copies of a value nothing ever
    /// wrote. A column with no default at all (`websiteURL`, an optional) is asked with `default: nil`,
    /// and then any non-null really is somebody's data.
    static func rowsHoldingSomethingOtherThan(_ defaultValue: String?, inColumn column: String,
                                              ofTable table: String, in storeURL: URL) -> Int? {
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              column.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        guard columns(ofTable: table, in: storeURL)?.contains(column) == true else { return nil }
        // `<> ?` is false for a NULL on either side, so the null case is spelled out rather than left to
        // three-valued logic: a null row holds nothing, which is not "something other than the default".
        let sql = defaultValue == nil
            ? "SELECT COUNT(*) FROM \(table) WHERE \(column) IS NOT NULL;"
            : "SELECT COUNT(*) FROM \(table) WHERE \(column) IS NOT NULL AND \(column) <> ?;"
        return query(sql, bind: defaultValue, in: storeURL) { statement in
            String(sqlite3_column_int64(statement, 0))
        }?.first.flatMap(Int.init)
    }

    /// The distinct values a column holds, each with how many rows hold it, commonest first. nil when the
    /// file or the column could not be read.
    ///
    /// A count of rows that are not the default says a migration would destroy something; this says WHAT,
    /// which is the difference between a number somebody has to go and investigate and one they can act
    /// on. Values only, so it is safe to print: a column of classification labels is not personal data,
    /// and no call site here reads a column that holds any (L222).
    static func valueCounts(inColumn column: String, ofTable table: String, in storeURL: URL) -> [String]? {
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              column.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        guard columns(ofTable: table, in: storeURL)?.contains(column) == true else { return nil }
        return query("""
            SELECT COALESCE(CAST(\(column) AS TEXT), 'NULL') || ': ' || COUNT(*)
            FROM \(table) GROUP BY \(column) ORDER BY COUNT(*) DESC;
            """, bind: nil, in: storeURL) { statement in
            String(cString: sqlite3_column_text(statement, 0))
        }
    }

    // copy-inventory:ignore-start  sqlite's own reads, never a sentence Overture says to Dan
    private static func query(_ sql: String, bind: String?, in storeURL: URL,
                              read: (OpaquePointer) -> String) -> [String]? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(storeURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        if let bind {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, bind, -1, transient)
        }

        var rows: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(read(statement))
        }
        return rows
    }
    // copy-inventory:ignore-end
}
