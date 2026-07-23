import Testing
import Foundation
import SQLite3
@testable import Overture

// #1409: the #663 guard only catches a FOREIGN file at the store path. It cannot catch Overture's own
// store quietly losing most of its rows, because a store with 3 shows is structurally identical to one
// with 501: both open cleanly and look healthy. That is the failure mode with no detection at all
// today, and the one that would cost the most before anyone noticed.
//
// The comparison needs no new bookkeeping. The launch backups already on disk ARE the history, so the
// check counts the live store and the most recent backup the same read-only way and compares them.
// That works on day one against backups taken before this shipped, and the number can never drift from
// what was actually backed up, because it IS what was backed up.
@Suite("A store that opens far emptier than its last backup says so (#1409)")
struct StoreShrinkCheckTests {

    // MARK: - The rule, on its own

    @Test("a store that lost almost everything warns")
    func sharpDropWarns() {
        #expect(StoreShrinkCheck.warning(live: 3, previous: .count(501)) != nil)
    }

    @Test("a store that grew, held steady, or dipped a little says nothing")
    func normalMovementIsSilent() {
        #expect(StoreShrinkCheck.warning(live: 520, previous: .count(501)) == nil)
        #expect(StoreShrinkCheck.warning(live: 501, previous: .count(501)) == nil)
        #expect(StoreShrinkCheck.warning(live: 480, previous: .count(501)) == nil)
    }

    // Halving is the trigger, but not on numbers too small to mean anything: a brand new store going
    // from 4 shows to 1 is Dan clearing out a test row, not a disaster, and a check that cried wolf
    // there would be turned off long before the day it mattered.
    @Test("a big proportional drop on tiny numbers stays quiet")
    func tinyStoresDoNotCryWolf() {
        #expect(StoreShrinkCheck.warning(live: 1, previous: .count(4)) == nil)
        #expect(StoreShrinkCheck.warning(live: 0, previous: .count(9)) == nil)
        // ...but the same proportion on a real store does not stay quiet.
        #expect(StoreShrinkCheck.warning(live: 0, previous: .count(10)) != nil)
    }

    @Test("exactly half is not yet a warning, below half is")
    func theBoundary() {
        #expect(StoreShrinkCheck.warning(live: 50, previous: .count(100)) == nil)
        #expect(StoreShrinkCheck.warning(live: 49, previous: .count(100)) != nil)
    }

    // The first launch after this ships has nothing to compare against yet. That is not a finding.
    @Test("no earlier backup at all is silent, not a warning")
    func noHistoryIsSilent() {
        #expect(StoreShrinkCheck.warning(live: 3, previous: .none) == nil)
        #expect(StoreShrinkCheck.warning(live: 0, previous: .none) == nil)
    }

    // ...but a backup that EXISTS and cannot be counted is different, and must not pass as "fine".
    // Failing towards a warning is the whole point: the case this feature exists for is the one where
    // something is already wrong, which is exactly when a read is most likely to fail.
    @Test("a backup that exists but cannot be read warns rather than staying silent")
    func unreadableHistoryWarns() {
        let warning = StoreShrinkCheck.warning(live: 501, previous: .unreadable("20260723-113732"))

        #expect(warning != nil)
        #expect(warning?.message.contains("20260723-113732") == true)
        // The heading must not overclaim: nothing is known to be missing, only unverifiable.
        #expect(warning?.title == StoreShrinkCheck.unreadableTitle)
    }

    // The sentence has to carry the two numbers and where to look, or it is just an alarm with no
    // next move. Dan reads this once, at launch, possibly in a panic.
    @Test("the warning names both counts and where the backups are")
    func theWarningIsActionable() throws {
        let warning = try #require(StoreShrinkCheck.warning(live: 3, previous: .count(501)))

        #expect(warning.message.contains("3"))
        #expect(warning.message.contains("501"))
        #expect(warning.message.lowercased().contains("backup"))
        // #843: the heading says what it MEANS, the message carries the evidence, so the sheet does
        // not say the same thing twice in two sizes.
        #expect(warning.title == StoreShrinkCheck.shrankTitle)
        #expect(!warning.title.contains("501"))
    }

    // MARK: - Counting a real store

    private func sandbox() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-shrink-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // A real SQLite file shaped like Overture's own store, with `rows` prospects in it.
    private func writeStore(at url: URL, rows: Int) {
        var db: OpaquePointer?
        #expect(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
        #expect(sqlite3_exec(db, "CREATE TABLE ZPROSPECT (Z_PK INTEGER PRIMARY KEY);", nil, nil, nil) == SQLITE_OK)
        for i in 1...max(rows, 1) where rows > 0 {
            #expect(sqlite3_exec(db, "INSERT INTO ZPROSPECT (Z_PK) VALUES (\(i));", nil, nil, nil) == SQLITE_OK)
        }
        sqlite3_close(db)
    }

    @Test("counting reads the real store read only, without opening it as a store")
    func countsARealStore() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = dir.appendingPathComponent("Overture.store")
        writeStore(at: store, rows: 7)

        #expect(StoreShrinkCheck.rowCount(at: store) == 7)
    }

    @Test("a file that is not a readable store counts as nothing, rather than as zero rows")
    func anUnreadableFileIsNotZero() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        let junk = dir.appendingPathComponent("Overture.store")
        try Data("not a database".utf8).write(to: junk)

        // nil, NOT 0. Zero rows would read as "the store emptied", inventing a catastrophe out of a
        // file that simply could not be counted.
        #expect(StoreShrinkCheck.rowCount(at: junk) == nil)
    }

    // MARK: - End to end, against real backup folders

    private func makeBackup(_ dataDirectory: URL, named: String, rows: Int) throws {
        let folder = StoreBackup.backupsDirectory(dataDirectory: dataDirectory)
            .appendingPathComponent(named, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        writeStore(at: folder.appendingPathComponent("Overture.store"), rows: rows)
    }

    @Test("the check compares the live store against the newest real backup")
    func endToEnd() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        writeStore(at: dir.appendingPathComponent("Overture.store"), rows: 3)
        try makeBackup(dir, named: "20260722-090000", rows: 480)
        try makeBackup(dir, named: "20260723-090000", rows: 501)

        let warning = try #require(StoreShrinkCheck.check(dataDirectory: dir))

        #expect(warning.message.contains("501"))    // the NEWEST backup, not the older one
        #expect(warning.message.contains("3"))
    }

    // #1410 named refusal snapshots `.foreign` because they hold another app's file. Counting one as
    // the previous count would compare Dan's shows against iCloud Mail's rows, which is meaningless
    // and would fire this warning on every launch after such an incident.
    @Test("a refusal snapshot is never used as the previous count")
    func foreignSnapshotsAreNotHistory() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        writeStore(at: dir.appendingPathComponent("Overture.store"), rows: 501)
        try makeBackup(dir, named: "20260722-090000", rows: 501)
        try makeBackup(dir, named: "20260723-113732.foreign", rows: 0)

        // Compared against the real backup (501 vs 501): silent. Compared against the foreign
        // snapshot's 0 rows it would have been silent too, so check the reverse case as well.
        #expect(StoreShrinkCheck.check(dataDirectory: dir) == nil)
    }

    @Test("a foreign snapshot holding many rows cannot mask a real collapse")
    func foreignSnapshotCannotMaskACollapse() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }
        writeStore(at: dir.appendingPathComponent("Overture.store"), rows: 2)
        try makeBackup(dir, named: "20260722-090000", rows: 501)
        // Newer, and full of rows, but not Overture's data. If this were treated as the history it
        // would still warn here; what matters is that the REAL 501 is what gets compared.
        try makeBackup(dir, named: "20260723-113732.foreign", rows: 3)

        let warning = try #require(StoreShrinkCheck.check(dataDirectory: dir))

        #expect(warning.message.contains("501"))
    }

    @Test("a fresh install with no store at all is silent")
    func freshInstallIsSilent() throws {
        let dir = try sandbox()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(StoreShrinkCheck.check(dataDirectory: dir) == nil)
    }
}
