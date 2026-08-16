import Testing
import Foundation

// #2531: the Swift half of one shared judgment.
//
// #1889 put a deterministic check behind the runbook rule that a drafted pitch must actually ask for
// something, and it scored PRODUCED output in the eval only. A draft Dan writes or edits by hand never
// passed through it, so a pitch that admires the show and asks for nothing could still be sent.
//
// Twin implementations in two languages must consume ONE shared committed fixture, or each ends up with
// its own idea of the rule and the two drift silently (L26). `fixtures/draft-ask/cases.json` is that
// fixture, and `src/lib/draftAskCases.test.ts` reads the same file and asserts the same verdicts.
@Suite("The shared ask corpus (#2531)")
struct DraftAskCasesTests {

    struct Corpus: Decodable {
        struct Case: Decodable {
            let name: String
            let from: String
            let asks: Bool
            let body: String
        }
        let version: Int
        let cases: [Case]
    }

    static func corpus() throws -> Corpus {
        let url = RepoRoot.url.appendingPathComponent("fixtures/draft-ask/cases.json")
        return try JSONDecoder().decode(Corpus.self, from: try Data(contentsOf: url))
    }

    // A fixture that came back empty would pass every assertion below it, which is the shape where a
    // guard reports hardest on the thing it can see least of (L98). Both sides are needed too: a corpus
    // of accepts only cannot tell a working rule from one that says yes to everything.
    @Test("the corpus is there, and has both sides")
    func theCorpusIsReal() throws {
        let corpus = try Self.corpus()
        #expect(corpus.cases.count > 30)
        #expect(corpus.cases.contains { $0.asks })
        #expect(corpus.cases.contains { !$0.asks })
    }

    @Test("the app agrees with the corpus on every case")
    func theAppAgrees() throws {
        var disagreed: [String] = []
        for testCase in try Self.corpus().cases where
            DraftCheck.asksAboutPhotographyPlans(testCase.body) != testCase.asks {
            disagreed.append("\(testCase.asks ? "should ask" : "should not ask"): \(testCase.name)")
        }
        #expect(disagreed.isEmpty, """
            The app's ask check disagrees with the shared corpus. The TypeScript eval reads the same file, \
            so one of the two has drifted:
            \(disagreed.joined(separator: "\n"))
            """)
    }

    // The finding itself, not only the predicate behind it: a rule that nothing turns into a warning is
    // a rule Dan never sees (L3).
    @Test("an askless draft raises the finding, and a real one does not")
    func theFindingIsRaised() throws {
        let corpus = try Self.corpus()
        let askless = try #require(corpus.cases.first { !$0.asks })
        let asking = try #require(corpus.cases.first { $0.asks })

        // Every body in the corpus is a COLD pitch, which is the register the rule is about, so the
        // finding is asked for explicitly here. A warm note is covered by `aWarmNoteIsNotAskless` below.
        #expect(DraftCheck.findings(in: askless.body, isColdPitch: true).contains(.asksForNothing))
        #expect(!DraftCheck.findings(in: asking.body, isColdPitch: true).contains(.asksForNothing))
    }

    // Advisory, deliberately. #789's bar for a blocker is a FACT about the text rather than a judgment
    // about its wording, and the runbook tells the run to reword the ask every time, so an unusual but
    // perfectly good phrasing is exactly what a wording rule gets wrong. The cost of a wrong block is
    // Dan's time on the draft he actually wants to send.
    @Test("it warns rather than blocking the send")
    func itDoesNotBlock() throws {
        let askless = try #require(try Self.corpus().cases.first { !$0.asks })
        #expect(!DraftIssue.asksForNothing.isBlocking)
        #expect(!DraftCheck.blockingFindings(in: askless.body).contains(.asksForNothing))
    }

    // The register the rule does NOT apply to, and the reason it is opt-in.
    //
    // This is the real email Dan sent a returning client, from `DraftCheckTests`. It asks for nothing by
    // this rule and is exactly right for who it went to: the runbook's CTA section is about opening a
    // conversation with a stranger. The first version of this check applied to every body and flagged it.
    @Test("a warm note to a returning client is not askless")
    func aWarmNoteIsNotAskless() {
        let warm = """
        Hi Emma,

        I'm looking forward to being there again this year. If you'd like me to photograph \
        this year's event as well, just say the word.

        Best,
        Dan
        """
        #expect(!DraftCheck.findings(in: warm).contains(.asksForNothing),
                "the check must be silent unless the caller says this is a cold pitch")
        #expect(DraftCheck.findings(in: warm, isColdPitch: true).contains(.asksForNothing),
                "and it must still see it as askless when asked, so the gate is the register, not the rule")
    }
}
