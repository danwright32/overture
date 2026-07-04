import Testing
import Foundation
@testable import Overture

// The shared cross-language drift guard (#492). Decodes the SAME committed cases the TypeScript
// side asserts (src/lib/groupNameMatchContract.test.ts) against this side's own implementation,
// so a one-sided change to normalization or matching fails this suite (or the TS one) instead of
// silently reclassifying a warm past client as cold with nothing catching it (the ~79 percent
// warm versus ~1.6 percent cold conversion signal). See fixtures/group-name-match/README.md.
@Suite("Group-name match cross-language fixture")
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
