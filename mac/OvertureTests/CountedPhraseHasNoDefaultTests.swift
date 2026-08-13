import Testing
import Foundation

// #2586: `ShowOutcome.countedPhrase` was a lookup keyed by the vocabulary with a live `default:` that
// returned `label`, the wording written to be PICKED off a menu rather than counted after a number. Five
// cases were named and the other nine fell through, so a pitched ending added later would have read as
// "3 Never heard back" in the middle of a sentence with nothing going red, because a default is
// indistinguishable from a deliberate choice (L113).
//
// Two gates replace it, and they catch different things. The switch is exhaustive, so adding ANY case
// breaks the build before it can reach a report. These tests are the other half: that the decision the
// build break forces is the RIGHT one, which the compiler cannot judge.
@Suite("A counted phrase is decided per ending, never defaulted (#2586)")
struct CountedPhraseHasNoDefaultTests {

    // The five pitched endings are the ones a lost split counts, so each must carry wording meant for
    // use after a number. A pitched ending added with no phrase would otherwise reach the report.
    @Test func everyPitchedEndingCarriesACountedPhrase() {
        for outcome in ShowOutcome.pitched {
            #expect(outcome.countedPhrase != nil,
                    "\(outcome) is counted in the lost split but has no phrasing for it")
        }
    }

    // The other direction, and the one the old `default:` silently answered wrong: an ending nothing
    // counts must say so by having NO phrase, rather than borrowing the menu label. Enumerates
    // `allCases` so a value added to neither half cannot slip past both checks.
    @Test func anEndingThatIsNeverCountedCarriesNoPhrase() {
        for outcome in ShowOutcome.allCases where !ShowOutcome.pitched.contains(outcome) {
            #expect(outcome.countedPhrase == nil,
                    "\(outcome) is never counted, so a phrase for it is wording nothing reads")
        }
    }

    // The failure path. `lostSplitLine` used to build its fragments with `compactMap`, so an ending with
    // no phrase would have vanished from the split while still being inside the lost TOTAL the split
    // claims to break down: the count and the rows it promises would disagree (L16), and a missing row
    // is far harder to notice than a wrong one. Exercised through `.duplicate`, which genuinely has no
    // counted phrase, because no pitched ending is allowed to lack one.
    @Test func anEndingWithNoCountedPhraseIsStillNamedRatherThanDropped() {
        #expect(OutcomePatterns.lostFragment(count: 3, outcome: .duplicate) == "3 duplicate")
    }

    @Test func anEndingWithACountedPhraseUsesIt() {
        #expect(OutcomePatterns.lostFragment(count: 1, outcome: .neverHeardBack) == "1 never heard back")
    }
}
