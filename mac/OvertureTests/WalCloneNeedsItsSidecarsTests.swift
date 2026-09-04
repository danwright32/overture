import Testing
import Foundation
import SQLite3

// #3072: the claim `LiveStoreClone` makes for converting its clone to `journal_mode=DELETE`, measured
// against the actual artifact rather than restated.
//
// The comment said a WAL database with no `-shm` beside it cannot be opened READ-ONLY, because a
// read-only connection may not create the shared memory file it would need. The overnight review of
// 2026-08-20 tried the direct version three times, it read fine and returned a count, and the sentence
// was left standing as the kind that gets quoted later as settled fact (L32).
//
// Measured 2026-09-04 through the same call the readers make (`sqlite3_open_v2` with
// `SQLITE_OPEN_READONLY`, which is what `StoreColumnCensus` and `StoreColumns` do) rather than an
// ad-hoc `sqlite3` invocation, since a check written beside the code is a second definition that drifts
// (L107). **The comment is right.** A `.backup` output is in WAL mode, carries no sidecars, and is
// refused read-only; converted to `DELETE` it reads with nothing beside it.
//
// The interesting part is WHY it read fine when somebody tried it, because the first version of this
// test reproduced that result and it was the instrument's own doing. Asking the clone `PRAGMA
// journal_mode` opens it READ-WRITE, which creates the `-shm` and `-wal` the read-only open then finds,
// so a probe that checks the mode before attempting the read has already repaired the condition it is
// about to measure. That is a measurement taken THROUGH the thing being measured (L70), and the only
// reason it surfaced is that the assertions were written before the numbers were believed.
//
// One detail worth having in writing, since it is what a future reader will compare against: the
// refusal code differs by how the sidecars came to be absent. A `.backup` output that never had them is
// `SQLITE_ERROR` (1). A WAL database that had them and had them deleted is `SQLITE_CANTOPEN` (14).
// Both are refusals and neither returns a row, so the tests below assert the refusal rather than one
// code, which would be asserting the rendering of a value rather than the rule (L103).
@Suite("A WAL clone needs its sidecars, and the conversion is what removes the need (#3072)")
struct WalCloneNeedsItsSidecarsTests {
    private func sqlite(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = args
        p.standardError = Pipe(); p.standardOutput = Pipe()
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    private func journalMode(of url: URL) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = [url.path, "PRAGMA journal_mode;"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        try? p.run()
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(data: d, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The readers' own call: `sqlite3_open_v2` with `SQLITE_OPEN_READONLY`, then one real query, since
    /// an open that succeeds and a query that works are different claims.
    private func readOnlyCount(_ url: URL) -> (code: Int32, rows: Int) {
        var db: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { if db != nil { sqlite3_close(db) } }
        guard code == SQLITE_OK, let db else { return (code, -1) }
        var stmt: OpaquePointer?
        defer { if stmt != nil { sqlite3_finalize(stmt) } }
        guard sqlite3_prepare_v2(db, "SELECT count(*) FROM t", -1, &stmt, nil) == SQLITE_OK,
              let stmt, sqlite3_step(stmt) == SQLITE_ROW else { return (SQLITE_ERROR, -1) }
        return (SQLITE_OK, Int(sqlite3_column_int(stmt, 0)))
    }

    private func sandbox() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wal-sidecars-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A WAL source with three rows, and a `.backup` clone of it, built the way `LiveStoreClone` does.
    private func walClone(in dir: URL) -> URL {
        let source = dir.appendingPathComponent("source.store")
        _ = sqlite([source.path,
                    "PRAGMA journal_mode=WAL; CREATE TABLE t(a); INSERT INTO t VALUES (1),(2),(3);"])
        let clone = dir.appendingPathComponent("clone.store")
        _ = sqlite(LiveStoreClone.backupArguments(source: source, clone: clone,
                                                  timeoutMilliseconds: 30_000))
        return clone
    }

    // Read LAST in its own sandbox, because asking is not free: `PRAGMA journal_mode` opens read-write
    // and leaves the sidecars behind, so no other assertion here may follow it on the same file.
    @Test func theBackupPreservesTheSourcesWalMode() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(journalMode(of: walClone(in: dir)) == "wal")
    }

    // The state the comment is actually about, and the one `.backup` really produces.
    @Test func theBackupLeavesNoSidecarsAtAll() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clone = walClone(in: dir)
        #expect(FileManager.default.fileExists(atPath: clone.path))
        for suffix in ["-shm", "-wal"] {
            #expect(!FileManager.default.fileExists(atPath: clone.path + suffix))
        }
    }

    // The fact the comment asserted, against the artifact `.backup` really writes. Both ends are
    // checked in one test, on the SAME clone through the SAME call, because a refusal with nothing to
    // compare it against says nothing about its cause.
    @Test func aWalCloneWithNoSidecarsIsRefusedReadOnlyAndTheConversionIsWhatFixesIt() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clone = walClone(in: dir)

        let asBackupLeftIt = readOnlyCount(clone)
        #expect(asBackupLeftIt.code != SQLITE_OK, "a WAL clone with no -shm must not open read-only")
        #expect(asBackupLeftIt.rows == -1)

        _ = sqlite(LiveStoreClone.selfContainedArguments(clone: clone))
        let converted = readOnlyCount(clone)
        #expect(converted.code == SQLITE_OK)
        #expect(converted.rows == 3)
    }

    // And what the conversion buys beyond readability: a file that stays readable with nothing beside
    // it, which is the "no sidecars" property the code's next paragraph claims. A snapshot missing the
    // files it depends on is worse than one that never needed them.
    @Test func theConvertedCloneStillReadsAfterEverythingBesideItIsRemoved() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clone = walClone(in: dir)
        _ = sqlite(LiveStoreClone.selfContainedArguments(clone: clone))
        for suffix in ["-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: clone.path + suffix))
        }
        let read = readOnlyCount(clone)
        #expect(read.code == SQLITE_OK)
        #expect(read.rows == 3)
    }
}
