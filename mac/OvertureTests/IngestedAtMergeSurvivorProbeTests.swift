import Testing
import Foundation
import SwiftData

// #4331 (A2): does stamping `ingestedAt` only on a changed row leave every merge reader picking the SAME
// survivor as stamping every touched row did? Measured on the frozen 1x and 4x inputs of #4327 step 0.0, opt in:
//
//   TEST_RUNNER_MEASURE_4331=1 TEST_RUNNER_MEASURE_4331_INPUTS=<archive> TEST_RUNNER_SWIFT_DETERMINISTIC_HASHING=1 \
//     mac/scripts/run-tests-locked.sh -only-testing:OvertureTests/IngestedAtMergeSurvivorProbeTests
//
// Each size is run twice from its own fresh copy of the archive, once under each rule (`IngestedAtStamp.Rule`):
// the recorded results land, the launch merges run, the same results land again, the merges run again. The two
// stores are then compared row by row and field by field through the landing oracle's snapshot, which leaves out
// only the clock fields. Equal means every merge picked the same survivor, every re-key landed on the same row,
// and nothing else any reader decided moved. It also reports, per landing, how many rows each rule restamped,
// and how many positions of the Archive's order (`DismissedProspects`) moved, which is the reader whose meaning
// this change DOES move, by design.
//
// PRIVACY: counts and durations only, never a title, venue or URL (L222). Nothing here writes outside its own
// sandbox, and the archive itself is never opened, only copied (L487).
@MainActor
@Suite("#4331 merge survivors under both stamp rules (opt in, frozen inputs)", .serialized)
final class IngestedAtMergeSurvivorProbeTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated static var env: [String: String] { ProcessInfo.processInfo.environment }

    @Test func bothRulesLeaveTheSameStoreAt1x() async throws { try await measure(size: "x1") }
    @Test func bothRulesLeaveTheSameStoreAt4x() async throws { try await measure(size: "x4") }

    private struct Arm {
        var restampedPerLanding: [Int] = []
        // Rows sharing a merge reader's candidate key with another row after each landing: the ones the rule
        // still restamps on every touch.
        var withATwin: [Int] = []
        var mergedAway: [Int] = []
        var landingSeconds: [Double] = []
        var snapshot: LandingOracle.Snapshot?
        var archiveOrder: [String] = []
        var rows = 0
    }

    private func measure(size: String) async throws {
        guard Self.env["MEASURE_4331"] != nil else {
            print("ingestedAt survivor probe: not measured. Set TEST_RUNNER_MEASURE_4331=1 to run it.")
            return
        }
        guard Self.env["SWIFT_DETERMINISTIC_HASHING"] == "1" else {
            Issue.record("UNMEASURED: the probe needs TEST_RUNNER_SWIFT_DETERMINISTIC_HASHING=1, as the real arm does")
            return
        }
        guard let inputs = Self.env["MEASURE_4331_INPUTS"] else {
            Issue.record("UNMEASURED: TEST_RUNNER_MEASURE_4331_INPUTS must name the frozen archive")
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
        var arms: [IngestedAtStamp.Rule: Arm] = [:]
        for rule in [IngestedAtStamp.Rule.everyTouch, .whenChanged] {
            arms[rule] = try await land(size: size, rule: rule, archive: archive, manifest: manifest,
                                        today: today, now: now)
        }
        guard let old = arms[.everyTouch], let new = arms[.whenChanged],
              let oldSnapshot = old.snapshot, let newSnapshot = new.snapshot else {
            Issue.record("UNMEASURED: an arm did not land")
            return
        }
        let differences = LandingOracle.differences(expected: LandingOracle.recording(of: Self.mergeClockAsPresence(oldSnapshot)),
                                                    actual: Self.mergeClockAsPresence(newSnapshot), arm: .real)
        let moved = zip(old.archiveOrder, new.archiveOrder).filter { $0 != $1 }.count
        print("""
            ingestedAt survivor probe [\(size)] \(old.rows) shows after; \(Phase0.load())
              rows restamped per landing, every touch: \(old.restampedPerLanding); only when changed: \(new.restampedPerLanding)
              rows with a twin after each landing: \(new.withATwin)
              landing seconds, every touch: \(old.landingSeconds.map { String(format: "%.2f", $0) }); only when changed: \(new.landingSeconds.map { String(format: "%.2f", $0) })
              rows the launch merges deleted per round, every touch: \(old.mergedAway); only when changed: \(new.mergedAway)
              Archive order positions moved: \(moved) of \(new.archiveOrder.count)
              stores after two landings and two launch merges: \(differences.isEmpty ? "EQUAL" : "DIFFERENT")
            """)
        #expect(differences.isEmpty, Comment(rawValue:
            "the two stamp rules left different stores, so some reader decided differently (hashes only):\n"
            + differences.joined(separator: "\n")))
    }

    // `survivedMergeAt` is stamped with the wall clock by the merge itself (`SurvivorInheritance.carry`), so the
    // two arms, merged minutes apart, can only agree on WHETHER a row survived a merge, which is the question.
    static func mergeClockAsPresence(_ snapshot: LandingOracle.Snapshot) -> LandingOracle.Snapshot {
        let rows = snapshot.rows.map { row in
            LandingOracle.Row(entity: row.entity, fields: row.fields.map { field in
                field.name == "survivedMergeAt" && field.value != "nil"
                    ? LandingOracle.Field(name: field.name, value: "set") : field
            })
        }
        // Re-sorted as `LandingOracle.snapshot` sorts, since the stamp took part in the order.
        return LandingOracle.Snapshot(rows: rows.sorted {
            if $0.entity != $1.entity { return $0.entity < $1.entity }
            if $0.identity != $1.identity { return $0.identity < $1.identity }
            return $0.canonical < $1.canonical
        })
    }

    private func land(size: String, rule: IngestedAtStamp.Rule, archive: URL, manifest: LandingOracle.Manifest,
                      today: String, now: Date) async throws -> Arm {
        let work = try sandboxes.make(named: "ingested-at-probe-\(size)-\(rule)")
        let storeNames = manifest.sha256.keys.filter { $0.hasPrefix(size + "/") }.sorted()
        guard let storeName = storeNames.first(where: { $0.hasSuffix(".store") }) else {
            Issue.record(Comment(rawValue: "UNMEASURED: the MANIFEST names no \(size) store"))
            return Arm()
        }
        for name in storeNames + LandingOracleTests.requiredInputs {
            let to = work.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: archive.appendingPathComponent(name), to: to)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: to.path)
        }
        let results = try ScoutExtractResultsDecoder.decode(
            try Data(contentsOf: work.appendingPathComponent("overture-scout-extract-results.json")))
        let container = try Phase0.openContainer(at: work.appendingPathComponent(storeName))
        let context = container.mainContext
        context.autosaveEnabled = false
        let existing = try context.fetch(FetchDescriptor<Prospect>())
        let loaded = DownbeatBridge.loadWithHealth(from: work.appendingPathComponent("downbeat-export.json"), now: now)
        let history = LocalHistory.forMatching(existing: existing,
                                               importedFrom: work.appendingPathComponent("overture-history.json"))
        let blocked = ScoutService.blockedCalendar(export: (loaded.bookings, loaded.blockedDates, loaded.health),
                                                   context: context)
        var arm = Arm()
        for round in 0..<2 {
            let at = now.addingTimeInterval(Double(round) * 3_600)
            let before = Dictionary(try context.fetch(FetchDescriptor<Prospect>()).map { ($0.persistentModelID, $0.ingestedAt) },
                                    uniquingKeysWith: { a, _ in a })
            let start = Date()
            await ScoutExtractIngest.ingest(results, clients: loaded.clients, history: history, blocked: blocked,
                                            today: today, now: at, stampRule: rule, into: context)
            try context.save()
            arm.landingSeconds.append(Date().timeIntervalSince(start))
            let after = try context.fetch(FetchDescriptor<Prospect>())
            arm.restampedPerLanding.append(after.filter { p in before[p.persistentModelID].map { $0 != p.ingestedAt } ?? false }.count)
            let index = MergeCandidateIndex(rows: after, tokens: { ScoutLandingStore.Fold($0).tokens })
            arm.withATwin.append(after.filter { index.isContested($0) }.count)
            // The launch merges that read `ingestedAt`, in `LaunchMigrations.run`'s order.
            let beforeMerges = after.count
            FirstSeenBackfill.run(in: context)
            NaturalKeyVenueMigration.run(in: context)
            DriftedRunMerge.run(in: context)
            SameNightTitleVariantMerge.run(in: context)
            try context.save()
            arm.mergedAway.append(beforeMerges - (try context.fetchCount(FetchDescriptor<Prospect>())))
        }
        let rows = try context.fetch(FetchDescriptor<Prospect>())
        arm.rows = rows.count
        arm.archiveOrder = DismissedProspects.list(from: rows).map(\.naturalKey)
        arm.snapshot = try LandingOracle.snapshot(of: container)
        return arm
    }
}
