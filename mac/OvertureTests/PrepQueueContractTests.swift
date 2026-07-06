import Testing
import Foundation
@testable import Overture

// The Swift writer half of the Prep queue contract (#157). The READER is the Prep Claude Code
// workflow (docs/prep-runbook.md), not code, so there is no second programmatic side to assert —
// this fixture pins what PrepQueueBuilder.encode emits and is the canonical example the runbook
// points the workflow at. The committed fixture must decode to exactly the model the builder
// round-trips, so a change to PrepQueue's shape breaks this test instead of the workflow silently
// reading a work-list it no longer understands (the #109 class).
@Suite("Prep queue contract fixtures")
struct PrepQueueContractTests {
    private func fixture(_ name: String) throws -> Data {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
        return try Data(contentsOf: repoRoot.appendingPathComponent("fixtures/prep-queue/\(name)"))
    }

    // The exact model the v1 fixture encodes: one fully-populated item and one with every optional
    // omitted (decodes to nil), exercising both ends of the contract. v1 predates `production`
    // (#586), so it decodes to nil under the current model — the byte-identical backward-decode proof.
    private let expected = PrepQueue(
        version: 1,
        generatedAt: "2026-06-25T00:00:00.000Z",
        items: [
            PrepQueueItem(
                naturalKey: "aurora-strings|2026-03-10|carnegie-hall",
                groupName: "Aurora Strings",
                venue: "Carnegie Hall",
                performanceDate: "2026-03-10",
                discipline: "music",
                websiteURL: "https://aurorastrings.example",
                sourceListingURL: "https://example.org/aurora-10",
                possibleMatchName: "Aurora Strings",
                priorRelationship: "warm",
                production: nil
            ),
            PrepQueueItem(
                naturalKey: "lumen-dance|undated|none",
                groupName: "Lumen Dance",
                venue: nil,
                performanceDate: nil,
                discipline: "dance",
                websiteURL: nil,
                sourceListingURL: nil,
                possibleMatchName: nil,
                priorRelationship: "cold",
                production: nil
            ),
        ]
    )

    @Test func theCommittedFixtureMatchesWhatTheBuilderEncodes() throws {
        // The fixture decodes to exactly the model the builder writes, pinning the wire shape.
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v1.json"))
        #expect(decoded == expected)
    }

    @Test func builderOutputRoundTripsThroughTheReader() throws {
        // Encode via the real writer, decode back: the contract is symmetric for both optional ends.
        let data = try PrepQueueBuilder.encode(expected)
        let roundTripped = try JSONDecoder().decode(PrepQueue.self, from: data)
        #expect(roundTripped == expected)
    }

    @Test func theBuilderNowStampsVersion2() {
        let q = PrepQueueBuilder.build(from: [], generatedAt: "2026-06-25T00:00:00.000Z")
        #expect(q.version == 2)
    }

    // v2 (#586): the queue item gains an optional `production` (self / agency / unknown, from
    // `Prospect.production`/#349), so the Prep research step knows whether a show is self-produced
    // before deciding whether to pursue a named performer directly (#366 Phase 3). Additive, so the
    // v1 fixture above still decodes with `production` absent (nil).
    @Test func theV2FixtureCarriesTheProductionType() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v2.json"))
        #expect(decoded.version == 2)
        #expect(decoded.items[0].production == "self")
        #expect(decoded.items[1].production == "agency")
    }
}
