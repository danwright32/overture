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
            guard let observed = type as? any ScopeObserved.Type else { continue }
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
        return try context.fetch(FetchDescriptor<M>()).map { model in
            var fields: [Field] = []
            for field in M.scopeFields {
                let name = ScoutReLandWritesNothingTests.fieldName(field.keyPath)
                guard clockDerived["\(entity).\(name)"] == nil else { continue }
                fields.append(Field(name: name, value: render(model[keyPath: field.keyPath])))
            }
            return Row(entity: entity, fields: fields.sorted { $0.name < $1.name })
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
        case let models as [any PersistentModel]:
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
    static func short(_ fullHash: String) -> String { "sha256:" + fullHash.prefix(12) }

    // MARK: the two file forms

    /// One line per field. The synthetic arm writes the VALUE, the real arm the value's HASH, so a real-arm
    /// file never holds a title, a venue or a presenter even on this Mac.
    enum Form { case values, hashes }

    static func lines(of snapshot: Snapshot, form: Form) -> [String] {
        var out: [String] = []
        for entity in snapshot.counts.keys.sorted() {
            out.append("count\t\(entity)\t\(snapshot.counts[entity] ?? 0)")
        }
        var position: [String: Int] = [:]
        for row in snapshot.rows {
            let index = position[row.entity, default: 0]
            position[row.entity] = index + 1
            for field in row.fields {
                let cell = form == .values ? escape(field.value) : "sha256:" + hash(field.value)
                out.append("\(row.entity)\t\(index)\t\(field.name)\t\(cell)")
            }
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
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#") || line == realArmMarker { continue }
            let parts = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
            if parts.count == 3, parts[0] == "count" {
                r.counts[parts[1]] = Int(parts[2]) ?? -1
                continue
            }
            guard parts.count == 4, let index = Int(parts[1]) else { continue }
            let (entity, field, cell) = (parts[0], parts[2], parts[3])
            var rows = r.hashes[entity] ?? []
            while rows.count <= index { rows.append([:]) }
            if cell.hasPrefix("sha256:") {
                rows[index][field] = String(cell.dropFirst("sha256:".count))
            } else {
                let value = unescape(cell)
                rows[index][field] = hash(value)
                var shown = r.values[entity] ?? []
                while shown.count <= index { shown.append([:]) }
                shown[index][field] = value
                r.values[entity] = shown
            }
            r.hashes[entity] = rows
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
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return "REFUSED: could not run \(git) to ask whether \(directory.path) is inside a git work tree, "
                + "so a real-arm file is not written there (\(error))"
        }
        process.waitUntilExit()
        let said = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if said == "true" {
            return "REFUSED: \(directory.path) is inside a git work tree, and a real-arm file holds real "
                + "data that must never be committed. Name a directory outside every checkout."
        }
        return nil
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
