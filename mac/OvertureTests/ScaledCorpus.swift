import Foundation
import SwiftData
import SQLite3
#if OVERTURE_HOSTED_TESTS
@testable import Overture
#endif

// #4427: the fourfold corpus, and the scout results that go with it.
//
// `Phase0.scaledCopy` builds the corpus every Phase 0, 0b and 0c probe reads, and delegates here. It lives in
// a file of its own, rather than in Phase0Corpus.swift, because the landing oracle's frozen 4x store is built by
// `LandingOracleTests.freezeTheInputs`, which `scripts/landing-oracle.sh` runs in a worktree of 6d3453d8 with
// only an OVERLAY of test files added. An overlay may only ADD files that commit lacks, and Phase0Corpus.swift
// is one it has, so a corpus built there through `Phase0.scaledCopy` would be 6d3453d8's corpus whatever this
// tree says. This file is in the overlay, so the freeze builds today's corpus. Everything it names must
// therefore exist at 6d3453d8 too, which the overlay's own build proves on every recording.
//
// WHY THE SOURCES SCALE TOO. Until #4427 every copy kept its original's `sourceIds`, and the results landed on
// the corpus were the clone's. So to `FeedReconcile.reconcile` each copy was a show whose every owner was asked
// in the landing and none of them listed it, and it added a real miss to every future copy on every landing:
// 382 shows written by the reconcile at 4x against 7 on the clone, measured by #4372's attribution probe. A real
// store four times the size has four times the sources and four times the results and none of its live shows
// look cancelled (L48, L391). So each copy now has its own `WatchedSource` rows, and `results(_:factor:)` lands
// a copy of every result per copy, under the copy's source id, with every event glued exactly as the copy's
// stored rows are glued.
//
// WHY A COPY'S KEY IS RECOMPUTED. A copy's display fields are glued (title "Hamlet" becomes "qaHamlet"), and a
// landed event is keyed by `Prospect.makeNaturalKey` over its title, date and venue. The original key with the
// glue appended ("hamlet|date|hallqa") is a key no glued event can compute, so every copy event would miss the
// exact key arm its original hits and fall to the URL arms, which re-key: writes a real store never makes. So a
// copy whose original's key is the one the app itself would compute for it (`scoutAnchoredNaturalKey`, true of
// almost every row) gets the key the app computes for the COPY's glued values, which is the key its glued event
// arrives with. A row whose key the app would not compute (a renamed or merged card, #1886) keeps the old
// appended form, so its copy drifts from its event exactly as the original drifts from its own.

enum ScaledCorpus {
    /// Which corpus to build. `before4288` is the corpus as it stood before #4288 (every copy sharing its
    /// original's listing addresses), and therefore also before #4427 (sharing its original's sources, its
    /// key appended): only #4372's attribution probe asks for it, to reproduce the reading probe 0b.6 took on
    /// that corpus. Every other caller takes `current`.
    enum Era: Sendable {
        case current
        case before4288
    }

    enum Failure: Error, CustomStringConvertible {
        case sql(String)
        var description: String {
            switch self {
            case .sql(let message): return "the scaled corpus could not be built: \(message)"
            }
        }
    }

    /// What the build did, said beside every reading taken on it.
    struct Report: Sendable, Equatable {
        var copiedShows = 0
        var copiedSources = 0
        var keysRecomputed = 0
        /// Copies whose original's key is not the one the app would compute for it, so their key stays appended.
        var keysAppendedAsDrifted = 0
        /// Copies whose recomputed key another row already held, so their key stays appended (never a collision).
        var keysAppendedAsTaken = 0
        var runListingsReidentified = 0
        var sourceListsReidentified = 0
    }

    // MARK: the store

    nonisolated static func build(of clone: URL, factor: Int, in dir: URL, era: Era = .current) throws -> URL {
        let out = dir.appendingPathComponent("Overture-x\(factor).store")
        for suffix in ["", "-wal", "-shm"] {
            let from = URL(fileURLWithPath: clone.path + suffix)
            if FileManager.default.fileExists(atPath: from.path) {
                try FileManager.default.copyItem(at: from, to: URL(fileURLWithPath: out.path + suffix))
            }
        }
        var report = Report()
        let copyOf = try copyRows(in: out, factor: factor, era: era, report: &report)

        // The archived blobs SQL cannot edit, rewritten through the model: each copy's run listings and its
        // list of owning sources.
        let context = ModelContext(try Phase0.openContainer(at: out))
        for row in try context.fetch(FetchDescriptor<Prospect>()) {
            guard era == .current, let k = copyOf[row.naturalKey] else { continue }
            let glue = Phase0.glue(forCopy: k)
            if !row.runSourceURLs.isEmpty {
                row.runSourceURLs = row.runSourceURLs.map { $0.isEmpty ? $0 : $0 + glue }
                report.runListingsReidentified += 1
            }
            if !row.sourceIds.isEmpty {
                row.sourceIds = row.sourceIds.map { $0 + glue }
                report.sourceListsReidentified += 1
            }
        }
        try context.save()
        Phase0.say("scaled corpus: \(report.copiedShows) copied shows and \(report.copiedSources) copied sources; "
                   + "keys recomputed on \(report.keysRecomputed), left appended on \(report.keysAppendedAsDrifted) "
                   + "drifted and \(report.keysAppendedAsTaken) taken; run listings re-identified on "
                   + "\(report.runListingsReidentified), source lists on \(report.sourceListsReidentified)")
        return out
    }

    /// Copies every show, contact and (in the current era) source `factor - 1` times through SQL, and returns
    /// which copy each copied show belongs to, by its final natural key.
    private nonisolated static func copyRows(in out: URL, factor: Int, era: Era,
                                             report: inout Report) throws -> [String: Int] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(out.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw Failure.sql("open failed")
        }
        defer { sqlite3_close(db) }
        func columns(_ table: String) throws -> [String] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
                throw Failure.sql("table_info \(table)")
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
                throw Failure.sql(message)
            }
        }
        func text(_ stmt: OpaquePointer?, _ column: Int32) -> String? {
            sqlite3_column_text(stmt, column).map { String(cString: $0) }
        }
        let current = era == .current
        let offset = 100_000
        // The NAMES a person reads (title, presenter, room), and in the current era they take the glue in FRONT
        // of their first word (see `gluedName`); before #4427 they took it on the end of their last.
        let showNames: Set<String> = ["ZPRESENTER", "ZVENUE", "ZGROUPNAME", "ZSCOUTGROUPNAME", "ZSCOUTVENUE"]
        let showPrefixed: Set<String> = current ? showNames : []
        let showSuffixed = Set(["ZNATURALKEY", "ZSERIESID", "ZGMAILTHREADID", "ZGMAILMESSAGEID"]
                               + (current ? ["ZSOURCELISTINGURL"] : Array(showNames)))
        let contactPrefixed: Set<String> = ["ZEMAIL", "ZID"]
        let contactSuffixed: Set<String> = ["ZGMAILTHREADID", "ZGMAILMESSAGEID", "ZSENDGROUPID"]
        // A source's identity: its id, its name, and every address or room the landing reads from it. Its names
        // are glued as a show's are, its id and addresses on the end.
        let sourcePrefixed: Set<String> = ["ZORGNAME", "ZVENUENAME"]
        let sourceSuffixed: Set<String> = ["ZSOURCEID", "ZLISTINGSURL", "ZTICKETINGFEEDURL"]
        let showCols = try columns("ZPROSPECT")
        let contactCols = try columns("ZRECIPIENT")
        let sourceCols = current ? try columns("ZWATCHEDSOURCE") : []

        // The originals' keys and the values the app computes a key from, read before anything is copied.
        struct Original { let pk: Int64; let key: String; let anchoredTitle: String; let date: String?; let anchoredVenue: String? }
        var originals: [Original] = []
        do {
            var stmt: OpaquePointer?
            let sql = "SELECT Z_PK, ZNATURALKEY, COALESCE(ZSCOUTGROUPNAME, ZGROUPNAME), ZPERFORMANCEDATE, "
                + "COALESCE(ZSCOUTVENUE, ZVENUE) FROM ZPROSPECT WHERE Z_PK < \(offset)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failure.sql("read originals") }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let key = text(stmt, 1) ?? ""
                originals.append(Original(pk: sqlite3_column_int64(stmt, 0), key: key,
                                          anchoredTitle: text(stmt, 2) ?? "", date: text(stmt, 3),
                                          anchoredVenue: text(stmt, 4)))
            }
        }

        try exec("BEGIN")
        for k in 1..<factor {
            let shift = k * offset
            // GLUED onto a word, never a new word: a shared " x1" word would put every copied name into one
            // bucket of any word-indexed term (`ProducerGate.VenueKeyIndex`), which made the first reading of
            // this corpus superlinear for a reason no real store has. Glued, names share words within a copy
            // exactly as they do in the clone. Which word is `gluedName`'s reason.
            let glue = Phase0.glue(forCopy: k)
            let showExprs = showCols.map { c -> String in
                if c == "Z_PK" { return "Z_PK + \(shift)" }
                if showPrefixed.contains(c) { return "'\(glue)' || \(c)" }
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
            report.copiedShows += originals.count
            guard current else { continue }
            let sourceExprs = sourceCols.map { c -> String in
                if c == "Z_PK" { return "Z_PK + \(shift)" }
                if sourcePrefixed.contains(c) { return "'\(glue)' || \(c)" }
                if sourceSuffixed.contains(c) { return "\(c) || '\(glue)'" }
                return c
            }
            try exec("INSERT INTO ZWATCHEDSOURCE (\(sourceCols.joined(separator: ","))) SELECT "
                     + "\(sourceExprs.joined(separator: ",")) FROM ZWATCHEDSOURCE WHERE Z_PK < \(offset)")
            report.copiedSources += Int(sqlite3_changes(db))
        }
        if current {
            var update: OpaquePointer?
            guard sqlite3_prepare_v2(db, "UPDATE ZPROSPECT SET ZNATURALKEY = ? WHERE Z_PK = ?", -1, &update,
                                     nil) == SQLITE_OK else { throw Failure.sql("prepare key update") }
            defer { sqlite3_finalize(update) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let decisions = keyDecisions(originals.map { KeySource(key: $0.key, anchoredTitle: $0.anchoredTitle,
                                                                   date: $0.date, anchoredVenue: $0.anchoredVenue) },
                                         factor: factor)
            for (k, row, decision) in decisions {
                switch decision.kind {
                case .recomputed: report.keysRecomputed += 1
                case .drifted: report.keysAppendedAsDrifted += 1
                case .taken: report.keysAppendedAsTaken += 1
                }
                guard decision.kind == .recomputed else { continue }
                sqlite3_reset(update)
                sqlite3_bind_text(update, 1, decision.key, -1, transient)
                sqlite3_bind_int64(update, 2, originals[row].pk + Int64(k * offset))
                guard sqlite3_step(update) == SQLITE_DONE else { throw Failure.sql("key update") }
            }
            try exec("UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT MAX(Z_PK) FROM ZWATCHEDSOURCE) WHERE Z_NAME = 'WatchedSource'")
        }
        try exec("UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT MAX(Z_PK) FROM ZPROSPECT) WHERE Z_NAME = 'Prospect'")
        try exec("UPDATE Z_PRIMARYKEY SET Z_MAX = (SELECT MAX(Z_PK) FROM ZRECIPIENT) WHERE Z_NAME = 'Recipient'")
        try exec("COMMIT")

        var copyOf: [String: Int] = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT ZNATURALKEY, Z_PK / \(offset) FROM ZPROSPECT WHERE Z_PK >= \(offset)",
                                 -1, &stmt, nil) == SQLITE_OK else { throw Failure.sql("copied keys") }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let key = text(stmt, 0) { copyOf[key] = Int(sqlite3_column_int64(stmt, 1)) }
        }
        return copyOf
    }

    /// What a key is computed from: the original's key, and the title, date and room the app keys it by.
    struct KeySource: Equatable, Sendable {
        let key: String
        let anchoredTitle: String
        let date: String?
        let anchoredVenue: String?
    }

    /// Every copy's key, as (copy number, original's index, decision). Every copy already sits in the table
    /// under its appended key when these are written, so a recomputed key is judged against those too, not only
    /// against the originals and the keys decided so far: one equal to a later copy's appended key would hit the
    /// unique key on that copy's update.
    nonisolated static func keyDecisions(_ originals: [KeySource], factor: Int) -> [(Int, Int, KeyDecision)] {
        var taken = Set(originals.map(\.key))
        for k in 1..<max(factor, 1) {
            let glue = Phase0.glue(forCopy: k)
            for row in originals { taken.insert(row.key + glue) }
        }
        var out: [(Int, Int, KeyDecision)] = []
        for k in 1..<max(factor, 1) {
            let glue = Phase0.glue(forCopy: k)
            for (i, row) in originals.enumerated() {
                let decision = copyKey(key: row.key, anchoredTitle: row.anchoredTitle, date: row.date,
                                       anchoredVenue: row.anchoredVenue, glue: glue, taken: taken)
                taken.insert(decision.key)
                out.append((k, i, decision))
            }
        }
        return out
    }

    struct KeyDecision: Equatable {
        enum Kind: Equatable { case recomputed, drifted, taken }
        let key: String
        let kind: Kind
    }

    /// The key copy `glue` of a show gets. The one the app computes over the copy's glued title and venue when
    /// the original's key is the one the app computes over its own (so the copy's glued event arrives with it),
    /// and otherwise the original's key with the glue appended, which is also the answer when the computed key
    /// is already held, since a unique key must never be written twice.
    nonisolated static func copyKey(key: String, anchoredTitle: String, date: String?, anchoredVenue: String?,
                                    glue: String, taken: Set<String>) -> KeyDecision {
        let appended = key + glue
        guard Prospect.makeNaturalKey(groupName: anchoredTitle, performanceDate: date, venue: anchoredVenue) == key
        else { return KeyDecision(key: appended, kind: .drifted) }
        let computed = Prospect.makeNaturalKey(groupName: gluedName(anchoredTitle, glue: glue), performanceDate: date,
                                               venue: anchoredVenue.map { gluedName($0, glue: glue) })
        guard !taken.contains(computed) else { return KeyDecision(key: appended, kind: .taken) }
        return KeyDecision(key: computed, kind: .recomputed)
    }

    // MARK: the results

    /// The scout results a store `factor` times the size would land: every result once for the clone and once
    /// per copy, under the copy's source id, with every event glued as the copy's stored rows are. Factor 1 is
    /// the results unchanged.
    nonisolated static func results(_ results: ScoutExtractResults, factor: Int) -> ScoutExtractResults {
        var scaled = results
        for k in 1..<max(factor, 1) {
            let glue = Phase0.glue(forCopy: k)
            scaled.results += results.results.map { result in
                var copy = result
                copy.sourceId = result.sourceId + glue
                copy.events = result.events.map { glued($0, glue: glue) }
                return copy
            }
        }
        return scaled
    }

    /// One event as copy `glue`'s source would publish it: every field the corpus glues on a stored show
    /// (title, presenter, venue, series, listing address) glued the same way, and nothing else.
    /// A name as copy `glue` holds it: the glue in FRONT of the first word ("Winter Light" becomes "qaWinter
    /// Light"). In front because the landing relates names by their beginnings: a title that is a prefix of
    /// another is the same show with a subtitle (`GroupNameMatch`, the Fenwick triple), a room's key drops
    /// everything after its first comma (`VenueNormalization.keyName`), and a street suffix is folded on the
    /// last word. Glued on the end (as before #4427) "Winter Lightqa" is no prefix of "Winter Light
    /// Vespersqa" and "Weill Recital Hall, Carnegie Hallqa" keys to the ORIGINAL's room, so a copy's events
    /// landed differently from its original's, which `ScaledCorpusLandsLikeALargerStoreTests` measured.
    nonisolated static func gluedName(_ name: String, glue: String) -> String { glue + name }

    nonisolated static func glued(_ event: ScoutExtractEvent, glue: String) -> ScoutExtractEvent {
        var e = event
        e.title = gluedName(event.title, glue: glue)
        e.presenter = event.presenter.map { gluedName($0, glue: glue) }
        e.venue = event.venue.map { gluedName($0, glue: glue) }
        e.seriesId = event.seriesId.map { $0 + glue }
        e.sourceUrl = event.sourceUrl.map { $0.isEmpty ? $0 : $0 + glue }
        return e
    }
}
