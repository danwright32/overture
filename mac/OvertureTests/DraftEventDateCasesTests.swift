import Testing
import Foundation

// #2864: the shared corpus behind the date rule, the same arrangement #2531 uses for the ask rule.
//
// The judgment lives in two languages: `EventDateInDraft` runs on Dan's screen, and `prepEval`'s twin
// scores what a Prep run produced so a runbook edit that weakens the rule is caught by
// `scripts/eval-prep-runbook.sh` rather than at review time. Two implementations of one rule drift the
// moment either is touched, so both are tested against ONE committed file (L26), and the Swift side is
// the declared source of truth because it is what Dan actually meets.
//
// Half the corpus is the ACCEPT side, in the wordings a good draft really uses, because that is the half
// protecting a correct pitch: a matcher that missed one of them would fire on the common case and be
// switched off within a week (L93, L104, L147).
@Suite("The date rule's shared corpus")
struct DraftEventDateCasesTests {

    private struct Corpus: Decodable {
        struct Case: Decodable {
            var name: String
            var expect: String
            var today: String
            var performanceDate: String
            var runEndDate: String?
            var subject: String?
            var body: String
        }
        var version: Int
        var cases: [Case]
    }

    private func corpus() throws -> Corpus {
        let url = RepoRoot.url.appendingPathComponent("fixtures/draft-event-date/cases.json")
        return try JSONDecoder().decode(Corpus.self, from: try Data(contentsOf: url))
    }

    @Test func everyCaseInTheCorpusGetsTheVerdictItDeclares() throws {
        let corpus = try corpus()
        #expect(corpus.cases.count >= 20)
        for c in corpus.cases {
            let finding = EventDateInDraft.finding(subject: c.subject, body: c.body,
                                                   performanceDate: c.performanceDate,
                                                   runEndDate: c.runEndDate, today: c.today)
            let verdict: String
            switch finding {
            case .none: verdict = "ok"
            case .some(.namesNoDate): verdict = "missing"
            case .some(.namesADifferentDate): verdict = "wrong"
            }
            #expect(verdict == c.expect, "\(c.name): expected \(c.expect), got \(verdict)")
        }
    }

    // A corpus that had drifted to all-accept would pass the test above while proving nothing, so the
    // shape of the corpus itself is asserted: it must exercise all three verdicts, and the accept side
    // has to be the larger half.
    @Test func theCorpusExercisesAllThalderrdictsAndLeansOnTheAcceptSide() throws {
        let cases = try corpus().cases
        let byVerdict = Dictionary(grouping: cases, by: \.expect).mapValues(\.count)
        #expect(byVerdict["ok", default: 0] >= 10)
        #expect(byVerdict["missing", default: 0] >= 2)
        #expect(byVerdict["wrong", default: 0] >= 4)
        #expect(Set(byVerdict.keys) == ["ok", "missing", "wrong"])
    }
}
