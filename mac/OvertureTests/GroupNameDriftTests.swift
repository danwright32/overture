import Testing
import Foundation
@testable import Overture

// Locked normalization/matching spec (#492). Used to also guard a TypeScript mirror
// (groupNameMatch.ts), decoding the same committed cases so a one-sided change would fail this
// suite or the TS one instead of silently reclassifying a warm past client as cold with nothing
// catching it (the ~79 percent warm versus ~1.6 percent cold conversion signal); that mirror was
// retired in #493. This suite is now GroupNameMatch.swift's only locked spec, not a
// cross-language drift guard. See fixtures/group-name-match/README.md.
@Suite("Group-name match locked fixture")
struct GroupNameDriftTests {
    private struct NormalizeCase: Decodable {
        let input: String
        let expected: String
    }

    private struct MatchCase: Decodable {
        let a: String
        let b: String
        let confident: Bool
        let possible: Bool
    }

    private struct Fixture: Decodable {
        let normalize: [NormalizeCase]
        let match: [MatchCase]
    }

    private func loadFixture() throws -> Fixture {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests
            .deletingLastPathComponent()   // mac
            .deletingLastPathComponent()   // repo root
        let data = try Data(contentsOf: repoRoot.appendingPathComponent("fixtures/group-name-match/v1.json"))
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    @Test func normalizesEveryFixtureCaseTheAgreedWay() throws {
        let fixture = try loadFixture()
        for c in fixture.normalize {
            #expect(GroupNameMatch.normalize(c.input) == c.expected)
        }
    }

    @Test func matchesEveryFixtureCaseTheAgreedWay() throws {
        let fixture = try loadFixture()
        for c in fixture.match {
            #expect(GroupNameMatch.isConfident(c.a, c.b) == c.confident)
            #expect(GroupNameMatch.isPossible(c.a, c.b) == c.possible)
        }
    }
}
