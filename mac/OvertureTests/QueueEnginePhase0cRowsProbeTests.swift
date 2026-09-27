import Testing
import Foundation
import SwiftData

// #4106 plan v7, Phase 0c: probes 0c.5 (T7, the per-row entries), 0c.6 (T8, the unattributed remainder and
// the long tail) and 0c.10 (the total orders of decisions 13 and 18).
//
// TWO KINDS OF TEST, run differently on purpose.
//
// 1. The PROPERTY TEST of the T7 prototype runs on every suite run, at CI settings chosen to add seconds:
//    seeded operation sequences over committed synthetic stores of 60 and 300 rows, with the prototype's
//    every output compared against today's code through the canonical oracle after EVERY operation and
//    every undo. Deep settings (20 seeds by 500 operations, both sizes) are opt in:
//
//      TEST_RUNNER_MEASURE_4106_PHASE0C_ROWS_DEEP=1 mac/scripts/run-tests-locked.sh \
//        "-only-testing:OvertureTests/QueueEnginePhase0cRowsProbeTests"
//
// 2. The PROBES read a `LiveStoreClone` copy of the live store and the fourfold corpus `Phase0.scaledCopy`
//    builds from it, and run a stopwatch, so they are opt in for the reasons every #4106 probe is (it clones
//    Dan's store, and a timing on a shared Mac measures the Mac, L224). Without the variable each says it did
//    not run rather than passing silently (L98):
//
//      TEST_RUNNER_MEASURE_4106_PHASE0C_ROWS=1 mac/scripts/run-tests-locked.sh \
//        "-only-testing:OvertureTests/QueueEnginePhase0cRowsProbeTests"
//
// PRIVACY. Counts, durations, field names and 8 hex digit hashes only, never a show, a presenter, a venue,
// an address or a URL (L222). Timings are the Debug build the runner builds, with the load average beside
// every block (L356) and a five-run spread of today's code as the noise floor (L395).

enum Phase0cRows {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0C_ROWS"] != nil
    }

    nonisolated static var deep: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0C_ROWS_DEEP"] != nil
    }

    nonisolated static func say(_ line: String) { print("phase0c-rows " + line) }

    /// Max, p99 and median of a set of samples, in milliseconds, with the count.
    nonisolated static func spread(_ samples: [Double]) -> (max: Double, p99: Double, median: Double, text: String) {
        guard !samples.isEmpty else { return (0, 0, 0, "no samples") }
        let s = samples.sorted()
        let p99 = s[min(s.count - 1, Int((Double(s.count) * 0.99).rounded(.up)) - 1)]
        let median = s[s.count / 2]
        return (s.last!, p99, median,
                String(format: "max %.3f ms, p99 %.3f, median %.3f over %d", s.last!, p99, median, s.count))
    }
}

@MainActor
@Suite("#4106 Phase 0c probes 0c.5, 0c.6, 0c.10 (T7 property test by default; clone probes opt in)")
struct QueueEnginePhase0cRowsProbeTests {

    let sandboxes = TemporarySandboxes()

    func skip(_ probe: String) -> Bool {
        guard Phase0cRows.enabled else {
            print("phase0c-rows \(probe): not measured. Set TEST_RUNNER_MEASURE_4106_PHASE0C_ROWS=1 to run it.")
            return true
        }
        return false
    }

    // MARK: - 0c.5: the property test, on the synthetic stores

    struct SequenceResult {
        var failures: [String] = []
        var checks = 0
        var skipped = 0
        var opsByKind: [String: Int] = [:]
        var oracleMovedByKind: [String: Int] = [:]
        var changedKeysByKind: [String: Int] = [:]
        var hiddenFlips = 0
        var inheritedMoves = 0
        var permutedDisagreements = 0
        var contactOrderMoved = 0
    }

    private static func same(_ a: Phase0cRowOracle, _ b: Phase0cRowOracle) -> Bool {
        a.rows == b.rows && a.focuses == b.focuses && a.agent == b.agent && a.due == b.due
            && a.dueNext == b.dueNext && a.reachNext == b.reachNext && a.rowCounts == b.rowCounts
    }

    /// One seeded sequence: every operation checked, a random share undone and checked again.
    static func runSequence(size: Int, seed: UInt64, ops: Int) throws -> SequenceResult {
        let fx = try Phase0cRowsFixture(size: size, seed: seed)
        var result = SequenceResult()
        var proto = Phase0cRowEntries(rows: fx.rows, context: fx.rowContext(), upstream: fx.upstream())
        var lastOracle = fx.oracle()
        var lastUp = fx.upstream()

        func check(_ step: Int, _ label: String, kind: String?) {
            let o = fx.oracle()
            // Rows whose relationship order moved while the entry stood: a fact about the store, reported.
            let byPID = fx.rowsByPID
            for (pid, e) in proto.entries {
                if let p = byPID[pid], p.recipients.map(\.id) != e.contactOrder { result.contactOrderMoved += 1 }
            }
            result.checks += 1
            let bad = o.mismatches(proto, rowsByKey: fx.rowsByKey)
            if !bad.isEmpty {
                result.failures.append("seed \(seed) size \(size) step \(step) op \(label): " + bad.joined(separator: "; "))
            }
            if let kind, !same(o, lastOracle) { result.oracleMovedByKind[kind, default: 0] += 1 }
            lastOracle = o
        }

        func apply(_ changed: Set<PersistentIdentifier>, kind: String?) {
            let up = fx.upstream()
            result.hiddenFlips += up.hidden.symmetricDifference(lastUp.hidden).count
            result.inheritedMoves += Set(up.inherited.keys).union(lastUp.inherited.keys)
                .filter { up.inherited[$0] != lastUp.inherited[$0] }.count
            lastUp = up
            let out = proto.apply(changed: changed, rows: fx.rowsByPID, upstream: up, context: fx.rowContext())
            if let kind, !out.isEmpty { result.changedKeysByKind[kind, default: 0] += 1 }
        }

        check(0, "initial", kind: nil)
        for step in 1...ops {
            // Every kind once, in order, first, so each is exercised whatever the seed draws; then at random.
            let every = Phase0cRowsFixture.Kind.allCases
            let kind = step <= every.count ? every[step - 1] : fx.pickKind()
            guard let op = fx.perform(kind) else { result.skipped += 1; continue }
            result.opsByKind[kind.rawValue, default: 0] += 1
            apply(op.changed, kind: kind.rawValue)
            check(step, op.label, kind: kind.rawValue)
            if fx.coin(0.4) {
                apply(op.undo(), kind: nil)
                check(step, op.label + " (undo)", kind: nil)
            }
            if result.failures.count >= 5 { break }
        }
        // The oracle itself, over reversed and shuffled input, at the end of the sequence (plan section 4):
        // through the canonical wrapper it must give one answer whatever order the rows arrive in.
        var generator = SeededGenerator(seed: seed ^ 0x5eed)
        let forward = fx.oracle()
        for order in [Array(fx.rows.reversed()), fx.rows.shuffled(using: &generator)]
        where !same(fx.oracle(order: order), forward) {
            result.permutedDisagreements += 1
        }
        return result
    }

    @Test(arguments: [60, 300])
    func rowEntriesPatchAgreesWithTheCanonicalOracles(size: Int) throws {
        let deep = Phase0cRows.deep
        let seeds: [UInt64] = deep ? (1...20).map { UInt64(4106_5000 + $0) }
            : (size == 60 ? [4106_5001, 4106_5002] : [4106_5003])
        let ops = deep ? 500 : (size == 60 ? 60 : 30)
        let started = Phase0.now()
        var total = SequenceResult()
        for seed in seeds {
            let r = try Self.runSequence(size: size, seed: seed, ops: ops)
            total.failures += r.failures
            total.checks += r.checks
            total.skipped += r.skipped
            total.hiddenFlips += r.hiddenFlips
            total.inheritedMoves += r.inheritedMoves
            total.permutedDisagreements += r.permutedDisagreements
            total.contactOrderMoved += r.contactOrderMoved
            for (k, v) in r.opsByKind { total.opsByKind[k, default: 0] += v }
            for (k, v) in r.oracleMovedByKind { total.oracleMovedByKind[k, default: 0] += v }
            for (k, v) in r.changedKeysByKind { total.changedKeysByKind[k, default: 0] += v }
        }
        let wall = Phase0.ms(since: started)
        let kinds = Phase0cRowsFixture.Kind.allCases.map(\.rawValue).map {
            "\($0) \(total.opsByKind[$0] ?? 0)/\(total.oracleMovedByKind[$0] ?? 0)/\(total.changedKeysByKind[$0] ?? 0)"
        }
        Phase0cRows.say("""
            0c.5 property [\(size) rows, \(deep ? "deep" : "CI")] \(seeds.count) seeds x \(ops) ops, \
            \(total.checks) comparisons, \(total.skipped) ops not applicable, \(total.failures.count) failing, \
            wall \(String(format: "%.0f", wall)) ms
              per kind (applied / oracle output moved / prototype ChangedKeys non-empty): \(kinds.joined(separator: ", "))
              upstream hand-offs seen: \(total.hiddenFlips) hidden flips, \(total.inheritedMoves) inherited moves
              oracle over reversed and shuffled input disagreeing with forward: \(total.permutedDisagreements)
              entry-comparisons where p.recipients came back in a different order than when the entry was built, the row unchanged: \(total.contactOrderMoved)
            """)
        #expect(total.failures.isEmpty, Comment(rawValue: total.failures.prefix(5).joined(separator: "\n")))
        #expect(total.permutedDisagreements == 0, "the canonical oracle gave two answers for one store")
        // Positive controls (L159): the hand-offs this probe exists for must actually have happened, or a
        // green run proves nothing about them.
        #expect(total.hiddenFlips > 0, "no operation ever flipped a collapse's hidden set")
        #expect(total.inheritedMoves > 0, "no operation ever moved an inherited answer")
        #expect((total.oracleMovedByKind["collapsedFront"] ?? 0) > 0, "dismissing a front never changed the output")
        #expect((total.oracleMovedByKind["clock"] ?? 0) > 0, "no clock move ever changed the output")
    }
}
