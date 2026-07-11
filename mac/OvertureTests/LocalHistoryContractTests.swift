import Testing
import Foundation
@testable import Overture

// The local-history contract (#166). Used to also be read by a TypeScript mirror
// (localHistoryContract.test.ts via parseLocalHistory) decoding the same committed fixture, so a
// format change one reader hadn't caught up to would fail here or there instead of silently
// treating every org as cold in production (the #104 / #109 trap); that mirror was retired in
// #493 once the app was confirmed to scout natively, so the app is now the only reader. This is
// the exact decode ScoutService.loadLocalHistory performs. Mirrors DownbeatExportContractTests.
@Suite("Local history contract fixtures")
struct LocalHistoryContractTests {
    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("fixtures/local-history")
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
                try JSONDecoder().decode([HistoryRecord].self, from: data)
            }
        }
    }

    // #762: the booking sheet's Email column now rides along, so a performer matched through the
    // HISTORY can be corroborated the same way one matched through the Downbeat client list already
    // is. Additive and optional: v1 above has no addresses at all and must still decode, so an
    // existing overture-history.json keeps working without a re-import.
    @Test func decodesTheV2FixtureCarryingContactAddresses() throws {
        let history = try JSONDecoder().decode([HistoryRecord].self, from: try fixture("v2.json"))
        #expect(history.count == 5)

        #expect(history[0].groupName == "Aurora Strings")
        #expect(history[0].email == "hello@aurorastrings.org")

        // A performer filed with their instrument, which is exactly the shape #755 taught the person
        // matcher to read.
        #expect(history[1].groupName == "Kento Hong, violin")
        #expect(history[1].email == "kento@example.com")

        // One cell really can hold two addresses; the app splits them, the importer does not.
        #expect(history[2].email == "a@example.com, b@example.com")

        // An omitted email decodes to nil, not a crash and not an empty string.
        #expect(history[3].email == nil)
        #expect(history[4].email == nil)
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
