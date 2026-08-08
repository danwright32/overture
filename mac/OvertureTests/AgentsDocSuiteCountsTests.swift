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
