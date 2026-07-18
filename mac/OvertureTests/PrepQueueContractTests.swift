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
    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("fixtures/prep-queue")
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
                try JSONDecoder().decode(PrepQueue.self, from: data)
            }
        }
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

    @Test func theBuilderNowStampsVersion4() {
        let q = PrepQueueBuilder.build(from: [], generatedAt: "2026-06-25T00:00:00.000Z")
        #expect(q.version == 4)
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

    // v3 (#367): the queue item gains an optional `reprepMode` ("draft_only" / "contacts_only",
    // absent means both), so the Prep run knows to skip the corresponding half for a prospect Dan
    // asked to re-prep. Additive, so the v1/v2 fixtures above still decode with it absent (nil).
    @Test func theV3FixtureCarriesTheReprepMode() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v3.json"))
        #expect(decoded.version == 3)
        #expect(decoded.items[0].reprepMode == "draft_only")
        #expect(decoded.items[1].reprepMode == "contacts_only")
    }

    // v4 (#1122): the queue item gains `runEndDate` (the run's closing night) and `openingNightPassed`
    // (true only for a run whose opening night has passed while later dates remain), so the Prep run can
    // pitch the whole run and never reference a gone opening night. Additive, so v1-v3 fixtures still
    // decode with both absent (nil).
    @Test func theV4FixtureCarriesTheRunRangeAndPassedOpening() throws {
        let decoded = try JSONDecoder().decode(PrepQueue.self, from: try fixture("v4.json"))
        #expect(decoded.version == 4)
        #expect(decoded.items[0].runEndDate == "2026-03-14")
        #expect(decoded.items[0].openingNightPassed == true)
        // The second item is single-night with no passed opening: both fields absent.
        #expect(decoded.items[1].runEndDate == nil)
        #expect(decoded.items[1].openingNightPassed == nil)
    }

    // MARK: - Negative paths (#747)
    //
    // The enumeration guard only proves every committed fixture decodes. A guard that cannot fail is
    // not a guard, so these prove a DRIFTED fixture would actually be caught rather than waved
    // through. The app writes this file, so the risk is not a hostile input: it is a fixture quietly
    // losing a field that the Prep run (a Claude Code workflow, not code) depends on, with the guard
    // reporting green the whole time.

    private func decoding(_ json: String) throws -> PrepQueue {
        try JSONDecoder().decode(PrepQueue.self, from: Data(json.utf8))
    }

    // naturalKey is the OPAQUE token the run must echo back verbatim into PrepResults; rebuilding it
    // is the documented silent-mismatch trap. An item without one is unusable.
    @Test func anItemMissingItsNaturalKeyIsRejected() {
        let keyless = """
        {"version":3,"generatedAt":"now","items":[
          {"groupName":"G","discipline":"music","priorRelationship":"none"}]}
        """
        #expect(throws: (any Error).self) { try decoding(keyless) }
    }

    @Test func anItemMissingARequiredResearchFieldIsRejected() {
        // groupName is what the Prep run actually researches; without it the item is a dead token.
        let nameless = """
        {"version":3,"generatedAt":"now","items":[
          {"naturalKey":"k","discipline":"music","priorRelationship":"none"}]}
        """
        #expect(throws: (any Error).self) { try decoding(nameless) }
    }

    // production and reprepMode are genuinely optional (v2/v3 additions), so their absence must NOT
    // be an error. This pins the line between "optional by design" and "missing and broken".
    @Test func theOptionalV2AndV3FieldsMayBeAbsent() throws {
        let minimal = """
        {"version":3,"generatedAt":"now","items":[
          {"naturalKey":"k","groupName":"G","discipline":"music","priorRelationship":"none"}]}
        """
        let decoded = try decoding(minimal)
        #expect(decoded.items[0].production == nil)
        #expect(decoded.items[0].reprepMode == nil)
        // v4 (#1122) fields are optional too: a minimal item omits them and decodes to nil.
        #expect(decoded.items[0].runEndDate == nil)
        #expect(decoded.items[0].openingNightPassed == nil)
    }

    @Test func garbageIsRejectedRatherThanReadAsAnEmptyQueue() {
        #expect(throws: (any Error).self) { try decoding("not json") }
    }
}
