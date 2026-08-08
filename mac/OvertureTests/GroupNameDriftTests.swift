import Testing
import Foundation

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
        let repoRoot = RepoRoot.url
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

    // #774: normalize strips everything outside a-z, so an accented org name used to shred into junk
    // tokens ("Sinfónica" to "sinf" and "nica") and could never match, silently scoring a real repeat
    // client as a cold lead. This is the ORG path, which #755 deliberately left alone.
    @Test func anAccentedOrgNameMatchesItsPlainSpelling() {
        #expect(GroupNameMatch.normalize("Orquesta Sinfónica") == "orquesta sinfonica")
        #expect(GroupNameMatch.isConfident("Théâtre du Châtelet", "Theatre du Chatelet"))
    }

    // Folding touches combining marks, NOT punctuation, so the long-dash separators that
    // stripProgramSubtitle depends on must survive it. If they didn't, a "Presenter, long dash,
    // Program" name would stop collapsing to just the presenter, and every venue-versus-booking-sheet
    // match would break (#105).
    //
    // The separators are written as escapes, not literal characters, only because the repo's style
    // hook forbids those characters in source: here they are DATA (the thing under test), not prose.
    @Test func foldingLeavesTheDashSeparatorsStripProgramSubtitleNeeds() {
        let emDash = "\u{2014}"
        let enDash = "\u{2013}"

        #expect(GroupNameMatch.normalize("Every Voice Choirs \(emDash) Earth Day Jazz") == "every voice choirs")
        #expect(GroupNameMatch.normalize("Orquesta Sinfónica \(emDash) Gala Nocturna") == "orquesta sinfonica")
        #expect(GroupNameMatch.normalize("Théâtre du Châtelet \(enDash) Saison 2026") == "theatre du chatelet")
    }

    // The shared matcher is also what suppresses do-not-contact orgs, so folding has to help there
    // too: a DNC org whose name carries an accent must still suppress, not silently slip through.
    @Test func anAccentedDoNotContactOrgStillSuppresses() {
        let verdict = HistoryMatch.matchRelationship(
            name: "Théâtre du Châtelet",
            clients: [],
            history: [HistoryRecord(groupName: "Theatre du Chatelet", status: "dnc")])

        #expect(verdict.suppressed)
    }
}
