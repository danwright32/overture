import Foundation
import CryptoKit
import SwiftData

// #4328 (step A1 of the scout landing plan, discussion #4326): a snapshot oracle of what one scout landing
// leaves in the store, recorded from main 6d3453d8 so every later change to the landing (A4's incremental
// working set, A6's moved save, #4325's saved reconcile) has to answer "is the store still EQUAL?".
// A step toward #4275: it changes no product code and the 100 ms bar is not met until Phase E says so.
//
// TWO ARMS, deliberately different in what they may hold.
//
//   synthetic   about sixty INVENTED shows over six sources (`LandingOracleCorpus`), landed in memory. Its
//               expected snapshot is committed, with values, so a failure can say what changed.
//   real        the recorded scout extract results landed on the FROZEN 1x and 4x inputs (#4327 step 0.0),
//               never committed (L222, L155). Its snapshot file holds a HASH per field, never a value, and
//               its first line is the marker the push path refuses (`scripts/lib/real-arm-guard.sh`).
//
// WHICH VIEW THE SNAPSHOT READS (L84). The landing's context is saved ONCE, explicitly, after `ingest`
// returns, and the snapshot is then read through a FRESH `ModelContext` on the same container. So it records
// the state 6d3453d8 INTENDS autosave to reach: every source's per-source save, the last source's post-save
// health writes and ingest's final FeedReconcile writes (#4325), which today only an autosave would carry.
// Autosave is OFF on the landing context, so nothing reaches the store except through that one save. A6
// (moving the save) and #4325 (saving the reconcile) must leave this oracle EQUAL; A5's deliberate saveFailed
// fix changes what a FAILED save leaves and is pinned by its own expected-changes test, not by this.
//
// WHAT IT EXCLUDES, and why (L252). 6d3453d8 has no clock seam inside `apply`: a row's `ingestedAt` is
// `Date()` (ScoutService.swift:2631), a new row's `firstSeenAt` copies it (Prospect.swift:1136), and
// FeedReconcile stamps `mergeSurvivorUnseenAt` from its own defaulted `Date()` (FeedReconcile.swift:261).
// Those can never repeat, so they are left out of the snapshot entirely, as are the source health stamps the
// plan names. `clockDerived` is the list, each with its reason, and
// `LandingOracleTests.everyFieldThatDiffersBetweenTwoLandingsIsAClockField` DERIVES it: it lands the same
// inputs twice and fails on any field that differed and is not listed. They are pinned later, in an
// expected-changes fixture written once the clock seam exists.
//
// A MISMATCH IN THE REAL ARM NEVER PRINTS A VALUE (L445). It names the entity, the row's position in the
// snapshot, the field and the two hashes. Only the synthetic arm prints values, which is why every
// seen-to-fail text in a pull request comes from the synthetic arm.
enum LandingOracle {

    // The line that marks a real-arm file, built from two halves so no file in the repository holds a line
    // that IS the marker (L245, L673): not this one, not the guard, not the guard's fixture.
    static let realArmMarker = "OVERTURE-REAL-ARM" + ": never commit"

    // Every field a landing stamps from a clock 6d3453d8 cannot pin, keyed "Entity.field", with its reason.
    static let clockDerived: [String: String] = [
        "Prospect.ingestedAt":
            "apply stamps Date() on every row it touches (ScoutService.swift:2631) and on every insert (the "
            + "Prospect initialiser's default)",
        "Prospect.firstSeenAt":
            "a new row copies its ingestedAt (Prospect.swift:1136), so it is the same Date()",
        "Prospect.mergeSurvivorUnseenAt":
            "FeedReconcile.answerAnyMergeSurvivorQuestion stamps the reconcile's now, which ingest leaves at its "
            + "Date() default (FeedReconcile.swift:261)",
        "WatchedSource.lastCheckedAt":
            "a health stamp the plan pins later with the clock seam; ingest writes it from its now",
        "WatchedSource.lastSucceededAt":
            "a health stamp the plan pins later with the clock seam; recordSuccessfulRead writes it from now",
        "WatchedSource.lastNonEmptyAt":
            "a health stamp the plan pins later with the clock seam; recordSuccessfulRead writes it from now",
        // Not a clock, but excluded for the same reason: it cannot repeat across two landings.
        "WatchedSource.lastTouchedSequence":
            "#4330's landing sequence, minted per run above every earlier mint in the process, so two "
            + "landings of the same inputs differ by construction; 6d3453d8 has no such field",
        // #4335: which run landed the source, the same kind of fact as the sequence above.
        "WatchedSource.lastLandedSequence":
            "#4335's landing sequence of the run that landed the source, minted per run like "
            + "lastTouchedSequence; 6d3453d8 has no such field",
        "WatchedSource.lastLandedRunID":
            "#4335's run identity, a sweep id minted per run (or, for decoded results with no file, an id of "
            + "their own), so it cannot repeat; 6d3453d8 has no such field",
    ]

    // Whole models the oracle does not record, keyed by name, with the reason. Only a model that is a record
    // OF the landing rather than data it lands belongs here, and only while 6d3453d8's recording, which
    // predates it, is the oracle.
    static let recordsOfTheLanding: [String: String] = [
        "LandingRun":
            "#4335's record of each landing (its identity, sequence and start), one row per run, so two landings "
            + "of the same inputs leave two different rows; 6d3453d8 has no such model",
    ]

    // MARK: the snapshot

    struct Field: Equatable {
        let name: String
        let value: String
    }

    struct Row: Equatable {
        let entity: String
        let fields: [Field]
        var identity: String {
            fields.first { $0.name == "naturalKey" || $0.name == "sourceId" }?.value ?? ""
        }
        var canonical: String { fields.map { "\($0.name)=\($0.value)" }.joined(separator: "\u{1F}") }
    }

    /// Every row of every model in the schema, clock fields dropped, rows in a stable order: by entity, then by
    /// the row's own identity (a show's natural key, a source's id), then by everything else it holds.
    struct Snapshot: Equatable {
        var rows: [Row]

        var counts: [String: Int] { rows.reduce(into: [:]) { $0[$1.entity, default: 0] += 1 } }

        func rows(of entity: String) -> [Row] { rows.filter { $0.entity == entity } }
    }

    /// Reads `container` through a FRESH context, so the snapshot is what was SAVED, never what one context
    /// is still holding.
    @MainActor
    static func snapshot(of container: ModelContainer) throws -> Snapshot {
        let fresh = ModelContext(container)
        var rows: [Row] = []
        for type in AppSchema.models {
            // Every model is ScopeObserved (ScopeFieldsMatchTheSchemaTests), so nothing is skipped here today;
            // `everyModelInTheSchemaIsSnapshotted` fails the day one is not, rather than this reading EQUAL
            // over a model it never looked at (L96).
            guard let observed = type as? any ScopeObserved.Type else { continue }
            guard recordsOfTheLanding[String(describing: type)] == nil else { continue }
            rows += try snapshotRows(observed, in: fresh)
        }
        rows.sort {
            if $0.entity != $1.entity { return $0.entity < $1.entity }
            if $0.identity != $1.identity { return $0.identity < $1.identity }
            return $0.canonical < $1.canonical
        }
        return Snapshot(rows: rows)
    }

    @MainActor
    private static func snapshotRows<M: ScopeObserved>(_ type: M.Type, in context: ModelContext) throws -> [Row] {
        let entity = String(describing: M.self)
        // The names ONCE per model, never per row: a key path's name is found by a symbol lookup in dyld, and
        // doing it per row per field was nearly all of a 4x recording's time (sampled, 1,445 of 1,458 samples).
        let named = M.scopeFields
            .map { (name: ScoutReLandWritesNothingTests.fieldName($0.keyPath), keyPath: $0.keyPath) }
            .filter { clockDerived["\(entity).\($0.name)"] == nil }
            .sorted { $0.name < $1.name }
        return try context.fetch(FetchDescriptor<M>()).map { model in
            Row(entity: entity, fields: named.map { Field(name: $0.name, value: render(model[keyPath: $0.keyPath])) })
        }
    }

    /// One value as text that repeats exactly across runs and processes.
    ///
    /// A Date at full precision rather than `String(describing:)`, which prints whole seconds: two landings
    /// in the same second would then read alike and hide a clock stamp from the test that derives the clock
    /// list. A relationship is rendered by what it points AT (a show's natural key, a count of rows), never by
    /// the object, whose description is an address. An unordered collection is sorted, because its order is
    /// the hash seed's, not the data's.
    static func render(_ any: Any?) -> String {
        guard let value = unwrap(any) else { return "nil" }
        switch value {
        case let date as Date:
            return String(format: "date:%.6f", date.timeIntervalSinceReferenceDate)
        case let data as Data:
            return "data:" + hex(SHA256.hash(data: data))
        case let prospect as Prospect:
            return "Prospect(" + prospect.naturalKey + ")"
        case let model as any PersistentModel:
            return String(describing: type(of: model)) + "(related)"
        // Only a NON-EMPTY array: an empty `[String]` also casts to `[any PersistentModel]`, because a cast of an
        // empty array has no element to refuse, and rendered an empty `sourceIds` as "0 related" (seen in the
        // first seen-to-fail text of #4328). An empty list of either kind renders "[]", which is unambiguous
        // because each field only ever holds one kind.
        case let models as [any PersistentModel] where !models.isEmpty:
            return "\(models.count) related"
        case let set as Set<String>:
            return String(describing: set.sorted())
        default:
            return String(describing: value)
        }
    }

    private static func unwrap(_ any: Any?) -> Any? {
        guard let any else { return nil }
        let mirror = Mirror(reflecting: any)
        guard mirror.displayStyle == .optional else { return any }
        guard let child = mirror.children.first else { return nil }
        return unwrap(child.value)
    }

    // MARK: hashing

    static func hash(_ text: String) -> String { hex(SHA256.hash(data: Data(text.utf8))) }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The short form a mismatch prints: enough to tell two hashes apart, too short to be a lookup key.
    static func short(_ cellHash: String) -> String { "sha256:" + cellHash.prefix(12) }

    // MARK: the two file forms

    /// One line per ROW, under one `fields` line per entity naming the columns: a line per field made the
    /// committed synthetic file 300 KB, too large for anybody to review. The synthetic arm writes each VALUE
    /// (`=` then the escaped text), the real arm each value's HASH (`h` then the first 16 hex digits of its
    /// sha256), so a real-arm file never holds a title, a venue or a presenter even on this Mac.
    enum Form { case values, hashes }

    static func cellHash(_ value: String) -> String { String(hash(value).prefix(16)) }

    static func lines(of snapshot: Snapshot, form: Form) -> [String] {
        var out: [String] = []
        for entity in snapshot.counts.keys.sorted() {
            out.append("count\t\(entity)\t\(snapshot.counts[entity] ?? 0)")
        }
        var position: [String: Int] = [:]
        var named = Set<String>()
        for row in snapshot.rows {
            if named.insert(row.entity).inserted {
                out.append((["fields", row.entity] + row.fields.map(\.name)).joined(separator: "\t"))
            }
            let index = position[row.entity, default: 0]
            position[row.entity] = index + 1
            let cells = row.fields.map { form == .values ? "=" + escape($0.value) : "h" + cellHash($0.value) }
            out.append((["row", row.entity, String(index)] + cells).joined(separator: "\t"))
        }
        return out
    }

    /// The digest #4275 is given for a real-arm recording: the hash of its hashed lines, so two recordings
    /// can be compared without either leaving this Mac.
    static func digest(of snapshot: Snapshot) -> String {
        hash(lines(of: snapshot, form: .hashes).joined(separator: "\n"))
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var escaping = false
        for c in s {
            if escaping {
                switch c {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                default: out.append(c)
                }
                escaping = false
            } else if c == "\\" {
                escaping = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// The text of a real-arm recording: the marker FIRST, alone on its line, then a header, then the
    /// hashed lines.
    static func realArmFile(_ snapshot: Snapshot, header: [String]) -> String {
        ([realArmMarker] + header.map { "# " + $0 } + ["# digest " + digest(of: snapshot)]
            + lines(of: snapshot, form: .hashes)).joined(separator: "\n") + "\n"
    }

    static func syntheticFile(_ snapshot: Snapshot, header: [String]) -> String {
        (header.map { "# " + $0 } + lines(of: snapshot, form: .values)).joined(separator: "\n") + "\n"
    }

    // MARK: reading a recording back

    /// A recorded snapshot as the comparison needs it: counts per entity and, per entity, each row's fields
    /// as HASHES. A values file is hashed on the way in, so both arms are compared the same way; only the
    /// synthetic arm also keeps the values, to print.
    struct Recording {
        var counts: [String: Int] = [:]
        var hashes: [String: [[String: String]]] = [:]
        var values: [String: [[String: String]]] = [:]
    }

    static func parse(_ text: String) -> Recording {
        var r = Recording()
        var columns: [String: [String]] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") || line == realArmMarker { continue }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            switch parts.first ?? "" {
            case "count" where parts.count == 3:
                r.counts[parts[1]] = Int(parts[2]) ?? -1
            case "fields" where parts.count >= 2:
                columns[parts[1]] = Array(parts.dropFirst(2))
            case "row" where parts.count >= 3:
                guard let index = Int(parts[2]), let names = columns[parts[1]] else { continue }
                let entity = parts[1]
                // Mutated in place through the dictionary, never copied out and back: a 4x recording has
                // thousands of rows, and a copy per row is quadratic.
                if r.hashes[entity] == nil { r.hashes[entity] = [] }
                while r.hashes[entity]!.count <= index { r.hashes[entity]!.append([:]) }
                for (name, cell) in zip(names, parts.dropFirst(3)) {
                    if cell.hasPrefix("h") {
                        r.hashes[entity]![index][name] = String(cell.dropFirst())
                    } else {
                        let value = unescape(String(cell.dropFirst()))
                        r.hashes[entity]![index][name] = cellHash(value)
                        if r.values[entity] == nil { r.values[entity] = [] }
                        while r.values[entity]!.count <= index { r.values[entity]!.append([:]) }
                        r.values[entity]![index][name] = value
                    }
                }
            default:
                continue
            }
        }
        return r
    }

    static func recording(of snapshot: Snapshot) -> Recording {
        parse(lines(of: snapshot, form: .values).joined(separator: "\n"))
    }

    // MARK: comparing

    enum Arm { case synthetic, real }

    /// Every difference between what was recorded and what this landing left, as lines. Empty means EQUAL.
    ///
    /// Row by row, field by field, on HASHES. In the real arm a line names the entity, the row's position,
    /// the field and the two short hashes and nothing else (L445); in the synthetic arm it adds the two
    /// values. `limit` keeps a large drift readable: the count of what was not printed is always said.
    static func differences(expected: Recording, actual: Snapshot, arm: Arm, limit: Int = 25) -> [String] {
        let got = recording(of: actual)
        var out: [String] = []
        var total = 0
        func add(_ line: String) {
            total += 1
            if out.count < limit { out.append(line) }
        }
        for entity in Set(expected.counts.keys).union(got.counts.keys).sorted() {
            let want = expected.counts[entity] ?? 0
            let have = got.counts[entity] ?? 0
            if want != have { add("\(entity): expected \(want) rows, got \(have)") }
            let wantRows = expected.hashes[entity] ?? []
            let haveRows = got.hashes[entity] ?? []
            for index in 0..<min(wantRows.count, haveRows.count) {
                let names = Set(wantRows[index].keys).union(haveRows[index].keys).sorted()
                for name in names where wantRows[index][name] != haveRows[index][name] {
                    var line = "\(entity) row \(index) field \(name): expected "
                        + (wantRows[index][name].map(short) ?? "absent") + " got "
                        + (haveRows[index][name].map(short) ?? "absent")
                    if arm == .synthetic {
                        let was = expected.values[entity].flatMap { index < $0.count ? $0[index][name] : nil }
                        let now = got.values[entity].flatMap { index < $0.count ? $0[index][name] : nil }
                        line += " (\(was.map { "\"\($0)\"" } ?? "absent") then \(now.map { "\"\($0)\"" } ?? "absent"))"
                    }
                    add(line)
                }
            }
        }
        if total > out.count { out.append("and \(total - out.count) more differences not printed") }
        return out
    }

    // MARK: where a real-arm file may be written

    /// Why `directory` must not receive a real-arm file, or nil when it may. It refuses anywhere inside a git
    /// work tree, and refuses when it cannot tell, because a real-arm file inside a checkout is one `git add`
    /// from a public repository (L42). `git` is a parameter so the refusal can be driven without one.
    static func refusalToWrite(into directory: URL, git: String = "/usr/bin/git") -> String? {
        var probe = directory.standardizedFileURL
        while !FileManager.default.fileExists(atPath: probe.path), probe.path != "/" {
            probe = probe.deletingLastPathComponent()
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", probe.path, "rev-parse", "--is-inside-work-tree"]
        let pipe = Pipe()
        let errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return "REFUSED: could not run \(git) to ask whether \(directory.path) is inside a git work tree, "
                + "so a real-arm file is not written there (\(error))"
        }
        let said = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let complained = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        if said == "true" {
            return "REFUSED: \(directory.path) is inside a git work tree, and a real-arm file holds real "
                + "data that must never be committed. Name a directory outside every checkout."
        }
        // The ONE answer that allows the write is git saying it is in no repository at all. Anything else (it
        // answered "false", which it does inside a .git directory; it refused over ownership; it failed some
        // other way) is a question it did not answer, and that refuses (L42, L490).
        if process.terminationStatus != 0, complained.contains("not a git repository") {
            return nil
        }
        return "REFUSED: \(git) did not say \(directory.path) is outside every git work tree (exit "
            + "\(process.terminationStatus), answered \"\(said ?? "")\"), so a real-arm file is not written there"
    }

    // MARK: the frozen inputs (#4327 step 0.0)

    /// The archive's manifest: `sha256  <file>` lines, as `shasum -a 256` writes them, plus `key: value` facts.
    struct Manifest {
        var sha256: [String: String] = [:]
        var facts: [String: String] = [:]
    }

    static func manifest(at url: URL) -> Manifest? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var m = Manifest()
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#") { continue }
            if let colon = line.range(of: ": "), !line.hasPrefix(" ") {
                let key = String(line[line.startIndex..<colon.lowerBound])
                if !key.contains(" ") {
                    m.facts[key] = String(line[colon.upperBound...])
                    continue
                }
            }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].count == 64 else { continue }
            m.sha256[parts[1].trimmingCharacters(in: .whitespaces)] = parts[0]
        }
        return m
    }

    /// Nil when every file the manifest names hashes to what it recorded, or the reading
    /// `UNMEASURED: inputs differ from the oracle's (<file>)` naming the first that does not.
    static func inputsRefusal(archive: URL, manifest: Manifest) -> String? {
        guard !manifest.sha256.isEmpty else {
            return "UNMEASURED: the frozen inputs' manifest names no files, so nothing could be checked"
        }
        for name in manifest.sha256.keys.sorted() {
            guard let data = try? Data(contentsOf: archive.appendingPathComponent(name)) else {
                return "UNMEASURED: inputs differ from the oracle's (\(name): unreadable)"
            }
            if hex(SHA256.hash(data: data)) != manifest.sha256[name] {
                return "UNMEASURED: inputs differ from the oracle's (\(name))"
            }
        }
        return nil
    }
}
