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

    @Test func aProbeHistoryThatCannotBeReadIsLeftExactlyAsItIs() throws {
        let url = try temporaryFile("{ this is not json")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = ProbeDurationHistoryStore.record(.init(lookups: 3, streams: 1, seconds: 60), at: url)

        #expect(try String(contentsOf: url, encoding: .utf8) == "{ this is not json")
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
