import Testing
import Foundation
@testable import Overture

// #281: the DEBUG-only action that copies the live handoff INPUTS into the isolated
// Overture-Debug data folder, so scout/booking/reply features can be exercised against
// realistic data without touching live data. The helper is compiled out of release builds,
// so these tests (always built in Debug) are the only thing that references it.
#if DEBUG
@Suite("Debug seed (#281)")
struct DebugSeedTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("debug-seed-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func planMapsEachInputToASrcAndDestUnderTheRightBase() {
        let live = URL(fileURLWithPath: "/live")
        let debug = URL(fileURLWithPath: "/debug")

        let pairs = DebugSeed.plan(liveBase: live, debugBase: debug)

        #expect(pairs.count == DebugSeed.inputFileNames.count)
        for pair in pairs {
            #expect(pair.src == live.appendingPathComponent(pair.name))
            #expect(pair.dest == debug.appendingPathComponent(pair.name))
        }
    }

    @Test func planOnlyCoversFilesTheAppIngests() {
        // Inputs the app READS (per docs/contracts.md) are seeded; outputs/queues the app WRITES
        // are not, or seeding would clobber live work product into the dev folder.
        #expect(DebugSeed.inputFileNames.contains("downbeat-export.json"))
        #expect(DebugSeed.inputFileNames.contains("overture-results.json"))
        #expect(DebugSeed.inputFileNames.contains("overture-prep-results.json"))
        #expect(DebugSeed.inputFileNames.contains("overture-reply-classify-results.json"))
        #expect(!DebugSeed.inputFileNames.contains("overture-prep-queue.json"))
        #expect(!DebugSeed.inputFileNames.contains("overture-reply-classify-queue.json"))
        #expect(!DebugSeed.inputFileNames.contains("overture-voice-feedback.json"))
    }

    @Test func seedCopiesPresentInputsAndReportsMissingOnes() throws {
        let live = try makeTempDir()
        let debug = try makeTempDir()
        let present = "overture-results.json"
        try "{\"hello\":1}".write(to: live.appendingPathComponent(present), atomically: true, encoding: .utf8)

        let result = try DebugSeed.seed(liveBase: live, debugBase: debug)

        #expect(result.copied == [present])
        #expect(result.missing == DebugSeed.inputFileNames.filter { $0 != present })
        let copied = try String(contentsOf: debug.appendingPathComponent(present), encoding: .utf8)
        #expect(copied == "{\"hello\":1}")
    }

    @Test func seedOverwritesAnExistingDestination() throws {
        let live = try makeTempDir()
        let debug = try makeTempDir()
        let name = "downbeat-export.json"
        try "new".write(to: live.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try "stale".write(to: debug.appendingPathComponent(name), atomically: true, encoding: .utf8)

        _ = try DebugSeed.seed(liveBase: live, debugBase: debug)

        let after = try String(contentsOf: debug.appendingPathComponent(name), encoding: .utf8)
        #expect(after == "new")
    }

    @Test func seedCreatesTheDestinationDirectoryWhenAbsent() throws {
        let live = try makeTempDir()
        let debug = FileManager.default.temporaryDirectory
            .appendingPathComponent("debug-seed-missing-\(UUID().uuidString)", isDirectory: true)
        let name = "overture-history.json"
        try "[]".write(to: live.appendingPathComponent(name), atomically: true, encoding: .utf8)

        let result = try DebugSeed.seed(liveBase: live, debugBase: debug)

        #expect(result.copied == [name])
        #expect(FileManager.default.fileExists(atPath: debug.appendingPathComponent(name).path))
    }
}
#endif
