import Foundation
import SwiftData
import SQLite3
#if OVERTURE_HOSTED_TESTS
@testable import Overture
#endif

// #4106: the probe helpers every Phase 0, 0b and 0c probe shares: the opt in, the stopwatch, a median of
// five with its spread, the load average, and the 4x corpus built from a clone of the live store.
//
// Lifted out of QueueEnginePhase0ProbeTests.swift unchanged, so the HOSTED view body probe (0c.8) compiles
// the same helpers rather than a copy of them. Compiled into both test targets: the pure one reaches the
// app by compiling its sources in, the hosted one through the import above, which only the hosted
// target's OVERTURE_HOSTED_TESTS condition switches on (mac/project.yml).
//
// Every timing is a median of five with its spread (L395, L656), taken in the Debug build the test runner
// builds, which is the build every earlier figure on #4106 was taken in too; a Release build is faster and
// none of these numbers describe it. Load average is printed beside each block (L356).

enum Phase0 {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0"] != nil
    }

    nonisolated static var liveStoreExists: Bool { LiveStoreClone.liveStoreURL != nil }

    nonisolated static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    nonisolated static func ms(since start: UInt64) -> Double { Double(now() - start) / 1_000_000 }

    /// #4384: a probe's save that did not reach the store, naming the step it came from. Every probe save goes
    /// through `save`, `saveFailure` or `requireSaved` below rather than `try? context.save()`, which let a
    /// save that never landed read exactly like one that did, so the comparisons and timings after it judged
    /// uncommitted state (L515, L10). Carries the save's own text (L520).
    struct SaveNotLanded: Error, CustomStringConvertible {
        let step: String
        let underlying: String
        var description: String { "the \(step) save did not land: \(underlying)" }
    }

    /// nil when the save landed, otherwise the save's own error text. For a closure that cannot throw: a
    /// stopwatch body, or work run on another thread, whose caller then hands the answer to `requireSaved`.
    nonisolated static func saveFailure(_ context: ModelContext,
                                        save: (ModelContext) throws -> Void = { try $0.save() }) -> String? {
        do {
            try save(context)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    nonisolated static func requireSaved(_ failure: String?, step: String) throws {
        if let failure { throw SaveNotLanded(step: step, underlying: failure) }
    }

    nonisolated static func save(_ context: ModelContext, step: String,
                                 save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        try requireSaved(saveFailure(context, save: save), step: step)
    }

    nonisolated static func time(_ work: () -> Void) -> Double {
        let start = now()
        work()
        return ms(since: start)
    }

    struct Reading: Sendable {
        let runs: [Double]
        var median: Double { runs.sorted()[runs.count / 2] }
        var low: Double { runs.min() ?? 0 }
        var high: Double { runs.max() ?? 0 }
        var text: String { String(format: "%.1f ms (%.1f to %.1f)", median, low, high) }
    }

    nonisolated static func median5(_ work: () -> Void) -> Reading {
        Reading(runs: (0..<5).map { _ in time(work) })
    }

    // THE load average reader every probe shares (#4315). It used to be three copies, one per probe
    // family, and they disagreed on a failed read: one read it as 0, a quiet Mac, which could let a
    // replay on an unmeasured Mac score a PASS (fixed on #4314). The next probe copies whichever one it
    // finds first (L263, L370), so there is one, and `Phase0LoadReaderTests` fails on a second call to
    // the system reader anywhere in the test targets.

    /// The one, five and fifteen minute averages. `getloadavg` returns how many it filled, -1 on failure,
    /// and leaves the rest at whatever the buffer held, so a reading it did not fill is INFINITE: it can
    /// never pass as quiet, where read as 0 it would (L490).
    nonisolated static func loadReadings(samplesTaken: Int32, averages: [Double]) -> [Double] {
        (0..<3).map { i in i < Int(samplesTaken) && i < averages.count ? averages[i] : .infinity }
    }

    nonisolated static func loadAverages() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        let taken = getloadavg(&l, 3)
        return loadReadings(samplesTaken: taken, averages: l)
    }

    nonisolated static func oneMinuteLoad() -> Double { loadAverages()[0] }

    /// The line printed beside every timed block (L356).
    nonisolated static func loadText(_ readings: [Double]) -> String {
        String(format: "load %.2f %.2f %.2f", readings[0], readings[1], readings[2])
    }

    nonisolated static func load() -> String { loadText(loadAverages()) }

    /// Waits for the one minute load to fall under `below`, bounded by `deadline` seconds (L110), polling
    /// every `poll`. `load` is the last reading; one at or over `below` means the wait ran out, and a load
    /// that could not be read is infinite, so it never ends the wait early as quiet. The reader, the sleep
    /// and the clock are parameters so a test can drive every outcome without waiting (L524).
    nonisolated static func waitForLoad(
        below: Double, deadline seconds: Double, poll: Double,
        read: () -> Double = { Phase0.oneMinuteLoad() },
        sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
        clock: () -> Double = { Double(Phase0.now()) / 1_000_000_000 }
    ) -> (load: Double, waited: Double, text: String) {
        let start = clock()
        var waited = 0.0
        var load = read()
        while load >= below && waited < seconds {
            sleep(poll)
            waited = clock() - start
            load = read()
        }
        let verdict = load < below ? "yes" : "NO"
        return (load, waited, String(format: "one minute load %.2f (under %.0f: ", load, below) + verdict
                    + String(format: ", waited %.0f s)", waited))
    }

    nonisolated static func say(_ line: String) { print("phase0 " + line) }

    nonisolated static func openContainer(at url: URL) throws -> ModelContainer {
        try FileStores.container(for: AppSchema.schema, configurations: [
            ModelConfiguration(schema: AppSchema.schema, url: url, cloudKitDatabase: .none)])
    }

    /// A copy of `clone` holding `factor` times the shows. The copies scale the clone's DISTRIBUTIONS rather
    /// than duplicating rows (L391): every copy keeps its row's shape (status, dates, fields, contacts) and
    /// gets a new identity (natural key, presenter, venue, title, series, thread ids, contact addresses), so
    /// cross-row clusters keyed on those form their own clusters rather than growing fourfold. Dates are
    /// kept, so a night holds `factor` times the shows it did: pessimistic for any term grouped by night,
    /// and stated beside every reading taken on it.
    ///
    /// Listings are part of that identity too (#4106, found by the #4275 attribution): a copy's
    /// `sourceListingURL` and every one of its `runSourceURLs` carry the copy's glue, so a listing holding N
    /// shows in the clone holds N in each copy rather than 4N in one. `ScaledCorpusKeepsListingsDistinctTests`
    /// holds that. `runSourceURLs` is an archived blob SQL cannot edit, so it is rewritten through the model
    /// after the rows are copied.
    nonisolated static func glue(forCopy k: Int) -> String { "q" + String(UnicodeScalar(UInt8(96 + k))) }

    nonisolated static func scaledCopy(of clone: URL, factor: Int, in dir: URL) throws -> URL {
        let out = dir.appendingPathComponent("Overture-x\(factor).store")
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: clone.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: out.path + suffix))
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(out.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw ScaleError.sql("open failed")
        }
        var closed = false
        defer { if !closed { sqlite3_close(db) } }
        func columns(_ table: String) throws -> [String] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
                throw ScaleError.sql("table_info \(table)")
            }
            defer { sqlite3_finalize(stmt) }
            var names: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                names.append(String(cString: sqlite3_column_text(stmt, 1)))
            }
            return names
        }
        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
                let message = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw ScaleError.sql(message)
            }
        }
        let offset = 100_000
        let showSuffixed: Set<String> = ["ZNATURALKEY", "ZPRESENTER", "ZVENUE", "ZGROUPNAME", "ZSCOUTGROUPNAME",
                                         "ZSCOUTVENUE", "ZSERIESID", "ZGMAILTHREADID", "ZGMAILMESSAGEID",
                                         "ZSOURCELISTINGURL"]
        let contactPrefixed: Set<String> = ["ZEMAIL", "ZID"]
        let contactSuffixed: Set<String> = ["ZGMAILTHREADID", "ZGMAILMESSAGEID", "ZSENDGROUPID"]
        let showCols = try columns("ZPROSPECT")
        let contactCols = try columns("ZRECIPIENT")
        try exec("BEGIN")
        for k in 1..<factor {
            let shift = k * offset
            // GLUED onto the last word, never a new word: a shared " x1" word would put every copied name
            // into one bucket of any word-indexed term (`ProducerGate.VenueKeyIndex`), which made the first
            // reading of this corpus superlinear for a reason no real store has. Glued, "Hall" becomes
            // "Hallqa", so names share words within a copy exactly as they do in the clone.
            let glue = Self.glue(forCopy: k)
            let showExprs = showCols.map { c -> String in
                if c == "Z_PK" { return "Z_PK + \(shift)" }
                if showSuffixed.contains(c) { return "\(c) || '\(glue)'" }
                return c
            }
            try exec("INSERT INTO ZPROSPECT (\(showCols.joined(separator: ","))) SELECT "
                     + "\(showExprs.joined(separator: ",")) FROM ZPROSPECT WHERE Z_PK < \(offset)")
            let contactExprs = contactCols.map { c -> String in
                if c == "Z_PK" || c == "ZPROSPECT" { return "\(c) + \(shift)" }
                if contactPrefixed.contains(c) { return "'x\(k).' || \(c)" }
                if contactSuffixed.contains(c) { return "\(c) || '\(glue)'" }
                return c
            }
            try exec("INSERT INTO ZRECIPIENT (\(contactCols.joined(separator: ","))) SELECT "
                     + "\(contactExprs.joined(separator: ",")) FROM ZRECIPIENT WHERE Z_PK < \(offset)")
        }
        try exec("UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT MAX(Z_PK) FROM ZPROSPECT) WHERE Z_NAME = 'Prospect'")
        try exec("UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT MAX(Z_PK) FROM ZRECIPIENT) WHERE Z_NAME = 'Recipient'")
        try exec("COMMIT")

        // Which copy each copied row belongs to, by its (already glued) natural key, for the blob rewrite.
        var copyOf: [String: Int] = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZNATURALKEY, Z_PK / \(offset) FROM ZPROSPECT WHERE Z_PK >= \(offset)",
                                 -1, &stmt, nil) == SQLITE_OK else { throw ScaleError.sql("copied keys") }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let key = sqlite3_column_text(stmt, 0) {
                copyOf[String(cString: key)] = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        closed = true

        let context = ModelContext(try openContainer(at: out))
        var rewritten = 0
        for row in try context.fetch(FetchDescriptor<Prospect>()) {
            guard let k = copyOf[row.naturalKey], !row.runSourceURLs.isEmpty else { continue }
            let glue = Self.glue(forCopy: k)
            row.runSourceURLs = row.runSourceURLs.map { $0.isEmpty ? $0 : $0 + glue }
            rewritten += 1
        }
        try context.save()
        say("scaled corpus: \(copyOf.count) copied shows, run listings re-identified on \(rewritten)")
        return out
    }

    enum ScaleError: Error { case sql(String) }

    /// The shape a scaled corpus must keep (L48): printed side by side for the clone and the copy.
    static func shape(_ rows: [Prospect]) -> String {
        let contacts = rows.reduce(0) { $0 + $1.recipients.count }
        let dismissed = rows.filter { $0.statusRaw == "dismissed" }.count
        let contacted = rows.filter { $0.sentAt != nil }.count
        var perNight: [String: Int] = [:]
        for r in rows { perNight[r.performanceDate ?? "", default: 0] += 1 }
        let pairs = Set(rows.map { "\($0.presenter ?? "")|\($0.venue ?? "")" }).count
        return "\(rows.count) shows, \(contacts) contacts (\(String(format: "%.3f", Double(contacts) / Double(max(rows.count, 1)))) a show), "
            + "dismissed \(String(format: "%.3f", Double(dismissed) / Double(max(rows.count, 1)))), "
            + "contacted \(String(format: "%.3f", Double(contacted) / Double(max(rows.count, 1)))), "
            + "largest night \(perNight.values.max() ?? 0), presenter-venue pairs \(pairs)"
    }
}
