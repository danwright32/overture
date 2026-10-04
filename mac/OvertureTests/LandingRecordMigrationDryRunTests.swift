import Testing
import Foundation
import SwiftData

// #4335 (A6) migration dry run (L267). Five new columns, all defaulted or optional, so the migration is a
// lightweight addition: `LandingRun.sequence`, `entryPointRaw` and `startedAt`, and
// `WatchedSource.lastLandedRunID` and `lastLandedSequence`. This rehearses it against a COPY of the real
// Release store (never the live file), through the one shared clone and MigrationRehearsal, and proves every
// existing Prospect, WatchedSource and LandingRun survives, and the migrated store takes the new values and
// reads them back. It says so when it rehearsed nothing (no live store on this machine) rather than passing
// silently.
//
// Which store it is handed decides what "survives" means. A store from before #4335 has no landing record
// columns, so every source must read as never landed by a recorded run. Once Dan's installed build carries
// #4335 the live store already HAS the columns and real landings have written them (2026-10-03: this test
// went red on every merge for exactly that reason), so the honest claim is that every value the file held
// before this build opened it reads back unchanged. Both arms are read from the file with sqlite3 BEFORE the
// container opens it, so neither compares SwiftData against itself (L70).
@MainActor
@Suite("Landing record columns migration dry run against a clone of the live store (#4335)")
struct LandingRecordMigrationDryRunTests {
    private var releaseStoreURL: URL {
        StoreLocation.storeURL(appSupport: StoreLocation.appSupport, isDebugBuild: false)
    }

    @Test func addingTheLandingRecordColumnsPreservesEveryRowInACloneOfTheLiveStore() throws {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("landing-record-dryrun-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { FileStores.remove(tmpDir) }

        let start = try MigrationRehearsal.begin("the landing record columns", liveStore: releaseStoreURL,
                                                 into: tmpDir)
        guard case let .rehearse(copy) = start else {
            if case let .skipped(said) = start { MigrationRehearsal.report(said) }
            if case let .cloneFailed(said) = start { MigrationRehearsal.report(said) }
            return
        }

        // Counted with SQLite rather than SwiftData, so the count is of the file as Dan's build left it,
        // before anything this build declares has opened it.
        let before = try Self.counts(at: copy)
        let landed = try Self.landingColumns(at: copy)

        let container = try FileStores.container(for: AppSchema.schema, configurations: [ModelConfiguration(url: copy)])
        let ctx = ModelContext(container)
        let sources = try ctx.fetch(FetchDescriptor<WatchedSource>())
        #expect(try ctx.fetch(FetchDescriptor<Prospect>()).count == before.prospects)
        #expect(sources.count == before.sources)
        #expect(try ctx.fetch(FetchDescriptor<LandingRun>()).count == before.runs)
        let runs = try ctx.fetch(FetchDescriptor<LandingRun>())
        if let landed {
            // Already migrated: every stored value reads back exactly as the file held it.
            let readSources = Dictionary(uniqueKeysWithValues: sources.map {
                ($0.sourceId, Self.Landed(runID: $0.lastLandedRunID, sequence: $0.lastLandedSequence)) })
            #expect(readSources == landed.sources, "a source's landing record changed when this build opened the store")
            // Compared as sorted lists rather than keyed, because nothing makes `runIdentity` unique.
            let readRuns = runs.map { Self.Run(identity: $0.runIdentity, entryPoint: $0.entryPointRaw, sequence: $0.sequence) }
                .sorted()
            #expect(readRuns == landed.runs, "a landing run's sequence or entry point changed when this build opened the store")
        } else {
            #expect(sources.allSatisfy { $0.lastLandedRunID == nil && $0.lastLandedSequence == 0 },
                    "a migrated source reads as landed by a run nothing recorded")
            #expect(runs.allSatisfy { $0.sequence == 0 && $0.entryPointRaw.isEmpty })
            // #4335 (the recovery): two more columns, a count and a time, both reading as never recovered.
            #expect(runs.allSatisfy { $0.attemptCount == 0 && $0.recoveredAt == nil })
        }

        // The new columns take a write and read it back, which a schema mismatch breaks and an open-and-count
        // would not notice.
        let started = Date(timeIntervalSince1970: 1_790_792_040.5)
        let dry = LandingRun(runIdentity: "dry-run-landing", landedAt: nil, sequence: 9_999,
                             entryPoint: .runScoutLanding, startedAt: started)
        dry.attemptCount = 2
        dry.recoveredAt = started.addingTimeInterval(60)
        ctx.insert(dry)
        if let first = sources.first {
            first.lastLandedRunID = "dry-run-landing"
            first.lastLandedSequence = 9_999
        }
        try ctx.save()
        let fresh = ModelContext(container)
        #expect(try LandingRun.highestSequence(in: fresh) == 9_999)
        let run = try #require(try fresh.fetch(FetchDescriptor<LandingRun>()).first { $0.runIdentity == "dry-run-landing" })
        #expect(run.startedAt == started && run.entryPointRaw == "runScoutLanding")
        #expect(run.attemptCount == 2 && run.recoveredAt == started.addingTimeInterval(60))
        if let id = sources.first?.sourceId {
            let s = try #require(try fresh.fetch(FetchDescriptor<WatchedSource>()).first { $0.sourceId == id })
            #expect(s.lastLandedRunID == "dry-run-landing" && s.lastLandedSequence == 9_999)
        }
    }

    struct Landed: Equatable {
        let runID: String?
        let sequence: Int
    }

    struct Run: Comparable {
        let identity: String
        let entryPoint: String
        let sequence: Int
        static func < (a: Run, b: Run) -> Bool {
            (a.identity, a.entryPoint, a.sequence) < (b.identity, b.entryPoint, b.sequence)
        }
    }

    // The landing record columns as the file holds them, or nil when the file predates them (a store from
    // before #4335).
    private static func landingColumns(at store: URL) throws
        -> (sources: [String: Landed], runs: [Run])? {
        let columns = try query(store, "SELECT name FROM pragma_table_info('ZWATCHEDSOURCE');")
        guard columns.contains(where: { $0.first == "ZLASTLANDEDRUNID" }) else { return nil }
        // Absence is its own column rather than a sentinel value, since the sqlite3 shell rewrites control
        // characters on output and a sentinel chosen to be unlikely is a value somebody can write.
        let sources = try query(store, "SELECT ZSOURCEID, ZLASTLANDEDRUNID IS NULL, ifnull(ZLASTLANDEDRUNID, ''), ZLASTLANDEDSEQUENCE FROM ZWATCHEDSOURCE;")
        let runs = try query(store, "SELECT ZRUNIDENTITY, ifnull(ZENTRYPOINTRAW, ''), ZSEQUENCE FROM ZLANDINGRUN;")
        let keyed = Dictionary(uniqueKeysWithValues: sources.map { r in
            (r[0], Landed(runID: r[1] == "1" ? nil : r[2], sequence: Int(r[3]) ?? -1))
        })
        return (keyed, runs.map { Run(identity: $0[0], entryPoint: $0[1], sequence: Int($0[2]) ?? -1) }.sorted())
    }

    // One read-only sqlite3 query, rows split on the unit separator so a value holding "|" stays whole.
    private static func query(_ store: URL, _ sql: String) throws -> [[String]] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        p.arguments = ["-readonly", "-separator", "\u{1F}", store.path, sql]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .map { $0.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init) }
    }

    // Row counts of the three tables, read from the file with sqlite3. A table the old build never created
    // (LandingRun, on a store from before #4336) counts as zero rows.
    private static func counts(at store: URL) throws -> (prospects: Int, sources: Int, runs: Int) {
        func count(_ table: String) throws -> Int {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            p.arguments = ["-readonly", store.path,
                           "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='\(table)';"
                           + " SELECT count(*) FROM \(table);"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            try p.run()
            p.waitUntilExit()
            let lines = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").map(String.init)
            guard lines.first == "1" else { return 0 }
            return Int(lines.dropFirst().first ?? "") ?? -1
        }
        return (try count("ZPROSPECT"), try count("ZWATCHEDSOURCE"), try count("ZLANDINGRUN"))
    }
}
