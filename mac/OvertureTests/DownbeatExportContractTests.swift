import Testing
import Foundation

// The Downbeat-export contract (#113). Used to also be decoded by a TypeScript mirror
// (downbeatExportContract.test.ts) against the same committed fixtures, so a format change one
// reader hadn't caught up to would fail here or there instead of silently treating every client
// as cold in production (the #109 regression); that mirror was retired in #493 once the app was
// confirmed to scout natively, so the app is now the only reader. blockedDates is consumed
// elsewhere on the Swift side, so this reader only pins clients/venues/bookings.
@Suite("Downbeat export contract fixtures")
struct DownbeatExportContractTests {
    // The fixtures live at <repo>/fixtures/downbeat-export, shared with the TS suite. Resolve
    // them from this test file's source path so no bundle-resource wiring is needed.
    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("fixtures/downbeat-export")
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
    }

    private func fixtureFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)
            .filter { $0.hasSuffix(".json") }
    }

    // #491: enumerates whatever is actually committed, so a new fixture file with no matching
    // decode case fails here instead of silently shipping with zero coverage on this side.
    @Test func decodesEveryCommittedFixtureWithoutThrowing() throws {
        let names = try fixtureFileNames()
        #expect(!names.isEmpty)
        for name in names {
            let data = try fixture(name)
            #expect(throws: Never.self) {
                try DownbeatBridge.decode(data)
            }
        }
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

        // #156: the Swift reader must decode blockedDates (the TS side already does), so the
        // scout can suppress already-booked days. Same set the TS contract test asserts.
        #expect(export.blockedDates == ["2026-03-10", "2026-03-11", "2026-03-12", "2026-04-02"])
    }

    @Test func decodesTheV1FixtureToTheAgreedLogicalShape() throws {
        let export = try DownbeatBridge.decode(try fixture("v1.json"))
        #expect(export.version == 1)
        #expect(export.clients.count == 1)
        #expect(export.venues.count == 1)
        #expect(export.bookings.isEmpty)   // no bookings key in a v1 file
        #expect(export.blockedDates.isEmpty)   // v1 predates blockedDates
    }
}
