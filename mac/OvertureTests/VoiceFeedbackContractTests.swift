import Testing
import Foundation
@testable import Overture

// The Swift writer half of the voice-feedback contract (#241). The READER is the Prep Claude Code
// workflow (docs/prep-runbook.md, wired by #242), not code, so there is no second programmatic side
// to assert — this fixture pins what VoiceFeedbackBuilder.encode emits and is the canonical example
// the runbook points the workflow at. A change to VoiceFeedback's shape breaks this test instead of
// the workflow silently reading a file it no longer understands (the #109 class).
@Suite("Voice feedback contract fixtures")
struct VoiceFeedbackContractTests {
    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("fixtures/voice-feedback")
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
                try JSONDecoder().decode(VoiceFeedback.self, from: data)
            }
        }
    }

    private let expected = VoiceFeedback(
        version: 1,
        generatedAt: "2026-06-26T00:00:00Z",
        pairs: [
            VoiceFeedbackPair(
                naturalKey: "aurora-strings|2026-03-10|carnegie-hall",
                discipline: "music",
                originalSubject: "Photographing Aurora Strings at Carnegie Hall",
                originalBody: "Hi, I'd be glad to cover this performance.",
                sentSubject: "Photographing Aurora Strings at Carnegie Hall",
                sentBody: "Hi Maria, I photograph performing arts in New York and would document this run unobtrusively, no flash.",
                sentAt: "2026-03-01T14:30:00Z",
                outcome: "replied"
            )
        ]
    )

    @Test func theCommittedFixtureMatchesWhatTheBuilderEncodes() throws {
        let decoded = try JSONDecoder().decode(VoiceFeedback.self, from: try fixture("v1.json"))
        #expect(decoded == expected)
    }

    @Test func builderOutputRoundTripsThroughTheReader() throws {
        let data = try VoiceFeedbackBuilder.encode(expected)
        let roundTripped = try JSONDecoder().decode(VoiceFeedback.self, from: data)
        #expect(roundTripped == expected)
    }

    // v2 (#392): the pair gains an outcomeRecipientId attributing the win to a specific recipient.
    // Still exactly one pair per show (the body is shared). v1.json stays byte-identical above as the
    // backward-decode proof (its outcomeRecipientId decodes to nil).
    @Test func theV2FixtureCarriesTheOutcomeRecipientAttribution() throws {
        let decoded = try JSONDecoder().decode(VoiceFeedback.self, from: try fixture("v2.json"))
        #expect(decoded.version == 2)
        #expect(decoded.pairs.count == 1)
        #expect(decoded.pairs.first?.outcomeRecipientId == "erobinson@aurorastrings.example")
        #expect(decoded.pairs.first?.outcome == "booked")
    }

    @Test func theV1FixtureStillDecodesWithoutTheDiscriminator() throws {
        let decoded = try JSONDecoder().decode(VoiceFeedback.self, from: try fixture("v1.json"))
        #expect(decoded.pairs.first?.outcomeRecipientId == nil)
        #expect(decoded.pairs.first?.kind == nil)            // pre-v3 pairs carry no kind tag
    }

    // v3 (#463): a reply Dan edited and sent is its own lesson, tagged kind "reply", so the distiller
    // learns the reply register apart from cold openers. The file may carry both kinds; a cold pair still
    // omits the tag (nil = cold), keeping older readers and the v1/v2 fixtures byte-compatible.
    @Test func theV3FixtureCarriesAReplyKindPairAlongsideACold() throws {
        let decoded = try JSONDecoder().decode(VoiceFeedback.self, from: try fixture("v3.json"))
        #expect(decoded.version == 3)
        let reply = decoded.pairs.first { $0.kind == "reply" }
        let cold = decoded.pairs.first { $0.kind == nil }
        #expect(reply?.outcomeRecipientId == "erobinson@aurorastrings.example")
        #expect(reply?.outcome == "booked")
        #expect(cold != nil)                                 // a kindless cold pair coexists
    }
}
