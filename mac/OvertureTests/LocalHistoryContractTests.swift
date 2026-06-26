import Testing
import Foundation
@testable import Overture

// The Swift reader half of the shared local-history contract (#166). Decodes the SAME committed
// fixture the TS scout reads (src/lib/localHistoryContract.test.ts via parseLocalHistory) and
// asserts the same logical result, so a format change one reader hasn't caught up to fails here (or
// there) instead of silently treating every org as cold in production (the #104 / #109 trap). This
// is the exact decode ScoutService.loadLocalHistory performs. Mirrors DownbeatExportContractTests.
@Suite("Local history contract fixtures")
struct LocalHistoryContractTests {
    private func fixture(_ name: String) throws -> Data {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
        return try Data(contentsOf: repoRoot.appendingPathComponent("fixtures/local-history/\(name)"))
    }

    @Test func decodesTheV1FixtureToTheAgreedLogicalShape() throws {
        let history = try JSONDecoder().decode([HistoryRecord].self, from: try fixture("v1.json"))
        #expect(history.count == 6)

        #expect(history[0].groupName == "Aurora Strings")
        #expect(history[0].status == "booked")

        // The full status vocabulary the ranker understands, plus a null status (reads as cold).
        #expect(history.map(\.status) == ["booked", "dnc", "lost_soft", "warm", "contacted", nil])

        // An omitted/null status decodes to nil, not a crash or empty string.
        #expect(history[5].groupName == "Unknown Status Co")
        #expect(history[5].status == nil)
    }
}
