import Testing
import Foundation

// The shoot-history contract (#1895, part of #1887). The TypeScript importer
// (`scripts/import-shoot-history.ts`) writes `overture-shoot-history.json`; this app reads it.
// The committed fixture is the shared spec, so a format change on one side fails a test rather
// than silently reporting that Dan has never shot anywhere (the #104 / #109 class).
//
// Mirrors LocalHistoryContractTests. Code on both sides, so there is no `fixtureShape.ts` entry:
// that guard exists for the contracts whose other side is a Claude Code workflow.
@Suite("Shoot history contract fixtures")
struct ShootHistoryContractTests {
    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("fixtures/shoot-history")
    }

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
    }

    private func fixtureFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)
            .filter { $0.hasSuffix(".json") }
    }

    // #491's rule: enumerate whatever is actually committed, so a new fixture file with no
    // matching decode case fails here instead of shipping with zero coverage on this side.
    @Test func decodesEveryCommittedFixtureWithoutThrowing() throws {
        let names = try fixtureFileNames()
        #expect(!names.isEmpty)
        for name in names {
            let data = try fixture(name)
            #expect(throws: Never.self) {
                try JSONDecoder().decode(ShootHistoryFile.self, from: data)
            }
        }
    }

    @Test func decodesTheV1FixtureToTheAgreedLogicalShape() throws {
        let file = try JSONDecoder().decode(ShootHistoryFile.self, from: try fixture("v1.json"))
        #expect(file.version == 1)
        #expect(file.shoots.count == 6)
    }

    // The two artifacts the importer deliberately does NOT fold, so this test is what pins the
    // app's obligation to fold them itself. If either stopped arriving, the app's own folding
    // would look unnecessary and could be "tidied" away.
    @Test func theFixtureCarriesTheRawCalendarArtifactsTheAppMustFold() throws {
        let file = try JSONDecoder().decode(ShootHistoryFile.self, from: try fixture("v1.json"))

        // A venue whose address is separated by NEWLINES, not commas. This is the one that
        // matters most: VenueNormalization.keyName splits on the first comma, so unfolded this
        // is a different venue from the plain spelling and The Green Room 42 counts 1, not 2.
        let newlineVenue = try #require(file.shoots.first { $0.venue.contains("\n") })
        #expect(newlineVenue.venue.hasPrefix("The Green Room 42\n"))

        // A venue wrapped in a matched pair of double quotes.
        let quoted = try #require(file.shoots.first { $0.venue.hasPrefix("\"") })
        #expect(quoted.venue.hasSuffix("\""))

        // Both spellings of The Green Room 42 are present, which is what makes the fixture a
        // real test of the fold rather than a demonstration of it.
        #expect(file.shoots.filter { $0.venue.contains("Green Room 42") }.count == 2)
    }

    // The evening-show conversion, pinned by the real 'Round Midnight shoot. The calendar stores
    // it as 2018-06-23T01:15Z; the correct Eastern day is the 22nd. 81 of 381 events shift like
    // this, so a regression here silently mis-dates one shoot in five.
    @Test func datesAreTheEasternDayNotTheUTCDay() throws {
        let file = try JSONDecoder().decode(ShootHistoryFile.self, from: try fixture("v1.json"))
        let roundMidnight = try #require(file.shoots.first { $0.title.contains("Round Midnight") })
        #expect(roundMidnight.date == "2018-06-22")
    }

    // The title carries the bracketed presenter where the calendar has one. It is load-bearing:
    // the count's rehearsal rule and the review card both read it.
    @Test func titlesCarryTheBracketedPresenter() throws {
        let file = try JSONDecoder().decode(ShootHistoryFile.self, from: try fixture("v1.json"))
        #expect(file.shoots.contains { $0.title.hasPrefix("[On Site Opera]") })
    }
}
