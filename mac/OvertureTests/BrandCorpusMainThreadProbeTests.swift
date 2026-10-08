import Testing
import Foundation
import SwiftData

// #4332 (A3): how much main thread time moving the brand corpus off the main actor removes.
//
// MEASUREMENT ONLY, on the contract of #4275's probes beside it: every read is taken against a throwaway
// `LiveStoreClone` copy of the live store, or a `Phase0.scaledCopy` of it, never the live store. Counts and
// durations only, never a show name (L222). OPT IN, and it says it did not run rather than passing:
//
//   TEST_RUNNER_MEASURE_4332=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/BrandCorpusMainThreadProbeTests
//
// Optional: TEST_RUNNER_MEASURE_4332_SIZES=1,4 (store multiples), TEST_RUNNER_MEASURE_4332_ROUNDS=5.
//
// WHAT IT COMPARES, per round, each on a context of its own so neither arm reads rows the other cached:
//   on main    `ScoutService.venueBrandCorpus(in:)` on a main actor context: the read both scout entry
//              points made at their first source before this change, and the one the lead paste still makes
//              until A11 (#4339). The main thread is held for all of it.
//   off main   the entry flush's check on the main actor (`ScoutService.flushBeforeLanding`), then
//              `ScoutService.venueBrandCorpusOffMain`, the read on a background context. Reported as the main
//              thread's LONGEST single wait while it ran, measured from another thread as
//              `LandingStallMonitor` does, and the read's wall time.
// The main thread time removed is the first arm minus the second's longest wait. It is the corpus's share of
// an entry point's first hold (RC3), not a figure for the whole hold, which A11 measures.
@MainActor
@Suite("How much main thread time the off main brand corpus read removes (#4332)", .serialized)
struct BrandCorpusMainThreadProbeTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated private static var env: [String: String] { ProcessInfo.processInfo.environment }
    nonisolated private static var enabled: Bool { env["MEASURE_4332"] != nil }
    nonisolated private static var sizes: [Int] {
        (env["MEASURE_4332_SIZES"] ?? "1,4").split(separator: ",").compactMap { Int($0) }
    }
    nonisolated private static var rounds: Int { Int(env["MEASURE_4332_ROUNDS"] ?? "") ?? 5 }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func theCorpusReadsMainThreadTimeOnAndOffTheMainActor() async throws {
        guard Self.enabled else {
            print("probe4332: not measured. Set TEST_RUNNER_MEASURE_4332=1 to run it.")
            return
        }
        let dir = try sandboxes.make(named: "probe4332-stores")
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        for factor in Self.sizes {
            let url = factor == 1 ? base : try Phase0.scaledCopy(of: base, factor: factor, in: dir)
            let container = try Phase0.openContainer(at: url)
            defer { withExtendedLifetime(container) {} }
            let rows = try container.mainContext.fetchCount(FetchDescriptor<Prospect>())
            var onMain: [Double] = []
            var offMainWorst: [Double] = []
            var offMainWall: [Double] = []
            for round in 0..<Self.rounds {
                func onMainArm() -> ProducerGate.VenueBrands {
                    let before = ModelContext(container)
                    let t0 = Phase0.now()
                    let read = ScoutService.venueBrandCorpus(in: before)
                    onMain.append(Phase0.ms(since: t0))
                    #expect(read.degradedReads.isEmpty)
                    return read.brands
                }
                func offMainArm() async -> ProducerGate.VenueBrands {
                    let after = ModelContext(container)
                    let monitor = LandingStallMonitor()
                    monitor.start()
                    let t1 = Phase0.now()
                    #expect(ScoutService.flushBeforeLanding(after, save: { try $0.save() }, record: EntryFlushRecord()).refusal == nil)
                    let landed = await ScoutService.venueBrandCorpusOffMain(
                        container: container, read: ScoutService.readProspectTable,
                        readOverrides: ScoutService.readProducerOverrides)
                    offMainWall.append(Phase0.ms(since: t1))
                    offMainWorst.append(monitor.stop().worst)
                    return landed.brands
                }
                // #4617: the arms alternate which goes first, round by round. Timed on main first in every round,
                // the off main arm carried the order effect into `mainThreadRemovedMs`.
                let onBrands: ProducerGate.VenueBrands, offBrands: ProducerGate.VenueBrands
                if round % 2 == 0 {
                    onBrands = onMainArm()
                    offBrands = await offMainArm()
                } else {
                    offBrands = await offMainArm()
                    onBrands = onMainArm()
                }
                // The two arms read the same store, so they must judge the same brands.
                #expect(offBrands == onBrands, "the off main corpus differs from the on main one")
                print("probe4332 size=\(factor)x rows=\(rows) round=\(round) onMainMs=\(String(format: "%.1f", onMain.last!)) "
                      + "offMainWorstWaitMs=\(String(format: "%.1f", offMainWorst.last!)) "
                      + "offMainWallMs=\(String(format: "%.1f", offMainWall.last!))")
            }
            // #4617: each median through `Phase0.reading`, which prints the line the before and after comparison
            // reads. An even number of rounds now reads the upper of the middle two, as every probe reading does.
            let onMainReading = Phase0.reading("brand-onMain-\(factor)x", runs: onMain)
            let worstWaitReading = Phase0.reading("brand-offMainWorstWait-\(factor)x", runs: offMainWorst)
            let wallReading = Phase0.reading("brand-offMainWall-\(factor)x", runs: offMainWall)
            print(Phase0.orderLine(alternated: true, ["brand-onMain-\(factor)x", "brand-offMainWorstWait-\(factor)x"]))
            let removed = onMainReading.median - worstWaitReading.median
            print("probe4332 SUMMARY size=\(factor)x rows=\(rows) rounds=\(Self.rounds) "
                  + "onMainMedianMs=\(String(format: "%.1f", onMainReading.median)) "
                  + "offMainWorstWaitMedianMs=\(String(format: "%.1f", worstWaitReading.median)) "
                  + "offMainWallMedianMs=\(String(format: "%.1f", wallReading.median)) "
                  + "mainThreadRemovedMs=\(String(format: "%.1f", removed))")
        }
    }
}
