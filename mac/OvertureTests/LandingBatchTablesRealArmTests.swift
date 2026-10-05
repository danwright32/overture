import Testing
import Foundation
import SwiftData
import CryptoKit

// #4333 (step A4 of #4275's plan), the item its audit of 2026-10-03 found unbuilt: "A1's oracle after EVERY
// source against a from-scratch rebuild" on the REAL arm. `LandingBatchTablesTests` checks the kept batch
// tables against a rebuild after every source on A1's SYNTHETIC corpus; the real arm (the frozen 1x and 4x
// inputs, #4327 step 0.0) was only ever compared end to end against 6d3453d8 (`LandingOracleTests.realArmAt1x`).
// So a table that drifted from a rebuild part way through a real landing, and was set right again by a later
// source, was invisible on the data the plan is sized from.
//
// Under the L445 decision (2026-09-29, on #4333 and #4335): the real arm is compared by DIGEST. A mismatch names
// the source's POSITION in the landing, the table and the two hashes, never a value, so its text can be pasted
// anywhere. Every failure text that goes in a PR body comes from the synthetic arm.
//
// Opt in, on this Mac only, exactly as the oracle's own real arm:
//   TEST_RUNNER_MEASURE_4275=1 TEST_RUNNER_MEASURE_4275_INPUTS=<frozen archive> \
//     mac/scripts/run-tests-locked.sh -only-testing:OvertureTests/LandingBatchTablesRealArmTests
// A step toward #4275; the 100 ms bar is not met until Phase E (#4343) says so.
@MainActor
@Suite("The real arm's batch tables equal a rebuild after every source, by digest (#4333)", .serialized)
final class LandingBatchTablesRealArmTests {
    private let sandboxes = TemporarySandboxes()
    nonisolated static var env: [String: String] { ProcessInfo.processInfo.environment }

    // MARK: the comparison, which names no value

    // Each table of a snapshot as one canonical text: keys sorted, a set's members sorted, a list kept in its
    // order (a key's row list IS ordered, RC2). Two snapshots holding the same tables give the same texts.
    static func tableTexts(_ s: LandingBatchTables.Snapshot) -> [(table: String, text: String)] {
        func counts(_ d: [String: [String: Int]]) -> String {
            d.keys.sorted().map { k in
                k + "\t" + (d[k] ?? [:]).keys.sorted().map { "\($0)=\(d[k]?[$0] ?? 0)" }.joined(separator: "\u{1f}")
            }.joined(separator: "\n")
        }
        func lists(_ d: [String: [String]]) -> String {
            d.keys.sorted().map { k in k + "\t" + (d[k] ?? []).joined(separator: "\u{1f}") }.joined(separator: "\n")
        }
        func set(_ s: Set<String>) -> String { s.sorted().joined(separator: "\n") }
        return [
            ("titleCounts", counts(s.titleCounts)),
            ("poisonedTokens", set(s.poisonedTokens)),
            ("spellingCounts", counts(s.spellingCounts)),
            ("atAVenueRows", lists(s.atAVenueRows)),
            ("anywhereRows", lists(s.anywhereRows)),
            ("atAVenueShows", lists(s.atAVenueShows)),
            ("anywhereShows", lists(s.anywhereShows)),
            ("atAVenueAmbiguous", set(s.atAVenueAmbiguous)),
            ("anywhereAmbiguous", set(s.anywhereAmbiguous)),
        ]
    }

    static func digest(_ text: String) -> String {
        "sha256:" + SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // The real arm's verdict for one landing step: one line per table whose kept form differs from the rebuild,
    // naming the step's position, the table and the two digests. Empty when every table agrees.
    static func realArmDifferences(kept: LandingBatchTables.Snapshot, rebuilt: LandingBatchTables.Snapshot,
                                   position: Int, of total: Int) -> [String] {
        zip(tableTexts(kept), tableTexts(rebuilt)).compactMap { k, r in
            k.text == r.text ? nil
                : "source \(position) of \(total), table \(k.table): kept \(digest(k.text)), a rebuild \(digest(r.text))"
        }
    }

    // L445's test, on the comparison above: a forced mismatch prints the position, the table and hashes, and
    // none of the corpus's titles, venues or presenters. The mismatch is forced by comparing the tables as they
    // stood after the first source with a rebuild after the last, which differ because later sources add rows.
    @Test func aForcedRealArmTableMismatchNamesNoTitleVenueOrPresenter() async throws {
        let container = try TestModelContainer.inMemory(AppSchema.models)
        let context = container.mainContext
        try LandingOracleCorpus.seed(into: context)
        var first: LandingBatchTables.Snapshot?
        var last: LandingBatchTables.Snapshot?
        await ScoutExtractIngest.ingest(LandingOracleCorpus.results(), clients: [], history: [], blocked: .empty,
                                        today: LandingOracleCorpus.today, now: LandingOracleCorpus.now,
                                        onLandingStep: { step, landing in
                                            guard step != ScoutLandingStore.Counters.afterReconcile else { return }
                                            if first == nil { first = try? landing.batchTablesSnapshot() }
                                            last = try? landing.rebuiltBatchTablesSnapshot()
                                        }, into: context)
        guard let first, let last else {
            Issue.record("the landing reported no source, so nothing was compared")
            return
        }
        let real = Self.realArmDifferences(kept: first, rebuilt: last, position: 1, of: 1).joined(separator: "\n")
        #expect(!real.isEmpty, "the forced mismatch produced no difference, so this measured nothing")
        #expect(real.contains(" table ") && real.contains("sha256:"),
                Comment(rawValue: "a real-arm difference does not name a table and two hashes: \(real.prefix(300))"))
        let names = Set(LandingOracleCorpus.stored.flatMap { [$0.title, $0.venue, $0.presenter] }
            + LandingOracleCorpus.sources.flatMap { s in
                [s.org] + s.events.flatMap { [$0.title, $0.venue ?? "", $0.presenter ?? ""] }
            }).filter { !$0.isEmpty }
        let leaked = names.filter { real.contains($0) }
        #expect(leaked.isEmpty, Comment(rawValue: "a real-arm table difference printed \(leaked.count) titles, venues or presenters"))
        // The positive control: the same two snapshots as the synthetic arm prints them do carry the corpus's
        // words (folded, so compared lower cased, a word at a time), so the silence above is the comparison's
        // redaction and not a lack of anything to print (L159).
        let shown = "\(first)\(last)".lowercased()
        let words = names.flatMap { $0.lowercased().split(separator: " ").map(String.init) }.filter { $0.count >= 5 }
        #expect(words.contains { shown.contains($0) },
                "the snapshots carried no corpus word either, so the redaction above is unmeasured")
    }

    // MARK: the real arm, opt in, on the frozen inputs

    // Opt in, and reported as SKIPPED when not asked for, never as a pass: a green line with nothing compared
    // reads as the real arm having been checked (L411).
    @Test(.enabled(if: Self.env["MEASURE_4275"] != nil, "opt in: set TEST_RUNNER_MEASURE_4275=1 and TEST_RUNNER_MEASURE_4275_INPUTS"))
    func realArmAt1x() async throws { try await realArm(size: "x1") }
    @Test(.enabled(if: Self.env["MEASURE_4275"] != nil, "opt in: set TEST_RUNNER_MEASURE_4275=1 and TEST_RUNNER_MEASURE_4275_INPUTS"))
    func realArmAt4x() async throws { try await realArm(size: "x4") }

    private func realArm(size: String) async throws {
        guard let inputs = Self.env["MEASURE_4275_INPUTS"] else {
            Issue.record("UNMEASURED: TEST_RUNNER_MEASURE_4275_INPUTS must name the frozen archive")
            return
        }
        let archive = URL(fileURLWithPath: inputs)
        guard let manifest = LandingOracle.manifest(at: archive.appendingPathComponent("MANIFEST")) else {
            Issue.record("UNMEASURED: the frozen inputs carry no readable MANIFEST")
            return
        }
        if let refusal = LandingOracle.inputsRefusal(archive: archive, manifest: manifest) {
            Issue.record(Comment(rawValue: refusal))
            return
        }
        guard let today = manifest.facts["today"], let nowText = manifest.facts["now"],
              let now = ISO8601DateFormatter().date(from: nowText) else {
            Issue.record("UNMEASURED: the MANIFEST does not pin today and now")
            return
        }
        let storeNames = manifest.sha256.keys.filter { $0.hasPrefix(size + "/") }.sorted()
        guard let storeName = storeNames.first(where: { $0.hasSuffix(".store") }) else {
            Issue.record(Comment(rawValue: "UNMEASURED: the MANIFEST names no \(size) store"))
            return
        }
        for name in LandingOracleTests.requiredInputs where manifest.sha256[name] == nil {
            Issue.record(Comment(rawValue: "UNMEASURED: inputs differ from the oracle's (\(name): not in the archive)"))
            return
        }
        // Every run copies the archive afresh; the archive itself is never opened (L487).
        let work = try sandboxes.make(named: "landing-tables-real-arm-\(size)")
        for name in storeNames + LandingOracleTests.requiredInputs {
            let to = work.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: archive.appendingPathComponent(name), to: to)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: to.path)
        }
        let results = try ScoutExtractResultsDecoder.decode(
            Data(contentsOf: work.appendingPathComponent("overture-scout-extract-results.json")))
        let container = try Phase0.openContainer(at: work.appendingPathComponent(storeName))
        let context = container.mainContext
        context.autosaveEnabled = false
        let existing = try context.fetch(FetchDescriptor<Prospect>())
        let loaded = DownbeatBridge.loadWithHealth(from: work.appendingPathComponent("downbeat-export.json"), now: now)
        let history = LocalHistory.forMatching(existing: existing,
                                               importedFrom: work.appendingPathComponent("overture-history.json"))
        let blocked = ScoutService.blockedCalendar(export: (loaded.bookings, loaded.blockedDates, loaded.health),
                                                   context: context)
        let total = results.results.count
        var position = 0
        var found: [String] = []
        await ScoutExtractIngest.ingest(results, clients: loaded.clients, history: history, blocked: blocked,
                                        today: today, now: now,
                                        onLandingStep: { step, landing in
                                            guard step != ScoutLandingStore.Counters.afterReconcile else { return }
                                            position += 1
                                            do {
                                                found += Self.realArmDifferences(
                                                    kept: try landing.batchTablesSnapshot(),
                                                    rebuilt: try landing.rebuiltBatchTablesSnapshot(),
                                                    position: position, of: total)
                                            } catch {
                                                found.append("source \(position) of \(total): the store could not answer")
                                            }
                                        }, into: context)
        // Counts only: how many sources landed and were compared (the rest settled while reading, so the tables
        // had nothing new to be judged against), and the verdict.
        print("landing-tables-real-arm: \(size): \(position) of \(total) sources landed and compared; "
              + (found.isEmpty ? "EQUAL after every source" : "\(found.count) DIFFERENT"))
        #expect(position > 0, "UNMEASURED: no source of the frozen results landed, so nothing was compared")
        #expect(found.isEmpty, Comment(rawValue: "the kept tables left a rebuild (hashes only):\n"
                                       + found.joined(separator: "\n")))
    }
}
