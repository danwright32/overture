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
        RepoRoot.url
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

    // #3193: the gate used to be the exact set [1, 2], so the next bump on the Downbeat side would
    // have thrown here, and `loadWithHealth` answers a throw with empty clients, empty bookings and
    // empty blockedDates. The client roster would have emptied and the scout would have stopped
    // suppressing nights Dan is already shooting, which is a pitch for a night that is taken. The
    // format is additive by contract and Codable ignores keys this struct does not declare, so a
    // version at or above the minimum is read for the keys it does declare.
    // The fixture is deliberately NOT named for any real Downbeat version: nothing here has seen the
    // next one, so it stands for whatever a later bump carries rather than claiming to be a copy of it.
    @Test func decodesAFutureVersionCarryingKeysThisReaderDoesNotDeclare() throws {
        let export = try DownbeatBridge.decode(try fixture("future-version-with-unknown-keys.json"))
        #expect(export.version == 97)
        #expect(export.clients.count == 1)
        #expect(export.clients[0].displayName == "Future Format Chorale")
        #expect(export.venues.count == 1)
        #expect(export.venues[0].name == "Merkin Hall")
        #expect(export.bookings.count == 1)
        #expect(export.bookings[0].shootName == "Season Opener")
        #expect(export.bookings[0].venueName == "Merkin Hall")
        // The half the outage would have cost: a booked night still reaches the scout's blocked set.
        #expect(export.blockedDates == ["2026-09-14"])
    }

    // The other half of #3193, so the gate is seen to refuse as well as accept: a version BELOW the
    // minimum is still a file this reader has no agreement about, and is refused rather than read.
    @Test func aVersionBelowTheMinimumIsStillRefused() throws {
        let ancient = Data(#"{"version":0,"clients":[],"venues":[]}"#.utf8)
        #expect(throws: DownbeatExportError.unsupportedVersion(0)) {
            try DownbeatBridge.decode(ancient)
        }
        let negative = Data(#"{"version":-1,"clients":[],"venues":[]}"#.utf8)
        #expect(throws: DownbeatExportError.unsupportedVersion(-1)) {
            try DownbeatBridge.decode(negative)
        }
    }
}
