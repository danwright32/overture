import Testing
import Foundation
@testable import Overture

// The Swift writer half of the recent-openers contract (#730). The READER is the Prep Claude Code
// workflow (docs/prep-runbook.md §2), not code, so there is no second programmatic side to assert:
// this fixture pins what RecentOpenersBuilder.encode emits and is the canonical example the runbook
// points the workflow at. A change to RecentOpeners' shape breaks this test instead of the workflow
// silently reading a file it no longer understands (the #109 class).
@Suite("Recent openers contract fixtures")
struct RecentOpenersContractTests {
    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("fixtures/recent-openers")
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
    }

    private func fixtureFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)
            .filter { $0.hasSuffix(".json") }
    }

    // #491/#744: enumerates whatever is actually committed, so a new fixture file with no matching
    // decode case fails here instead of silently shipping with zero coverage on this side.
    @Test func decodesEveryCommittedFixtureWithoutThrowing() throws {
        let names = try fixtureFileNames()
        #expect(!names.isEmpty)
        for name in names {
            let data = try fixture(name)
            #expect(throws: Never.self) {
                try JSONDecoder().decode(RecentOpeners.self, from: data)
            }
        }
    }

    private let expected = RecentOpeners(
        version: 1,
        generatedAt: "2026-06-26T00:00:00Z",
        openers: [
            RecentOpener(
                naturalKey: "aurora-strings|2026-03-10|carnegie-hall",
                discipline: "music",
                opener: "I photograph performing arts in New York and saw Aurora Strings.",
                usedAt: "2026-03-01T14:30:00Z"
            )
        ]
    )

    @Test func theCommittedFixtureMatchesWhatTheBuilderEncodes() throws {
        let decoded = try JSONDecoder().decode(RecentOpeners.self, from: try fixture("v1.json"))
        #expect(decoded == expected)
    }

    @Test func builderOutputRoundTripsThroughTheReader() throws {
        let data = try RecentOpenersBuilder.encode(expected)
        let roundTripped = try JSONDecoder().decode(RecentOpeners.self, from: data)
        #expect(roundTripped == expected)
    }

    // The encoded fixture is byte-for-byte what the builder emits (pretty-printed, sorted keys), so a
    // silent formatting drift between the writer and the committed spec is caught here too.
    @Test func theCommittedFixtureIsByteIdenticalToTheEncoder() throws {
        let emitted = try RecentOpenersBuilder.encode(expected)
        let onDisk = try fixture("v1.json")
        // The file ends with a trailing newline for a clean diff; the encoder does not add one.
        #expect(String(data: emitted, encoding: .utf8)! + "\n" == String(data: onDisk, encoding: .utf8)!)
    }

    // MARK: - Negative paths (#747)
    //
    // The enumeration guard only proves every committed fixture decodes. A guard that cannot fail is
    // not a guard, so these prove a drifted fixture would actually be caught. This file feeds the
    // drafter's anti-repetition step, so an opener that quietly loses a field does not crash anything:
    // it silently weakens the very variety the file exists to enforce, which is worse than a crash.

    private func decoding(_ json: String) throws -> RecentOpeners {
        try JSONDecoder().decode(RecentOpeners.self, from: Data(json.utf8))
    }

    @Test func anOpenerMissingARequiredFieldIsRejected() {
        // Every field is required: opener is the shape to avoid and usedAt is the ordering key. An
        // opener without one must not decode into a half-record.
        let noOpener = """
        {"version":1,"generatedAt":"now","openers":[
          {"naturalKey":"k","discipline":"music","usedAt":"2026-07-01T00:00:00Z"}]}
        """
        #expect(throws: (any Error).self) { try decoding(noOpener) }

        let noUsedAt = """
        {"version":1,"generatedAt":"now","openers":[
          {"naturalKey":"k","discipline":"music","opener":"An opener."}]}
        """
        #expect(throws: (any Error).self) { try decoding(noUsedAt) }
    }

    @Test func garbageIsRejectedRatherThanReadAsNoOpeners() {
        #expect(throws: (any Error).self) { try decoding("not json") }
    }
}
