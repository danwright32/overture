import Testing
import Foundation

// The drafter's instructions and the draft checker must not disagree about the venue history sentence.
//
// Dan, 2026-09-22, looking at a draft flagged "A sentence says the same thing twice": the sentence was
// "I've photographed a few shows at The Green Room 42, so I'm familiar with the room", which is exactly
// what the runbook told the drafter to write. The runbook's wording dated from 2026-07-31; #2949 (Dan,
// 2026-08-16) ruled that clause a restatement and taught `DraftCheck` to flag it, and nothing sent the
// ruling back to the instructions. So every draft that followed the runbook was warned about for following it.
//
// This reads the runbook's own examples through the REAL checker rather than restating the phrase list
// here (L63): each quoted follow-on clause in the venue history section is put after the history claim it
// is written to follow, and none may read as restating itself. A second copy of the checker's trigger
// words in this file would only prove the two copies agree (L70).
@Suite("The runbook's venue history examples pass the draft checker")
struct RunbookVenueHistoryExamplesTests {

    private static let sectionStart = "**Say if Dan already knows the room"

    private func venueHistorySection() throws -> String {
        let runbook = try String(contentsOf: RepoRoot.url.appendingPathComponent("docs/prep-runbook.md"),
                                 encoding: .utf8)
        let start = try #require(runbook.range(of: Self.sectionStart),
                                 "the runbook no longer has the venue history section this test reads")
        let rest = runbook[start.upperBound...]
        // The section ends at the next top level bullet of the drafting rules.
        let end = rest.range(of: "\n- **")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    private func followOnClauses(in section: String) -> [String] {
        let quoted = try! NSRegularExpression(pattern: "\"([^\"]+)\"")
        let ns = section as NSString
        return quoted.matches(in: section, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
            .filter { $0.hasPrefix("so ") }
    }

    @Test func everyFollowOnClauseTheRunbookQuotesPassesTheRestatementCheck() throws {
        let clauses = followOnClauses(in: try venueHistorySection())
        // An empty list would pass everything, so the extraction itself must have found something (L98).
        #expect(!clauses.isEmpty, "found no quoted follow-on clauses in the venue history section")
        for clause in clauses {
            let sentence = "I've photographed a few shows at The Green Room 42, \(clause)."
            #expect(!DraftCheck.findings(in: sentence).contains(.restatesItself),
                    Comment(rawValue: "the runbook quotes a clause the draft checker flags: \(clause)"))
        }
    }
}
