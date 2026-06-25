import Testing
import Foundation
@testable import Overture

// The Swift half of the shared Downbeat-export contract (#113). Decodes the SAME committed
// fixtures as src/lib/downbeatExportContract.test.ts and asserts the same logical result, so a
// format change that one reader hasn't caught up to fails here (or there) instead of silently
// treating every client as cold in production (the #109 regression). blockedDates is consumed
// elsewhere on the Swift side, so this reader only pins clients/venues/bookings.
@Suite("Downbeat export contract fixtures")
struct DownbeatExportContractTests {
    // The fixtures live at <repo>/fixtures/downbeat-export, shared with the TS suite. Resolve
    // them from this test file's source path so no bundle-resource wiring is needed.
    private func fixture(_ name: String) throws -> Data {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
        return try Data(contentsOf: repoRoot.appendingPathComponent("fixtures/downbeat-export/\(name)"))
    }

    @Test func decodesTheV2FixtureToTheAgreedLogicalShape() throws {
        let export = try DownbeatBridge.decode(try fixture("v2.json"))
        #expect(export.version == 2)
        #expect(export.clients.count == 2)
        #expect(export.venues.count == 1)
        #expect(export.bookings.count == 2)

        #expect(export.clients[0].id == "11111111-1111-1111-1111-111111111111")
        #expect(export.clients[0].displayName == "Every Voice Choirs")
        // Minimal client: omitted optionals decode to nil.
        #expect(export.clients[1].id == "55555555-5555-5555-5555-555555555555")
        #expect(export.clients[1].shortName == nil)

        #expect(export.bookings[0].venueId == "33333333-3333-3333-3333-333333333333")
        #expect(export.bookings[0].startDate == "2026-03-10")
        // Ad-hoc venue: venueId omitted -> nil; match on venueName.
        #expect(export.bookings[1].venueId == nil)
        #expect(export.bookings[1].venueName == "Pop-up Loft")
    }

    @Test func decodesTheV1FixtureToTheAgreedLogicalShape() throws {
        let export = try DownbeatBridge.decode(try fixture("v1.json"))
        #expect(export.version == 1)
        #expect(export.clients.count == 1)
        #expect(export.venues.count == 1)
        #expect(export.bookings.isEmpty)   // no bookings key in a v1 file
    }
}
