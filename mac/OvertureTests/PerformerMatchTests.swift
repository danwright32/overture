import Testing
import Foundation
@testable import Overture

// Locked spec for the performer-name matcher (#749, plan #748, issue #585). Repeat-client
// detection used to match on the org/group name only, so a performance fronted by someone Dan had
// already shot scored cold whenever the group name was new. HistoryMatch.matchPerformer closes that
// at Prep time. See fixtures/performer-match/README.md for why each property below is load-bearing.
@Suite("Performer-name match locked fixture")
struct PerformerMatchTests {
    private struct Expectation: Decodable {
        let relationship: PriorRelationship
        let downbeatClientId: String?
        let matchedClientName: String?
        let matchedPerformerName: String?
        let emailCorroborated: Bool
    }

    private struct MatchCase: Decodable {
        let name: String
        let performerName: String
        let performerEmail: String
        let production: Production
        let expect: Expectation
    }

    private struct Fixture: Decodable {
        let clients: [DownbeatClient]
        let history: [HistoryRecord]
        let cases: [MatchCase]
    }

    private func fixtureDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("fixtures/performer-match")
    }

    private func fixtureFileNames() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory().path)
            .filter { $0.hasSuffix(".json") }
    }

    private func loadFixture(_ name: String = "v1.json") throws -> Fixture {
        let data = try Data(contentsOf: fixtureDirectory().appendingPathComponent(name))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    // #491/#745: enumerates whatever is actually committed, so a new fixture file with no matching
    // decode case fails here instead of silently shipping with zero coverage on this side.
    @Test func decodesEveryCommittedFixtureWithoutThrowing() throws {
        let names = try fixtureFileNames()
        #expect(!names.isEmpty)
        for name in names {
            #expect(throws: Never.self) { try loadFixture(name) }
        }
    }

    @Test func matchesEveryFixtureCaseTheAgreedWay() throws {
        let fixture = try loadFixture()
        #expect(!fixture.cases.isEmpty)

        for c in fixture.cases {
            let verdict = HistoryMatch.matchPerformer(
                performerName: c.performerName,
                performerEmail: c.performerEmail,
                production: c.production,
                clients: fixture.clients,
                history: fixture.history
            )
            #expect(verdict.relationship == c.expect.relationship, "\(c.name): relationship")
            #expect(verdict.downbeatClientId == c.expect.downbeatClientId, "\(c.name): downbeatClientId")
            #expect(verdict.matchedClientName == c.expect.matchedClientName, "\(c.name): matchedClientName")
            #expect(verdict.matchedPerformerName == c.expect.matchedPerformerName, "\(c.name): matchedPerformerName")
            #expect(verdict.emailCorroborated == c.expect.emailCorroborated, "\(c.name): emailCorroborated")
        }
    }

    // A match Dan will be shown must be able to explain itself; a non-match must not invent a note.
    @Test func onlyAMatchCarriesANoteAndTheNoteNamesThePerformer() throws {
        let fixture = try loadFixture()
        for c in fixture.cases {
            let verdict = HistoryMatch.matchPerformer(
                performerName: c.performerName,
                performerEmail: c.performerEmail,
                production: c.production,
                clients: fixture.clients,
                history: fixture.history
            )
            if verdict.isMatch {
                let note = try #require(verdict.note, "\(c.name): a match must carry a note")
                #expect(note.contains(c.performerName), "\(c.name): the note must name the performer")
            } else {
                #expect(verdict.note == nil, "\(c.name): a non-match must not carry a note")
            }
        }
    }

    // The corroborating email is only worth surfacing when it actually corroborated something.
    @Test func aCorroboratedMatchSaysSoInItsNote() throws {
        let fixture = try loadFixture()
        let verdict = HistoryMatch.matchPerformer(
            performerName: "Marisol Vega",
            performerEmail: "marisol@vegaviolin.com",
            production: .selfProduced,
            clients: fixture.clients,
            history: fixture.history
        )
        #expect(verdict.emailCorroborated)
        #expect(verdict.note?.lowercased().contains("email") == true)
    }

    // The whole point of the tightened rule: the ORG matcher accepts this pair via token
    // containment, and the PERSON matcher must not, or "Jane Doe" warms off "Jane Doe Ensemble".
    @Test func theOrgMatcherAcceptsContainmentThatThePersonMatcherRejects() {
        #expect(GroupNameMatch.isConfident("Jane Doe", "Jane Doe Ensemble"))
        #expect(!GroupNameMatch.isConfidentPersonName("Jane Doe", "Jane Doe Ensemble"))
    }

    // Tightening the person path must not have loosened or altered the org path (#585 scope).
    @Test func theOrgMatcherIsUnchanged() {
        #expect(GroupNameMatch.isConfident("New York Theatre Ballet", "New York Theatre Ballet"))
        #expect(GroupNameMatch.isConfident("Northside Chamber Orchestra", "Northside Chamber"))
        #expect(!GroupNameMatch.isConfident("New York", "New York Theatre Ballet"))
    }

    @Test func personNameMatchingIgnoresTokenOrderButNotExtraTokens() {
        #expect(GroupNameMatch.isConfidentPersonName("Vega, Marisol", "Marisol Vega"))
        #expect(GroupNameMatch.isConfidentPersonName("marisol vega", "Marisol Vega"))
        #expect(!GroupNameMatch.isConfidentPersonName("Marisol Vega", "Marisol Vega Quartet"))
        #expect(!GroupNameMatch.isConfidentPersonName("", "Marisol Vega"))
        #expect(!GroupNameMatch.isConfidentPersonName("Marisol Vega", ""))
    }
}
