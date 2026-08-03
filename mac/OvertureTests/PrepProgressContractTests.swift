import Testing
import Foundation

// The Swift reader half of the Prep progress contract (#354). The WRITERS are
// mac/scripts/prep-run.sh (seeds total/completed:0) and the Prep Claude Code workflow
// (docs/prep-runbook.md, updates completed as it finishes each item), neither of which is
// Swift, so there is no second programmatic side to assert. This fixture pins the Swift
// decode and is the canonical example the runbook points the workflow at.
@Suite("Prep progress contract fixtures")
struct PrepProgressContractTests {
    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("fixtures/prep-progress")
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
    }

    private func fixtureFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)
            .filter { $0.hasSuffix(".json") }
    }

    // #491/#744: enumerates whatever is actually committed, so a new fixture file with no
    // matching decode case fails here instead of silently shipping with zero coverage on this side.
    @Test func decodesEveryCommittedFixtureWithoutThrowing() throws {
        let names = try fixtureFileNames()
        #expect(!names.isEmpty)
        for name in names {
            let data = try fixture(name)
            #expect(throws: Never.self) {
                try PrepProgressDecoder.decode(data)
            }
        }
    }

    @Test func decodesTheV1Fixture() throws {
        let progress = try PrepProgressDecoder.decode(try fixture("v1.json"))
        #expect(progress.version == 1)
        #expect(progress.total == 9)
        #expect(progress.completed == 3)
    }

    @Test func labelFormatsAsNOfM() throws {
        let progress = try PrepProgressDecoder.decode(try fixture("v1.json"))
        #expect(PrepProgressDecoder.label(for: progress) == "3 of 9")
    }

    @Test func labelIsNilWhenTotalIsZero() {
        let progress = PrepProgress(version: 1, total: 0, completed: 0)
        #expect(PrepProgressDecoder.label(for: progress) == nil)
    }

    @Test func labelIsNilForNoProgress() {
        #expect(PrepProgressDecoder.label(for: nil) == nil)
    }

    // Best-effort: a missing or malformed file reads as "nothing to show", never a crash or
    // thrown error surfaced to the toolbar (the workflow may be mid-write when the app polls).
    @Test func loadCurrentReturnsNilForAMissingFile() {
        let missing = URL(fileURLWithPath: "/tmp/overture-prep-progress-does-not-exist-\(UUID()).json")
        #expect(PrepProgressDecoder.loadCurrent(from: missing) == nil)
    }

    @Test func loadCurrentReturnsNilForMalformedJSON() throws {
        let url = URL(fileURLWithPath: "/tmp/overture-prep-progress-malformed-\(UUID()).json")
        try Data("{not valid json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(PrepProgressDecoder.loadCurrent(from: url) == nil)
    }

    // MARK: - Negative paths (#747)
    //
    // The enumeration guard only proves every committed fixture decodes. A guard that cannot fail is
    // not a guard, so these prove a drifted fixture would be caught.
    //
    // This contract has two layers with DELIBERATELY different failure behavior, and the distinction
    // is the thing worth pinning: `decode` is strict and throws, while `loadCurrent` is best-effort
    // and returns nil. That is not an inconsistency. The toolbar reads a file a separate workflow may
    // be writing at that exact instant, so a torn read must degrade to "nothing to show" rather than
    // throw. Anything reading it as a CONTRACT still has to see the failure.

    private func decoding(_ json: String) throws -> PrepProgress {
        try PrepProgressDecoder.decode(Data(json.utf8))
    }

    @Test func aProgressFileMissingARequiredCountIsRejected() {
        #expect(throws: (any Error).self) { try decoding(#"{"version":1,"total":10}"#) }
        #expect(throws: (any Error).self) { try decoding(#"{"version":1,"completed":3}"#) }
        #expect(throws: (any Error).self) { try decoding(#"{"total":10,"completed":3}"#) }
    }

    // A count that arrives as a string rather than a number is exactly the drift a hand-written
    // workflow produces, and it must not decode into a zero.
    @Test func aCountOfTheWrongTypeIsRejectedRatherThanCoercedToZero() {
        #expect(throws: (any Error).self) {
            try decoding(#"{"version":1,"total":"10","completed":"3"}"#)
        }
    }

    // The strict layer throws; the toolbar layer stays silent. Both, on the same bad bytes.
    @Test func theToolbarDegradesToNothingToShowOnTheSameBytesTheContractRejects() throws {
        let torn = #"{"version":1,"total":10,"comple"#   // a half-written file, mid-flush

        #expect(throws: (any Error).self) { try decoding(torn) }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prep-progress-torn-\(UUID().uuidString).json")
        try Data(torn.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(PrepProgressDecoder.loadCurrent(from: url) == nil)
    }
}
