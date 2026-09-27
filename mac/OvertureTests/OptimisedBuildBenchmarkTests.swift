import Testing
import Foundation

// #4106, plan v7 probe 0c.9: a FIXED workload whose optimised reading must be clearly faster than its
// Debug reading before any optimised timing is believed (L188, L416).
//
// The runner's build log check (`mac/scripts/lib/optimised-build.sh`) proves the compiler was HANDED
// -O. This proves the code that ran was actually faster for it, which is the claim every later timing
// leans on. Run it both ways and compare the two medians:
//
//   TEST_RUNNER_MEASURE_OPTIMISED_BUILD=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/OptimisedBuildBenchmarkTests
//   OVERTURE_TEST_OPTIMISED=1 TEST_RUNNER_MEASURE_OPTIMISED_BUILD=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/OptimisedBuildBenchmarkTests
//
// The workload is the shape decision 5 is about: a GENERIC function over a protocol, sorting and folding
// value types, which is what -Onone leaves unspecialised and -O with whole module specialises. It lives
// in this target on purpose, because this target compiles the app's sources into its own module
// (mac/project.yml), so it is built with exactly the flags the pure probes run under.
//
// Printed, never asserted against a time, because a duration depends on what else the Mac is doing
// (L224). What IS asserted is that every sample computed the same answer, which also keeps the
// optimiser from deleting the work it is being timed on.
@Suite("An optimised build is measurably optimised (#4106, 0c.9)")
struct OptimisedBuildBenchmarkTests {
    fileprivate static let rowCount = 100_000
    fileprivate static let samples = 11

    // A fixed sequence from a fixed seed, so both builds time identical input.
    fileprivate static func rows() -> [BenchmarkRow] {
        var state: UInt64 = 4106
        var out: [BenchmarkRow] = []
        out.reserveCapacity(rowCount)
        for _ in 0..<rowCount {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let key = Int(truncatingIfNeeded: state >> 40) % 50_000
            let weight = Int(truncatingIfNeeded: state >> 20) % 1_000
            out.append(BenchmarkRow(key: key, weight: weight))
        }
        return out
    }

    fileprivate static func workload<Row: BenchmarkKeyed>(_ rows: [Row]) -> Int {
        let sorted = rows.sorted { lhs, rhs in
            lhs.key != rhs.key ? lhs.key < rhs.key : lhs.weight < rhs.weight
        }
        var byBucket: [Int: Int] = [:]
        var checksum = 0
        for (index, row) in sorted.enumerated() {
            byBucket[row.key % 997, default: 0] &+= row.weight
            checksum = checksum &+ index &* row.weight
        }
        return byBucket.values.reduce(checksum, &+)
    }

    @Test func measureTheFixedWorkload() {
        guard ProcessInfo.processInfo.environment["MEASURE_OPTIMISED_BUILD"] != nil else {
            print("optimised-build-benchmark: not measured. Set TEST_RUNNER_MEASURE_OPTIMISED_BUILD=1 to run it.")
            return
        }
        let input = Self.rows()
        let expected = Self.workload(input)   // also the warm pass
        var millis: [Double] = []
        for _ in 0..<Self.samples {
            let started = DispatchTime.now().uptimeNanoseconds
            let answer = Self.workload(input)
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            #expect(answer == expected, "the fixed workload gave a different answer on a later sample")
            millis.append(Double(elapsed) / 1_000_000)
        }
        millis.sort()
        let at: (Int) -> String = { String(format: "%.1f", millis[$0]) }
        // The compiled code's own account of how it was built, beside the log check's account of what
        // the compiler was handed: `_isDebugAssertConfiguration` is true only at -Onone.
        let build = _isDebugAssertConfiguration() ? "compiled -Onone (Debug)" : "compiled optimised"
        print("optimised-build-benchmark: \(build); \(Self.samples) samples of a fixed \(Self.rowCount) row"
            + " generic sort and fold: median \(at(Self.samples / 2)) ms, p10 \(at(1)) ms,"
            + " p90 \(at(Self.samples - 2)) ms, min \(at(0)) ms, max \(at(Self.samples - 1)) ms")
    }
}

fileprivate protocol BenchmarkKeyed {
    var key: Int { get }
    var weight: Int { get }
}

fileprivate struct BenchmarkRow: BenchmarkKeyed {
    let key: Int
    let weight: Int
}
