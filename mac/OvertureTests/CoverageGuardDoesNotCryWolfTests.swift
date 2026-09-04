import Testing
import Foundation

// #2974: the two false-alarm shapes `SourceGuardCoverageGuardTests` still had, both closed at a cost
// proportional to the number of ACCUSATIONS rather than to the corpus.
//
// #2953 stopped the guard reading prose as code for function NAMES. Two gaps were left, deliberately,
// and #2974 asked for the lexer's real cost to be MEASURED before either was rejected on it.
//
// MEASURED 2026-09-04, over the whole of OvertureTests, 946 files and 8.5 MB:
//
//   the reading in force (regex over raw text):  0.32s
//   the candidate (strip comments, then regex):  2.48s
//   path literals found: 517 either way, difference 0
//
// So stripping comments from the path half costs about 2.2 seconds of every suite run and finds
// exactly the same set today. Rejecting it on cost was right, and now it is right for a reason
// somebody measured rather than estimated (L32, L316).
//
// The measurement also points at a better answer than either option #2974 offered. The false alarm is
// not "a path appears in a comment", it is "a path appears ONLY in a comment AND the file is gone". So
// the check happens where the accusation is made, on the (currently zero) missing paths, instead of on
// every file. Same for the dictionary shape: the array body is extracted with balanced brackets, so a
// nested dictionary no longer ends the body early.
@Suite("The coverage guard does not cry wolf (#2974)")
struct CoverageGuardDoesNotCryWolfTests {
    // A path quoted only in PROSE, about a file that has since been deleted. The guard used to report it
    // as a stale reference, which is a fault that is not there, and a check that cries wolf is one
    // people learn to ignore (L36).
    // The fixture paths are ASSEMBLED rather than written whole, so this file does not itself read as
    // a set of references to files that do not exist. The guard under test would otherwise accuse its
    // own test, which is the same false alarm wearing the other hat.
    private let gone = "Overture/Domain/" + "Gone.swift"
    private let here = "Overture/Domain/" + "Here.swift"
    private let both = "Overture/Domain/" + "Both.swift"

    @Test func aPathMentionedOnlyInACommentIsNotAStaleReference() {
        let src = """
            // This used to read "\(gone)" before #1 moved it.
            let real = SourceGuardHelper.source("\(here)")
            """
        #expect(SourceGuardCoverageGuardTests.pathIsOnlyInProse(gone, in: src))
        #expect(!SourceGuardCoverageGuardTests.pathIsOnlyInProse(here, in: src))
    }

    // The positive control, and the half that must not be traded away: a path in real code that has gone
    // is still an accusation. Without this the fix could simply be "never accuse" and pass (L159).
    @Test func aPathInCodeIsStillAccusedWhenItIsGone() {
        let src = """
            // \(gone) is discussed here.
            let real = SourceGuardHelper.source("\(gone)")
            """
        #expect(!SourceGuardCoverageGuardTests.pathIsOnlyInProse(gone, in: src))
    }

    // A path in BOTH is in code, so it is judged as code. Anything else would let one comment excuse a
    // genuinely stale reference sitting beside it.
    @Test func aPathInBothProseAndCodeIsJudgedAsCode() {
        let src = """
            // see "\(both)"
            let real = SourceGuardHelper.source("\(both)")
            """
        #expect(!SourceGuardCoverageGuardTests.pathIsOnlyInProse(both, in: src))
    }

    // The WIRING, which is what a unit test of the predicate alone does not reach. On the real tree
    // nothing references a missing path, so the exemption branch never executes and a mutation removing
    // it leaves the suite green (L3). Driven here over a fixture, with `exists` saying no.
    @Test func aStaleReferenceIsReportedAndAProseMentionIsNot() {
        let files = [
            (name: "Real.swift", text: "let real = SourceGuardHelper.source(\"\(gone)\")"),
            (name: "Prose.swift", text: "// once lived at \"\(here)\"\nlet x = 1"),
        ]
        let missing = SourceGuardCoverageGuardTests.staleReferences(in: files) { _ in false }
        #expect(missing.count == 1)
        #expect(missing.first?.contains("Real.swift") == true)
        #expect(missing.first?.contains(gone) == true)
    }

    // And nothing is reported when the files are all there, so the report above is about the paths and
    // not about the fixture (L159).
    @Test func nothingIsReportedWhenEveryPathExists() {
        let files = [(name: "Real.swift", text: "let real = SourceGuardHelper.source(\"\(gone)\")")]
        #expect(SourceGuardCoverageGuardTests.staleReferences(in: files) { _ in true }.isEmpty)
    }

    // The second shape #2974 names: an array whose FIRST element is itself a dictionary. The old
    // extraction ended the body at the first `]`, so `[["a": 1]]` was read as a list of names and the
    // dictionary test never saw the colon that would have excused it.
    @Test func anArrayWhoseFirstElementIsADictionaryIsNotReadAsAListOfNames() {
        let bodies = SourceGuardCoverageGuardTests.arrayLiteralBodies(in: #"let x = [["alpha": 1], ["beta": 2]]"#)
        #expect(bodies.count == 1)
        // An array OF dictionaries has its colons at depth one, so the depth-zero test correctly says
        // this body is not itself a dictionary. What matters to the name sweep is that it holds
        // key/value pairs at all.
        #expect(!SourceGuardCoverageGuardTests.isDictionaryLiteral(bodies[0]))
        #expect(SourceGuardCoverageGuardTests.holdsKeyValuePairs(bodies[0]))
    }

    // And a plain list still reads as one, which is the case the guard exists for.
    @Test func aPlainListOfNamesIsStillReadAsOne() {
        let bodies = SourceGuardCoverageGuardTests.arrayLiteralBodies(in: #"let x = ["alpha", "beta"]"#)
        #expect(bodies.count == 1)
        #expect(!SourceGuardCoverageGuardTests.isDictionaryLiteral(bodies[0]))
        #expect(!SourceGuardCoverageGuardTests.holdsKeyValuePairs(bodies[0]))
    }

    // A nested plain array is one body with its nesting intact, not two truncated ones.
    @Test func aNestedArrayComesBackWhole() {
        let bodies = SourceGuardCoverageGuardTests.arrayLiteralBodies(in: #"let x = [["alpha"], ["beta"]]"#)
        #expect(bodies.count == 1)
        #expect(bodies[0].contains("alpha") && bodies[0].contains("beta"))
    }
}
