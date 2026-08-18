import Testing
import Foundation

// #2879, found by the sweep rather than reported: a history file the app could not read was ERASED by
// the next thing that recorded into it.
//
// Both stores were written as `load()` then `recording(...)` then write. `load()` answered an unreadable
// file with an empty history, which is the right answer for a READER (no learned pace either way) and
// catastrophic for the WRITER: the first corrupt or half-written read silently threw away every run ever
// recorded, and the estimate started again from nothing with no symptom at all (L105, the same shape as
// downbeat#165).
@Suite("A duration history is never erased by a read it could not make")
struct DurationHistoryNotErasedTests {

    private func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duration-\(UUID().uuidString).json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func absentFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("duration-absent-\(UUID().uuidString).json")
    }

    @Test func aRunHistoryThatCannotBeReadIsLeftExactlyAsItIs() throws {
        let url = try temporaryFile("{ this is not json")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = RunDurationHistoryStore.record(sources: 4, seconds: 90, at: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "{ this is not json")
    }

    // The run here has to be one the store would ACTUALLY record, or this asserts nothing: the first
    // version used lookups 3 / streams 1, which `isComparable` refuses outright, so the file stayed
    // untouched whatever the refusal did and the test survived deleting the code it exists to guard
    // (L159, seen: the mutation SURVIVED). The control below builds the positive case from the same run.
    @Test func aProbeHistoryThatCannotBeReadIsLeftExactlyAsItIs() throws {
        let url = try temporaryFile("{ this is not json")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = ProbeDurationHistoryStore.record(recordableRun, at: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "{ this is not json")
    }

    // The control for the test above: the same run, against a file that is simply not there, DOES get
    // written. Without this the refusal could be a store that never writes at all.
    @Test func anAbsentProbeHistoryIsStillWrittenFromTheSameRun() throws {
        let url = absentFile()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = ProbeDurationHistoryStore.record(recordableRun, at: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(ProbeDurationHistoryStore.load(from: url) != ProbeDurationHistory())
    }

    // A run the store will genuinely keep: `isComparable` needs at least two lookups, at least two
    // streams, and streams no greater than lookups.
    private var recordableRun: ProbeDurationHistory.Run {
        .init(lookups: 4, streams: 2, seconds: 60, contended: false)
    }

    // The other half, and the reason the refusal above is not simply "never write": an ABSENT file is a
    // different state and there is genuinely nothing to lose, so the first run of a fresh install must
    // still be recorded. A guard that refused both would quietly stop either history ever starting.
    @Test func anAbsentHistoryIsStillWrittenOnTheFirstRun() throws {
        let url = absentFile()
        defer { try? FileManager.default.removeItem(at: url) }

        _ = RunDurationHistoryStore.record(sources: 4, seconds: 90, at: url)

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(RunDurationHistoryStore.load(from: url) != RunDurationHistory())
    }

    // A readable history still accepts new runs: the refusal must not have made the store write-only.
    @Test func areadableHistoryStillRecords() throws {
        let url = absentFile()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = RunDurationHistoryStore.record(sources: 4, seconds: 90, at: url)
        let after = RunDurationHistoryStore.record(sources: 4, seconds: 110, at: url)

        #expect(after != RunDurationHistory())
        #expect(RunDurationHistoryStore.load(from: url) == after)
    }
}
