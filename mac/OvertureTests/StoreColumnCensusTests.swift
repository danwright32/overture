import Testing
import Foundation
import SQLite3
import SwiftData

// #2054: the counting half of the joint-send rehearsal's replacement guard.
//
// The rehearsal used to ask "no show carries a send mode", which stopped being true the first night Dan
// used the feature and could never tell his own choice from the migration default it was built to catch
// (L68). What it can ask instead is whether OPENING the store changes how many rows carry a value: a
// fabricated default sets every row, so the count jumps, while Dan choosing a mode is a write he made
// before the census and is simply carried through both sides of it.
//
// That question can only be asked of the file BEFORE SwiftData opens it, so this reads the store's own
// SQLite directly, the way StoreSchemaGuard already does (#663). These tests build a REAL Overture store
// through SwiftData and census the actual `ZPROSPECT` / `ZSENDSTOGETHEROVERRIDE` names, rather than a
// synthetic table, so a rename or a WAL that hides the newest write shows up here rather than in a
// rehearsal that quietly counts zero (L52).
@MainActor
@Suite("Counting how many stored rows carry a value in one column")
struct StoreColumnCensusTests {
    private func tempStoreURL() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("census-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("Overture.store")
    }

    private func makeProspect(_ key: String) -> Prospect {
        Prospect(naturalKey: key, groupName: "Vienna Philharmonic", discipline: "music",
                 venue: "Stern Auditorium", performanceDate: "2026-11-14",
                 sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                 production: "self", profile: "strong", coverage: "likely_uncovered",
                 fitScore: 9, tier: "high", fitReason: "r", matchedClientName: nil,
                 possibleMatchSource: nil, possibleMatchName: nil)
    }

    // A written store and the connection that wrote it, handed back TOGETHER (#2930).
    //
    // The container is part of the fixture rather than a local that goes out of scope, because whether it
    // is still alive decides what is on disk. SwiftData writes in WAL mode, and a WAL-mode database with
    // no `-shm` beside it cannot be opened READ-ONLY at all: a read-only connection is not allowed to
    // create the shared-memory file it would need (the same fact LiveStoreClone converts its clone to
    // avoid). While the writer is open both sidecars exist and the census reads it; once the last
    // connection closes they are removed and it reads the plain file. The failure is the moment BETWEEN,
    // which is why letting the container fall out of scope made these flaky under load rather than
    // broken: measured 2026-08-17 and again 2026-08-20, one full-suite run each time, passing on a
    // scoped re-run both times.
    private struct WrittenStore {
        let url: URL
        let container: ModelContainer
    }

    // Writes `count` shows, setting a send mode on the first `withMode` of them.
    private func makeStore(count: Int, withMode: Int) throws -> WrittenStore {
        let url = tempStoreURL()
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: url)])
        let ctx = ModelContext(container)
        for i in 0..<count {
            let p = makeProspect("k\(i)")
            if i < withMode { p.sendsTogetherOverride = true }
            ctx.insert(p)
        }
        try ctx.save()
        return WrittenStore(url: url, container: container)
    }

    private func census(_ store: WrittenStore,
                        table: String = "ZPROSPECT",
                        column: String = "ZSENDSTOGETHEROVERRIDE") -> StoreColumnCensus.Reading {
        withExtendedLifetime(store.container) {
            StoreColumnCensus.nonNullRows(table: table, column: column, inSQLiteFileAt: store.url.path)
        }
    }

    @Test func countsOnlyTheRowsCarryingAValue() throws {
        let store = try makeStore(count: 3, withMode: 1)

        #expect(census(store) == .rows(1))
    }

    @Test func countsZeroWhenNoRowCarriesAValue() throws {
        let store = try makeStore(count: 3, withMode: 0)

        #expect(census(store) == .rows(0))
    }

    // The detector detecting: this is the shape the rehearsal relies on. A guard is only real once it has
    // been seen to report the thing it exists to report (L1), so a value appearing between two censuses
    // must change the number, not merely be readable.
    @Test func aValueWrittenAfterACensusChangesTheCount() throws {
        let store = try makeStore(count: 3, withMode: 0)
        let before = census(store)

        // Reopen and set the mode on EVERY row, which is the shape of the failure the rehearsal guards:
        // a migration default reaches all of them at once.
        let ctx = ModelContext(try ModelContainer(for: AppSchema.schema,
                                                  configurations: [ModelConfiguration(url: store.url)]))
        for p in try ctx.fetch(FetchDescriptor<Prospect>()) { p.sendsTogetherOverride = true }
        try ctx.save()

        let after = census(store)
        #expect(before == .rows(0))
        #expect(after == .rows(3))
        #expect(before != after)
    }

    // The store is WAL-mode (confirmed against the live file, 2026-08-04), so a write Dan made while the app
    // is open can still be sitting in the sidecar rather than the main database when the rehearsal clones it.
    // A read that could not see the WAL would undercount the "before" side and report a change nobody made,
    // so the sidecar is asserted to be genuinely non-empty here rather than hoped to be.
    @Test func seesAWriteStillSittingInTheWriteAheadLog() throws {
        let store = try makeStore(count: 3, withMode: 0)

        // Held open deliberately: nothing checkpoints the sidecar into the store while this container lives.
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: store.url)])
        let ctx = ModelContext(container)
        for p in try ctx.fetch(FetchDescriptor<Prospect>()) { p.sendsTogetherOverride = true }
        try ctx.save()

        let wal = URL(fileURLWithPath: store.url.path + "-wal")
        let walSize = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0
        #expect(walSize ?? 0 > 0, "the write landed in the main store, so this no longer covers the WAL at all")

        #expect(withExtendedLifetime(container) { census(store) } == .rows(3))
    }

    // A census that cannot be taken must say so, never answer zero: zero is indistinguishable from a clean
    // store and would make the rehearsal pass by measuring nothing (L11).
    //
    // And it must say WHICH of its refusals it made (#2930). Every one of them used to be the same nil, so
    // "no row carries a value" and "this could not be read at all" were one answer to every caller, and the
    // conditions that produce the second are exactly the busy machine where the first matters (L90).
    @Test func namesTheColumnItCouldNotFind() throws {
        let store = try makeStore(count: 2, withMode: 1)

        #expect(census(store, column: "ZNOSUCHCOLUMN")
                == .unreadable(.columnNotInTable(column: "ZNOSUCHCOLUMN", table: "ZPROSPECT")))
    }

    // A missing TABLE and a missing column are different states with different causes: one is a store that
    // is not Overture's, the other is a column this build has and that one does not.
    @Test func namesTheTableItCouldNotFind() throws {
        let store = try makeStore(count: 2, withMode: 1)

        #expect(census(store, table: "ZNOSUCHTABLE") == .unreadable(.tableNotInStore(table: "ZNOSUCHTABLE")))
    }

    @Test func namesTheFileThatIsNotThere() {
        let missing = tempStoreURL()

        let reading = StoreColumnCensus.nonNullRows(table: "ZPROSPECT",
                                                    column: "ZSENDSTOGETHEROVERRIDE",
                                                    inSQLiteFileAt: missing.path)
        #expect(reading == .unreadable(.noFileAtPath(missing.path)))
    }

    // A store whose PAGES are damaged but whose header still opens: the open succeeds and the first
    // query faults. That is the shape #2930 was really about, and the one this reader used to answer
    // wrongly: the first version turned SQLite's fault into `.tableNotInStore(table: "ZPROSPECT")`, a
    // definite fact about Dan's data manufactured out of not knowing.
    //
    // Built by damaging a COPY, so nothing owns the file and no connection is lied to. An earlier
    // version of this test built its state by deleting the `-shm` a live container still held, which is
    // an API violation SQLite names in its own log and which depends on release timing rather than on
    // any state: it passed scoped and failed a full run the same evening (#3043).
    @Test func saysItCouldNotReadAStoreWhosePagesAreDamaged() throws {
        let store = try makeStore(count: 3, withMode: 1)
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("census-damaged-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let copied = dir.appendingPathComponent("Overture.store")

        var bytes = try withExtendedLifetime(store.container) { try Data(contentsOf: store.url) }
        #expect(bytes.count > 4096, "the fixture store is too small to damage past its header")
        // The first page carries the header SQLite reads at open. Everything after it is where the
        // schema lives, so this opens and then cannot answer.
        for i in 4096..<bytes.count { bytes[i] = 0xFF }
        try bytes.write(to: copied)

        let reading = StoreColumnCensus.nonNullRows(table: "ZPROSPECT",
                                                    column: "ZSENDSTOGETHEROVERRIDE",
                                                    inSQLiteFileAt: copied.path)
        guard case .unreadable(let why) = reading else {
            Issue.record("a damaged store must not answer a count, and this answered \(reading)")
            return
        }
        #expect(why != .tableNotInStore(table: "ZPROSPECT"),
                "a query that FAILED is not evidence the table is absent")
        #expect(why != .columnNotInTable(column: "ZSENDSTOGETHEROVERRIDE", table: "ZPROSPECT"),
                "nor evidence the column is absent")
        let failure = try #require(why.sqliteFailure,
                                   "a fault must carry SQLite's own answer, or it says as little as nil did")
        #expect(failure.code != SQLITE_OK)
        #expect(!failure.message.isEmpty)
    }

    // Every refusal this reader can answer must have a test that PRODUCES it, or a case nothing ever
    // reaches reads exactly like one that cannot happen (L151). This is the open failing: a store the
    // process is not allowed to read at all.
    @Test func saysItCouldNotOpenAFileItIsNotAllowedToRead() throws {
        let store = try makeStore(count: 2, withMode: 1)
        let fm = FileManager.default
        try withExtendedLifetime(store.container) {
            try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: store.url.path)
        }
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.url.path) }

        let reading = StoreColumnCensus.nonNullRows(table: "ZPROSPECT",
                                                    column: "ZSENDSTOGETHEROVERRIDE",
                                                    inSQLiteFileAt: store.url.path)
        guard case .unreadable(.couldNotOpen(let failure)) = reading else {
            Issue.record("expected SQLite's own refusal to open, got \(reading)")
            return
        }
        #expect(failure.code != SQLITE_OK)
        #expect(!failure.message.isEmpty)
    }

    // Interpolated into the SQL rather than bound, so the names are checked before anything is opened.
    @Test func refusesANameThatIsNotAPlainIdentifier() throws {
        let store = try makeStore(count: 1, withMode: 1)

        #expect(census(store, table: "ZPROSPECT; DROP TABLE ZPROSPECT")
                == .unreadable(.notAPlainIdentifier("ZPROSPECT; DROP TABLE ZPROSPECT")))
        #expect(census(store, column: "") == .unreadable(.notAPlainIdentifier("")))
    }
}
