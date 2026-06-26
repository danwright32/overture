import Testing
import Foundation
@testable import Overture

// The Swift reader half of the shared scout-results contract (#157). Decodes the SAME committed
// fixtures the TS writer produces (src/lib/resultsContract.test.ts via buildResultsFile) and
// asserts the same logical result, so a format change one side hasn't caught up to fails here (or
// there) instead of silently breaking ingestion in production (the #109 regression). Mirrors
// DownbeatExportContractTests.
@Suite("Scout results contract fixtures")
struct ResultsContractTests {
    private func fixture(_ name: String) throws -> Data {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
        return try Data(contentsOf: repoRoot.appendingPathComponent("fixtures/scout-results/\(name)"))
    }

    @Test func decodesTheV2FixtureToTheAgreedLogicalShape() throws {
        let file = try ResultsFileDecoder.decode(try fixture("v2.json"))
        #expect(file.version == 2)
        #expect(file.prospects.count == 3)

        // Opening night of a collapsed multi-night run: keeps both nights' sources + closing date.
        let opening = file.prospects[0]
        #expect(opening.groupName == "Aurora Strings")
        #expect(opening.venue == "Carnegie Hall")
        #expect(opening.performanceDate == "2026-03-10")
        #expect(opening.runEndDate == "2026-03-11")
        #expect(opening.partOfRelatedRun == true)
        #expect(opening.runSourceUrls == [
            "https://example.org/aurora-10",
            "https://example.org/aurora-11",
        ])

        // A separate later run of the same group: single night, still flagged related.
        let later = file.prospects[1]
        #expect(later.performanceDate == "2026-03-20")
        #expect(later.runEndDate == nil)
        #expect(later.partOfRelatedRun == true)

        // Undated prospect sorts last; absent optionals decode to nil, no run sources.
        let undated = file.prospects[2]
        #expect(undated.groupName == "Lumen Dance")
        #expect(undated.venue == nil)
        #expect(undated.performanceDate == nil)
        #expect(undated.matchedClientName == nil)
        #expect(undated.possibleMatchName == "Lumen Dance Collective")
        #expect(undated.partOfRelatedRun == false)
        #expect(undated.runSourceUrls.isEmpty)
    }

    @Test func decodesTheV1FixtureWithTolerantDefaults() throws {
        // Pre-#132 shape: run-collapse keys and optional fields omitted. The tolerant version gate
        // accepts it and the decoder defaults the missing fields the importer relies on.
        let file = try ResultsFileDecoder.decode(try fixture("v1.json"))
        #expect(file.version == 1)
        #expect(file.prospects.count == 1)

        let p = file.prospects[0]
        #expect(p.groupName == "Old Format Ensemble")
        #expect(p.venue == nil)
        #expect(p.matchedClientName == nil)
        #expect(p.runEndDate == nil)
        #expect(p.partOfRelatedRun == false)
        #expect(p.runSourceUrls.isEmpty)
    }
}
