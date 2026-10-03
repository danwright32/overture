import Testing
import Foundation
import SwiftData

// #4372: WHY probe 0b.6 saw 1,167 per row trackers fire against 273 rows whose values changed, on the 4x corpus.
//
// MEASUREMENT ONLY, and the same contract as the Phase 0b probes it explains (`QueueEnginePhase0bProbeTests`):
// it reads a throwaway `LiveStoreClone` copy and the fourfold corpus `Phase0.scaledCopy` builds from it, never the
// live store, and lands a COPY of the scout results file on them. Opt in, and says it did not run otherwise (L98):
//
//   TEST_RUNNER_MEASURE_4372=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/ScoutLandingTrackerAttributionProbeTests
//
// What 0b.6 could not say, because it armed ONE tracker per row: which FIELD fired, whether that field's value
// moved, and which code wrote it. This arms one tracker per row per stored field (and per contact field, charged
// to the contact's show), snapshots every field's value before and after the landing, and records the return
// addresses of every fire, so each fire is attributed to the writer that made it.
//
// PRIVACY. Counts, field names and function names only: never a show name, a venue, an address or a URL (L222).

// The Swift runtime's own demangler, so a writer is printed as a function name rather than a mangled symbol.
@_silgen_name("swift_demangle")
private func trackerAttributionDemangle(_ name: UnsafePointer<CChar>?, _ length: UInt,
                                        _ out: UnsafeMutablePointer<CChar>?,
                                        _ outSize: UnsafeMutablePointer<UInt>?,
                                        _ flags: UInt32) -> UnsafeMutablePointer<CChar>?

enum TrackerAttribution {
    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["MEASURE_4372"] != nil }
    // Flushed, because a test's stdout is a pipe and buffers, so a long probe would otherwise say nothing
    // until it ended.
    nonisolated static func say(_ line: String) {
        print("tracker4372 " + line)
        fflush(stdout)
    }

    /// One stored field of a show or of one of its contacts, named for the report.
    struct Slot: Hashable { let row: Int; let field: String; let contact: String? }

    /// Every fire, keyed by the slot that fired, with the stack it fired from. Written from observation's
    /// `onChange`, which runs on whatever thread made the change, so it is lock protected.
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var fires: [Slot: [UInt]] = [:]
        private var offMain = 0
        private var phase = "read phase and the first source's landing"
        private var phaseOf: [Slot: String] = [:]

        func record(_ slot: Slot) {
            let stack = Thread.callStackReturnAddresses.prefix(64).map { $0.uintValue }
            let main = Thread.isMainThread
            lock.lock(); defer { lock.unlock() }
            fires[slot] = Array(stack)
            phaseOf[slot] = phase
            if !main { offMain += 1 }
        }

        func enter(_ name: String) { lock.lock(); phase = name; lock.unlock() }

        var snapshot: (fires: [Slot: [UInt]], phases: [Slot: String], offMain: Int) {
            lock.lock(); defer { lock.unlock() }
            return (fires, phaseOf, offMain)
        }
    }

    /// A field's value as text, or a relationship's membership by identity, so a refetch of an unchanged
    /// relationship compares equal.
    static func value(_ p: Prospect, _ field: ScopeField<Prospect>) -> String {
        if field.keyPath == \Prospect.recipients as AnyKeyPath {
            return p.recipients.map { "\($0.persistentModelID.hashValue)" }.sorted().joined(separator: ",")
        }
        return String(describing: p[keyPath: field.keyPath] ?? "nil")
    }

    static func value(_ r: Recipient, _ field: ScopeField<Recipient>) -> String {
        if field.keyPath == \Recipient.prospect as AnyKeyPath {
            return r.prospect.map { "\($0.persistentModelID.hashValue)" } ?? "nil"
        }
        return String(describing: r[keyPath: field.keyPath] ?? "nil")
    }

    static func name(_ keyPath: AnyKeyPath) -> String {
        let text = String(describing: keyPath)
        return text.split(separator: ".").last.map(String.init) ?? text
    }

    // Named ONCE: describing a key path looks its symbol up through dladdr, which at one call per row per
    // field took the first reading past the runner's 20 minute stall limit before it printed anything.
    static let showFieldNames = Prospect.scopeFields.map { name($0.keyPath) }
    static let contactFieldNames = Recipient.scopeFields.map { "Recipient." + name($0.keyPath) }

    /// Every slot's value, for one show and its contacts.
    static func values(_ rows: [Prospect]) -> [Slot: String] {
        var out: [Slot: String] = [:]
        for (i, p) in rows.enumerated() {
            for (n, f) in Prospect.scopeFields.enumerated() {
                out[Slot(row: i, field: showFieldNames[n], contact: nil)] = value(p, f)
            }
            for r in p.recipients {
                let c = "\(r.persistentModelID.hashValue)"
                for (n, f) in Recipient.scopeFields.enumerated() {
                    out[Slot(row: i, field: contactFieldNames[n], contact: c)] = value(r, f)
                }
            }
        }
        return out
    }

    /// One tracker per slot, armed through the model's own `access`, exactly as `ScopeField.arm` arms one.
    @MainActor
    static func arm(_ rows: [Prospect], log: Log) -> Int {
        var armed = 0
        for (i, p) in rows.enumerated() {
            for (n, f) in Prospect.scopeFields.enumerated() {
                let slot = Slot(row: i, field: showFieldNames[n], contact: nil)
                withObservationTracking { f.arm(p) } onChange: { log.record(slot) }
                armed += 1
            }
            for r in p.recipients {
                let c = "\(r.persistentModelID.hashValue)"
                for (n, f) in Recipient.scopeFields.enumerated() {
                    let slot = Slot(row: i, field: contactFieldNames[n], contact: c)
                    withObservationTracking { f.arm(r) } onChange: { log.record(slot) }
                    armed += 1
                }
            }
        }
        return armed
    }

    // MARK: - Why a row was restamped (#4481)

    /// For the rows whose `ingestedAt` moved, which of `MergeCandidateIndex`'s twin keys another row shares with
    /// it (the #4331 rule restamps a row with a twin on every touch), and whether that twin is a row of ANOTHER
    /// corpus copy, which no real store has. Read from the landed rows with the index's own key function.
    @MainActor
    static func twinKinds(rows: [Prospect], copyRow: [Bool], restamped: Set<Int>) -> String {
        func copyOf(_ i: Int) -> Int {
            for k in 1..<4 {
                let g = Phase0.glue(forCopy: k)
                if rows[i].groupName.contains(g + g) || rows[i].groupName.hasSuffix(g) { return k }
            }
            return 0
        }
        let keys = rows.map { p in
            MergeCandidateIndex.keys(of: p, tokens: ([p.sourceListingURL].compactMap { $0 } + p.runSourceURLs)
                .compactMap(ProductionToken.inURL))
        }
        var byExact: [String: [Int]] = [:]
        var byNight: [String: [Int]] = [:]
        for (i, k) in keys.enumerated() {
            for e in k.exact { byExact[e, default: []].append(i) }
            if let n = k.night { byNight[n, default: []].append(i) }
        }
        var kinds: [String: (rows: Int, crossCopy: Int)] = [:]
        var none = 0
        for i in restamped.sorted() {
            var found: [String: Bool] = [:]
            for e in keys[i].exact {
                for j in byExact[e] ?? [] where j != i {
                    let kind = String(e.prefix { $0 != " " })
                    found[kind] = (found[kind] ?? false) || copyOf(j) != copyOf(i)
                }
            }
            if let n = keys[i].night {
                for j in byNight[n] ?? [] where j != i
                    && GroupNameMatch.isSameNightVariant(keys[i].title, keys[j].title) {
                    found["night"] = (found["night"] ?? false) || copyOf(j) != copyOf(i)
                }
            }
            if found.isEmpty { none += 1 }
            for (kind, cross) in found {
                var e = kinds[kind] ?? (0, 0)
                e.rows += 1
                if cross { e.crossCopy += 1 }
                kinds[kind] = e
            }
        }
        let parts = kinds.sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value.rows) (\($0.value.crossCopy) with a twin in another copy)" }
        return "restamped shows \(restamped.count) (\(restamped.filter { copyRow[$0] }.count) copies), by the twin key "
            + "that restamps them: \(parts.isEmpty ? "none" : parts.joined(separator: ", ")); no twin \(none)"
    }

    // MARK: - Naming the writer behind a stack

    // Only ever touched from the report, on the main actor.
    nonisolated(unsafe) private static var symbols: [UInt: String?] = [:]

    /// The function an address sits in, demangled, or nil when it is not in Overture's own code.
    static func function(at address: UInt) -> String? {
        if let known = symbols[address] { return known }
        var info = Dl_info()
        var answer: String?
        if dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let file = info.dli_fname,
           String(cString: file).contains("Overture"), let sym = info.dli_sname {
            let mangled = String(cString: sym)
            if let d = trackerAttributionDemangle(sym, UInt(strlen(sym)), nil, nil, 0) {
                answer = String(cString: d)
                free(d)
            } else {
                answer = mangled
            }
        }
        symbols[address] = answer
        return answer
    }

    /// The writer: the first frames of Overture's own code below the observation machinery and this probe,
    /// shortened to the function names alone.
    static func writer(_ stack: [UInt], depth: Int = 4) -> String {
        var frames: [String] = []
        for address in stack {
            guard let f = function(at: address) else { continue }
            if f.contains("TrackerAttribution") || f.contains("ScoutLandingTrackerAttributionProbeTests") { continue }
            let short = shorten(f)
            if frames.last == short { continue }
            frames.append(short)
            if frames.count == depth { break }
        }
        return frames.isEmpty ? "(no Overture frame)" : frames.joined(separator: " < ")
    }

    /// `Overture.ScoutService.apply(_:to:now:storedByKey:) -> ()` to `ScoutService.apply(_:to:now:storedByKey:)`.
    static func shorten(_ f: String) -> String {
        var s = f
        for prefix in ["merged ", "implicit closure #1 in ", "closure #1 in ", "closure #2 in "] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if let paren = s.firstIndex(of: "(") {
            let head = s[..<paren]
            let rest = s[paren...]
            // Keep the argument labels, drop the types.
            var labels = ""
            var depth = 0
            var token = ""
            for ch in rest {
                if ch == "(" { depth += 1; if depth == 1 { labels.append("("); continue } }
                if ch == ")" { depth -= 1; if depth == 0 { labels.append(")"); break } }
                if depth == 1 {
                    if ch == ":" { labels += token.trimmingCharacters(in: .whitespaces) + ":"; token = "" }
                    else if ch == "," { token = "" }
                    else { token.append(ch) }
                }
            }
            s = String(head) + labels
        }
        for module in ["OvertureTests.", "Overture."] where s.hasPrefix(module) { s = String(s.dropFirst(module.count)) }
        return s
    }
}

@MainActor
@Suite("#4372 the scout landing's tracker fires, attributed (opt in, live store clone)")
struct ScoutLandingTrackerAttributionProbeTests {

    private let sandboxes = TemporarySandboxes()

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func attributeTheTrackerFires() async throws {
        guard TrackerAttribution.enabled else {
            print("tracker4372: not measured. Set TEST_RUNNER_MEASURE_4372=1 to run it.")
            return
        }
        let live = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
            .appendingPathComponent("overture-scout-extract-results.json")
        let dir = try sandboxes.make(named: "tracker4372")
        let copy = dir.appendingPathComponent("results.json")
        try? FileManager.default.copyItem(at: live, to: copy)
        guard let data = try? Data(contentsOf: copy), let results = try? ScoutExtractResultsDecoder.decode(data) else {
            TrackerAttribution.say("UNMEASURED: no readable scout extract results on this machine")
            return
        }
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        // `MEASURE_4372_CLONE_ONLY` skips the fourfold corpus, for a quicker first reading.
        let cloneOnly = ProcessInfo.processInfo.environment["MEASURE_4372_CLONE_ONLY"] != nil
        // `MEASURE_4372_HISTORICAL_CORPUS` adds the fourfold corpus as it stood when 0b.6 read 1,167 fires
        // (before #4288, every copy sharing its original's listing addresses), in a directory of its own.
        let historical = ProcessInfo.processInfo.environment["MEASURE_4372_HISTORICAL_CORPUS"] != nil
        // #4427: what each corpus lands. The 4x corpus lands a copy of every result per copy, under the copy's
        // own source, as a store four times the size would; the historical corpus predates that and lands the
        // clone's results, as 0b.6 did.
        var corpora = [("live clone", base, results)]
        if !cloneOnly {
            corpora.append(("4x", try Phase0.scaledCopy(of: base, factor: 4, in: dir),
                            Phase0.scaledResults(results, factor: 4)))
        }
        if historical {
            let old = try sandboxes.make(named: "tracker4372-historical")
            corpora.append(("4x, listings shared as before #4288",
                            try Phase0.scaledCopy(of: base, factor: 4, in: old, era: .before4288), results))
        }
        for (label, url, results) in corpora {
            let container = try Phase0.openContainer(at: url)
            let ctx = container.mainContext
            defer { withExtendedLifetime(container) {} }
            let saves = Phase0SaveLog(main: ctx)
            for round in 1...2 {
                let rows = try ctx.fetch(FetchDescriptor<Prospect>())
                for r in rows { _ = r.recipients.count }
                // #4427: by the title, which every copy glues, rather than the key, which since #4427 a copy
                // with no venue no longer ends in its glue. In front on today's corpus, on the end on the
                // historical one (`ScaledCorpus.gluedName`), so both are asked.
                let copyRow = rows.map { p in
                    (1..<4).contains { k in
                        let glue = Phase0.glue(forCopy: k)
                        return p.groupName.contains(glue + glue) || p.groupName.hasSuffix(glue)
                    }
                }
                let indexOf = Dictionary(rows.enumerated().map { ($1.persistentModelID, $0) }, uniquingKeysWith: { a, _ in a })
                var clock = Phase0.now()
                func lap(_ what: String) {
                    TrackerAttribution.say("[\(label)] round \(round): \(what) in \(String(format: "%.1f", Phase0.ms(since: clock))) ms")
                    clock = Phase0.now()
                }
                let before = TrackerAttribution.values(rows)
                lap("values snapshotted")
                let log = TrackerAttribution.Log()
                let armed = TrackerAttribution.arm(rows, log: log)
                lap("\(armed) trackers armed")
                _ = saves.take()
                var step = 0
                let outcome = await ScoutExtractIngest.ingest(
                    results, clients: [], history: [], blocked: .empty,
                    onLandingStep: { id, _ in
                        step += 1
                        log.enter(id == ScoutLandingStore.Counters.afterReconcile ? "closing save" : "later sources and the reconcile")
                    },
                    into: ctx)
                log.enter("after ingest returned")
                lap("landed")
                try? await Task.sleep(for: .milliseconds(150))
                let after = TrackerAttribution.values(rows)
                let snap = log.snapshot
                let entries = saves.take()
                lap("\(snap.fires.count) fires collected")
                report(label: label, round: round, rows: rows, copyRow: copyRow, armed: armed, before: before,
                       after: after, snap: snap, outcome: outcome, entries: entries, indexOf: indexOf, steps: step)
            }
        }
    }

    private func report(label: String, round: Int, rows: [Prospect], copyRow: [Bool], armed: Int,
                        before: [TrackerAttribution.Slot: String], after: [TrackerAttribution.Slot: String],
                        snap: (fires: [TrackerAttribution.Slot: [UInt]], phases: [TrackerAttribution.Slot: String], offMain: Int),
                        outcome: ScoutService.Outcome, entries: [Phase0SaveLog.Entry],
                        indexOf: [PersistentIdentifier: Int], steps: Int) {
        typealias Slot = TrackerAttribution.Slot
        let moved: (Slot) -> Bool = { before[$0] != after[$0] }
        let firedRows = Set(snap.fires.keys.map(\.row))
        let changedRows = Set(before.keys.filter(moved).map(\.row))
        let firedNoChange = firedRows.subtracting(changedRows)
        let fieldsPerRow = Prospect.scopeFields.count

        // Per writer: fires, rows, how many of those fires moved the value.
        var byWriter: [String: (fires: Int, moved: Int, rows: Set<Int>, copies: Set<Int>, fields: [String: Int])] = [:]
        var writerOf: [[UInt]: String] = [:]
        for (slot, stack) in snap.fires {
            let w = writerOf[stack] ?? TrackerAttribution.writer(stack)
            writerOf[stack] = w
            var e = byWriter[w] ?? (0, 0, [], [], [:])
            e.fires += 1
            if moved(slot) { e.moved += 1 }
            e.rows.insert(slot.row)
            if copyRow[slot.row] { e.copies.insert(slot.row) }
            e.fields[slot.field, default: 0] += 1
            byWriter[w] = e
        }
        // Per field: fires, and how many of them moved.
        var byField: [String: (fires: Int, moved: Int)] = [:]
        for slot in snap.fires.keys {
            var e = byField[slot.field] ?? (0, 0)
            e.fires += 1
            if moved(slot) { e.moved += 1 }
            byField[slot.field] = e
        }
        // How many of a row's own fields fired: one field is a write, all of them is a refresh.
        var rowFieldFires: [Int: Int] = [:]
        for slot in snap.fires.keys where slot.contact == nil { rowFieldFires[slot.row, default: 0] += 1 }
        let allFields = rowFieldFires.values.filter { $0 == fieldsPerRow }.count
        var phaseCounts: [String: Set<Int>] = [:]
        for (slot, phase) in snap.phases { phaseCounts[phase, default: []].insert(slot.row) }

        // Every save, and how many of the shows it reported updated had no value change.
        let saveLines = entries.enumerated().compactMap { (i, e) -> String? in
            let updated = (e.identifiers.first { $0.key.lowercased().contains("updated") }?.value ?? [])
                .compactMap { indexOf[$0] }
            guard !updated.isEmpty else { return nil }
            let unchanged = updated.filter { !changedRows.contains($0) }.count
            let copies = updated.filter { copyRow[$0] }.count
            return "save \(i + 1): \(updated.count) shows updated, \(unchanged) with no value change, \(copies) of them copies"
        }
        let writerLines = byWriter.sorted { $0.value.fires > $1.value.fires }.map { w, e in
            let topFields = e.fields.sorted { $0.value > $1.value }.prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            return "\(e.fires) fires on \(e.rows.count) shows (\(e.copies.count) copies), \(e.moved) moved a value: \(w)\n      fields: \(topFields)"
        }
        let fieldLines = byField.sorted { $0.value.fires > $1.value.fires }.prefix(30)
            .map { "\($0.key) \($0.value.fires) fired, \($0.value.moved) moved" }
        let twinLine = TrackerAttribution.twinKinds(rows: rows, copyRow: copyRow,
                                                    restamped: Set(before.keys.filter { $0.field == "ingestedAt" && $0.contact == nil && moved($0) }.map(\.row)))
        TrackerAttribution.say("""
            [\(label)] round \(round): \(rows.count) shows (\(copyRow.filter { $0 }.count) copies), \(armed) trackers armed, \(Phase0.load())
              outcome inserted \(outcome.inserted) updated \(outcome.updated) skipped \(outcome.skipped); \(steps) landing steps
              shows with a tracker fired \(firedRows.count) (\(firedRows.filter { copyRow[$0] }.count) copies); shows whose values changed \(changedRows.count) (\(changedRows.filter { copyRow[$0] }.count) copies); fired with no value change \(firedNoChange.count) (\(firedNoChange.filter { copyRow[$0] }.count) copies)
              slots fired \(snap.fires.count), of which moved a value \(snap.fires.keys.filter(moved).count); fires off the main thread \(snap.offMain)
              shows with ALL \(fieldsPerRow) of their own fields fired (a refresh, not a write) \(allFields); field fires per show: \(Dictionary(grouping: rowFieldFires.values, by: { $0 }).mapValues(\.count).sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " "))
              shows first fired by phase: \(phaseCounts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.count)" }.joined(separator: ", "))
              saves with shows updated: \(saveLines.isEmpty ? "none" : saveLines.joined(separator: "; "))
              by writer:
                \(writerLines.joined(separator: "\n    "))
              by field (top 30):
                \(fieldLines.joined(separator: "\n    "))
              \(twinLine)
            """)
    }
}
