import Testing
import Foundation

// #3886: `CompiledPattern` grew a capture-group read, so a call site that needs one piece of a match
// no longer has to hand-roll its own `NSRegularExpression` beside the shared type (L370).
//
// `GroupNameMatch.stripProgramSubtitle` is the site that forced it: it reads group 1 to keep the
// presenter and drop the program, and it was building a fresh regex on every name it normalized, on
// the scout's per-comparison path. `DraftCheck` keeps some optionals outside the shared type for the
// same missing capability.
@Suite("CompiledPattern reads a capture group (#3886)")
struct CompiledPatternTests {
    private static let presenterAndProgram = CompiledPattern(#"^(.*?)(?:\s[-]\s|:\s).+$"#)

    @Test func returnsTheCapturedText() {
        #expect(Self.presenterAndProgram.firstCaptureGroup(1, in: "Chamber Music Society: Brahms")
                == "Chamber Music Society")
    }

    // Absent is its own answer, and it is NOT the empty string: a caller reading "" as a capture would
    // silently replace a name with nothing (L215).
    @Test func returnsNilWhenNothingMatches() {
        #expect(Self.presenterAndProgram.firstCaptureGroup(1, in: "Chamber Music Society") == nil)
    }

    // A group index past the end of the pattern is a programming error in a literal, and it must read
    // as absent rather than crash or return the whole match.
    //
    // Index 2 rather than some comfortably larger number, and that is the whole test: this pattern has
    // ONE capture group, so `numberOfRanges` is 2 and index 2 is the FIRST invalid one. An index far past
    // the end is refused by an off-by-one bound as readily as by a correct one, and the first version of
    // this test asked for index 4 and stayed green with the bound loosened to `<=` (L172).
    @Test func returnsNilForTheFirstGroupIndexThePatternDoesNotHave() {
        #expect(Self.presenterAndProgram.firstCaptureGroup(2, in: "Chamber Music Society: Brahms") == nil)
        #expect(Self.presenterAndProgram.firstCaptureGroup(9, in: "Chamber Music Society: Brahms") == nil)
    }

    // A group that did not participate in the match reports NSNotFound for its range, which is a
    // different thing from an out-of-range index and must not be read as a capture of "".
    @Test func returnsNilForAGroupThatDidNotParticipate() {
        let optionalHead = CompiledPattern(#"^(?:(Presented by) )?(.+)$"#)
        #expect(optionalHead.firstCaptureGroup(1, in: "Brooklyn Art Song Society") == nil)
        #expect(optionalHead.firstCaptureGroup(2, in: "Brooklyn Art Song Society") == "Brooklyn Art Song Society")
    }

    // Group 0 is the whole match, which is what NSRegularExpression means by it, so a caller asking for
    // it gets that rather than a refusal.
    @Test func groupZeroIsTheWholeMatch() {
        #expect(Self.presenterAndProgram.firstCaptureGroup(0, in: "Chamber Music Society: Brahms")
                == "Chamber Music Society: Brahms")
    }

    // The two capabilities that already existed, exercised here because nothing else did: this type is
    // the one place the matching and replacing rules are defined, and until now it had no test of its
    // own at all.
    @Test func matchesAndReplacesThroughTheSharedType() {
        let whitespace = CompiledPattern(#"\s+"#)
        #expect(whitespace.matches("two  words"))
        #expect(!whitespace.matches("oneword"))
        #expect(whitespace.replacingMatches(in: "two   words", with: " ") == "two words")
    }
}
