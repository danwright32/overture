import Testing
import Foundation
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

    // Writes `count` shows, setting a send mode on the first `withMode` of them, and returns the store URL.
    private func makeStore(count: Int, withMode: Int) throws -> URL {
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
        return url
    }

    @Test func countsOnlyTheRowsCarryingAValue() throws {
        let url = try makeStore(count: 3, withMode: 1)

        #expect(StoreColumnCensus.nonNullCount(table: "ZPROSPECT",
                                               column: "ZSENDSTOGETHEROVERRIDE",
                                               inSQLiteFileAt: url.path) == 1)
    }

    @Test func countsZeroWhenNoRowCarriesAValue() throws {
        let url = try makeStore(count: 3, withMode: 0)

        #expect(StoreColumnCensus.nonNullCount(table: "ZPROSPECT",
                                               column: "ZSENDSTOGETHEROVERRIDE",
                                               inSQLiteFileAt: url.path) == 0)
    }

    // The detector detecting: this is the shape the rehearsal relies on. A guard is only real once it has
    // been seen to report the thing it exists to report (L1), so a value appearing between two censuses
    // must change the number, not merely be readable.
    @Test func aValueWrittenAfterACensusChangesTheCount() throws {
        let url = try makeStore(count: 3, withMode: 0)
        let before = StoreColumnCensus.nonNullCount(table: "ZPROSPECT",
                                                    column: "ZSENDSTOGETHEROVERRIDE",
                                                    inSQLiteFileAt: url.path)

        // Reopen and set the mode on EVERY row, which is the shape of the failure the rehearsal guards:
        // a migration default reaches all of them at once.
        let ctx = ModelContext(try ModelContainer(for: AppSchema.schema,
                                                  configurations: [ModelConfiguration(url: url)]))
        for p in try ctx.fetch(FetchDescriptor<Prospect>()) { p.sendsTogetherOverride = true }
        try ctx.save()

        let after = StoreColumnCensus.nonNullCount(table: "ZPROSPECT",
                                                   column: "ZSENDSTOGETHEROVERRIDE",
                                                   inSQLiteFileAt: url.path)
        #expect(before == 0)
        #expect(after == 3)
        #expect(before != after)
    }

    // The store is WAL-mode (confirmed against the live file, 2026-08-04), so a write Dan made while the app
    // is open can still be sitting in the sidecar rather than the main database when the rehearsal clones it.
    // A read that could not see the WAL would undercount the "before" side and report a change nobody made,
    // so the sidecar is asserted to be genuinely non-empty here rather than hoped to be.
    @Test func seesAWriteStillSittingInTheWriteAheadLog() throws {
        let url = try makeStore(count: 3, withMode: 0)

        // Held open deliberately: nothing checkpoints the sidecar into the store while this container lives.
        let container = try ModelContainer(for: AppSchema.schema,
                                           configurations: [ModelConfiguration(url: url)])
        let ctx = ModelContext(container)
        for p in try ctx.fetch(FetchDescriptor<Prospect>()) { p.sendsTogetherOverride = true }
        try ctx.save()

        let wal = URL(fileURLWithPath: url.path + "-wal")
        let walSize = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0
        #expect(walSize ?? 0 > 0, "the write landed in the main store, so this no longer covers the WAL at all")

        #expect(StoreColumnCensus.nonNullCount(table: "ZPROSPECT",
                                               column: "ZSENDSTOGETHEROVERRIDE",
                                               inSQLiteFileAt: url.path) == 3)
        _ = container
    }

    // A census that cannot be taken must say so, never answer zero: zero is indistinguishable from a clean
    // store and would make the rehearsal pass by measuring nothing (L11).
    @Test func reportsNothingRatherThanZeroForAColumnItCannotRead() throws {
        let url = try makeStore(count: 2, withMode: 1)

        #expect(StoreColumnCensus.nonNullCount(table: "ZPROSPECT",
                                               column: "ZNOSUCHCOLUMN",
                                               inSQLiteFileAt: url.path) == nil)
        #expect(StoreColumnCensus.nonNullCount(table: "ZNOSUCHTABLE",
                                               column: "ZSENDSTOGETHEROVERRIDE",
                                               inSQLiteFileAt: url.path) == nil)
    }

    @Test func reportsNothingForAFileThatIsNotThere() {
        let missing = tempStoreURL()

        #expect(StoreColumnCensus.nonNullCount(table: "ZPROSPECT",
                                               column: "ZSENDSTOGETHEROVERRIDE",
                                               inSQLiteFileAt: missing.path) == nil)
    }
}
