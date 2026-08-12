import Testing
import Foundation

// #2232: AGENTS.md may not state the suite's size as a hand-written number.
//
// Both figures it carried had drifted, one by 768 tests. That is worse than an ordinary stale
// number because of what the same document uses them FOR: two paragraphs on, it warns that a scoped
// run can print `** TEST SUCCEEDED **` having executed nothing, and says the way to tell is to check
// what actually ran. A stated total is exactly the reference someone checks against, so a wrong one
// quietly weakens the guard the document is trying to give.
//
// The replacement is a readout `run-tests-locked.sh` prints on every run, so the number is produced
// by the thing it describes and cannot drift. This test is what stops the hand-written one coming
// back the next time somebody wants the figure written down.
//
// It deliberately does NOT check that the counts are CORRECT, because that would be the same defect
// one level up: a test asserting a number in a document is a second hand-maintained copy of it.
@Suite("AGENTS.md states no hand-written suite size (#2232)")
struct AgentsDocSuiteCountsTests {

    // #1993: found through the shared search, which halts loudly if the repo is not there. A doc
    // this could not find would make every assertion below vacuously true, which is #1967's exact
    // failure and the reason the search exists at all.
    private var agentsDoc: String {
        get throws {
            try String(contentsOf: RepoRoot.url.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        }
    }

    // The measurement from 2026-08-02 is the one number allowed to stay, because it is a record of
    // an experiment on a stated date rather than a claim about the suite now (L37). Everything else
    // of the shape "N tests" or "N,NNN tests" is a live claim that will drift.
    private let datedMeasurement = "4802"

    @Test func noLineClaimsATestCountAsCurrentFact() throws {
        let doc = try agentsDoc
        let pattern = try NSRegularExpression(pattern: #"[\d,]{3,}\s+tests"#)
        let range = NSRange(doc.startIndex..., in: doc)

        var offenders: [String] = []
        pattern.enumerateMatches(in: doc, range: range) { match, _, _ in
            guard let match, let r = Range(match.range, in: doc) else { return }
            let text = String(doc[r])
            guard !text.replacingOccurrences(of: ",", with: "").hasPrefix(datedMeasurement) else { return }
            offenders.append(text)
        }

        #expect(offenders.isEmpty, """
            AGENTS.md states a test count as a current fact: \(offenders).
            Measured numbers are generated or omitted, never hand-written (L32). The suite reports \
            its own size on every run of mac/scripts/run-tests-locked.sh ("Suite shape: ..."), so \
            point at that instead of writing the figure down here.
            """)
    }

    // The other half of the same claim: the readout has to be described, or a reader who wants the
    // number has nowhere to go and will simply write one back in. A rule that removes something
    // without naming its replacement gets undone (L80).
    @Test func theDocPointsAtTheRunsOwnReadout() throws {
        let doc = try agentsDoc
        #expect(doc.contains("Suite shape:"))
    }
}

// The four words the merge gate matches are named in AGENTS.md, derived from the gate itself.
//
// `scripts/lib/pr-completeness-guard.sh` refuses a PR whose body does not contain each of four short
// tokens. It matches the WORD, never the answer, so a body that answers all four questions in other
// words is refused: PR #2526 answered the first one under the heading "the code path that WRITES it"
// and was turned away for not saying "writer". Dan's call, 2026-08-11: the gate stays exactly as
// strict as it is, and AGENTS.md tells authors which words it matches, since the alternative
// (accepting stems) would let an incidental mention anywhere in the body count as an answer.
//
// Derived from the script rather than listed here, because a hand-kept copy of another file's list
// only ever checks what somebody remembered (L41, L96). A fifth item added to the gate without a
// word in AGENTS.md is exactly the drift this catches, and it is the case that cannot be noticed by
// reading either file alone.
@Suite("AGENTS.md names the words the merge gate matches (#2526)")
struct AgentsDocNamesGateWordsTests {

    private func gateTokens() throws -> [String] {
        let url = RepoRoot.url.appendingPathComponent("scripts/lib/pr-completeness-guard.sh")
        let script = try String(contentsOf: url, encoding: .utf8)
        guard let open = script.range(of: "PR_COMPLETENESS_ITEMS=("),
              let close = script.range(of: ")", range: open.upperBound..<script.endIndex) else {
            Issue.record("could not find PR_COMPLETENESS_ITEMS in the guard script")
            return []
        }
        return script[open.upperBound..<close.lowerBound]
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"")) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    @Test func everyWordTheGateMatchesIsNamedInTheDoc() throws {
        let tokens = try gateTokens()
        #expect(tokens.count >= 4, "parsed \(tokens.count) tokens from the guard, expected its full list")

        let doc = try String(contentsOf: RepoRoot.url.appendingPathComponent("AGENTS.md"), encoding: .utf8)
            .lowercased()
        let missing = tokens.filter { !doc.contains($0.lowercased()) }

        #expect(missing.isEmpty, """
            The merge gate refuses a PR body that does not contain \(missing), and AGENTS.md never \
            says so. The gate matches the WORD and not the answer, so an author who answers the \
            question in other words is turned away with no way to know which word was wanted. Name \
            it in the PR body enumeration in AGENTS.md, or take it out of the gate.
            """)
    }
}
