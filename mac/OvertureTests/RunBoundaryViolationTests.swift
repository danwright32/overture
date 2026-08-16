import Testing
import Foundation

// #2764 gave the runner a deterministic boundary check: each run fingerprints every OTHER slot's results
// file by content before starting and re-checks it in the EXIT trap, so a run that followed a path it was
// not given is caught rather than trusted not to. A violation is written to `run-boundary-violation.log`.
//
// Nothing in the app read that file. That was fine while two runs could not be alive, so the condition
// could not occur. #2760 is the phase that makes it possible, and a durable record nobody surfaces is a
// writer with no reader (L46). Worse, it is the record of one run having destroyed another's paid work,
// sitting in a file Dan has no reason to open (L142).
@Suite("A boundary violation reaches Dan (#2760, from #2764)")
struct RunBoundaryViolationTests {

    private func tmpDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("overture-boundary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "Boundary-\(UUID().uuidString)")!
    }

    // The runner's own words, which is what the app has to recognise. Copied from `slot_check_foreign_results`
    // in mac/scripts/lib/run-slot.sh; the guard below pins the two together.
    private func violationLine(_ n: Int) -> String {
        (1...max(n, 1)).map { i in
            """
            2026-08-16T21:0\(i):00Z run-slot: BOUNDARY VIOLATION.
              This run is the 'check' slot, and the 'prep' slot's results file CHANGED while
              it was running: /tmp/overture-prep-results.json
            """
        }.joined(separator: "\n") + "\n"
    }

    // The ordinary state, which must stay silent: a fresh install has no log at all, and a launch that
    // reports a problem every time is a problem nobody reads.
    @Test func noLogSaysNothing() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(RunBoundaryViolations.newlyReported(in: dir, defaults: defaults()) == nil)
    }

    // The first violation is said out loud, and it names the file so Dan can reach the evidence.
    @Test func aFreshViolationIsReportedOnce() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = defaults()
        try violationLine(1).data(using: .utf8)!.write(to: RunBoundaryViolations.url(in: dir))

        let first = RunBoundaryViolations.newlyReported(in: dir, defaults: d)
        #expect(first != nil)
        #expect(first?.contains(RunBoundaryViolations.fileName) == true)

        // Said ONCE. A record that re-announces on every launch and every settle is the shape #884 removed
        // from the ingest, and it teaches Dan to ignore the one message here that means paid work was lost.
        #expect(RunBoundaryViolations.newlyReported(in: dir, defaults: d) == nil)
    }

    // And a SECOND violation, after the first was read, is its own event. Keyed on how many violations the
    // file records rather than on its size, so a rotation or a truncation cannot hide one (L40).
    @Test func aLaterViolationIsReportedAgain() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = defaults()
        let url = RunBoundaryViolations.url(in: dir)
        try violationLine(1).data(using: .utf8)!.write(to: url)
        _ = RunBoundaryViolations.newlyReported(in: dir, defaults: d)

        try violationLine(2).data(using: .utf8)!.write(to: url)

        #expect(RunBoundaryViolations.newlyReported(in: dir, defaults: d) != nil)
    }

    // A file the shell truncated back to nothing is a CHANGE, not a clean slate, so the count moving in
    // either direction is reported rather than only a growth.
    @Test func aTruncatedLogIsNotSilentlyForgiven() throws {
        let dir = try tmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let d = defaults()
        let url = RunBoundaryViolations.url(in: dir)
        try violationLine(2).data(using: .utf8)!.write(to: url)
        _ = RunBoundaryViolations.newlyReported(in: dir, defaults: d)

        try violationLine(1).data(using: .utf8)!.write(to: url)

        #expect(RunBoundaryViolations.newlyReported(in: dir, defaults: d) != nil)
    }

    // The two halves have to agree on one string, and they are in different languages, so nothing but this
    // holds them together: the app looks for the phrase the shell writes.
    @Test func theAppLooksForThePhraseTheRunnerWrites() throws {
        let script = try String(contentsOf: RepoRoot.url.appendingPathComponent("mac/scripts/lib/run-slot.sh"),
                                encoding: .utf8)
        #expect(script.contains(RunBoundaryViolations.marker),
                "the runner no longer writes the phrase the app counts")
        #expect(script.contains(RunBoundaryViolations.fileName),
                "the runner no longer writes the file the app reads")
    }
}
