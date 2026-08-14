import Testing
import Foundation

// #2722: Dan, 2026-08-14, on a phrase he had seen in several recent preps: "'most audiences don't notice
// I'm there at all'. It implies that some audiences *do* notice."
//
// The instruction was never hedged. Both sources state the claim absolutely, and the weakening is the
// model's own addition, which is the shape L27 names: a rule that lives only in a prompt is a hope. The
// runbook said what to claim and never forbade weakening it, so nothing caught the weakened form.
//
// **What this check is and is not.** It is a TRIPWIRE for the shape already seen in the wild, not coverage
// of the class. A drafter can weaken the same claim fifty ways, and a needle catches the wordings somebody
// thought of (L96). The load-bearing halves are the runbook and the brand voice skill now stating the rule
// in the words that forbid the failure, and the eval scoring real output against it. This is advisory, and
// its value is that the phrasing Dan actually met cannot come back silently.
//
// So it matches a SHAPE rather than a string: any hedge sitting in the same sentence as the
// audience-doesn't-notice claim. That is wider than the one phrase and still narrow enough to have
// somewhere to stand, and the tests below are built as much from what it must PRESERVE as from what it
// must catch (L104).
@Suite("Hedged effect claim")
struct HedgedEffectClaimTests {
    private func issues(_ body: String) -> Set<DraftIssue> {
        Set(DraftCheck.findings(in: body))
    }

    // The sentence Dan read in his own outgoing pitch, from the live handoff file.
    @Test func theSentenceDanObjectedToIsFlagged() {
        let body = "The way I work doesn't distract from what's happening on stage, "
            + "and most audiences don't notice I'm there at all."

        #expect(issues(body).contains(.hedgedEffectClaim))
    }

    // Every other quantifier that weakens the same claim. A needle for one string would pass on all of
    // these while reading as protection.
    @Test func everyQuantifierOnTheClaimIsFlagged() {
        let hedges = ["most audiences don't notice me",
                      "audiences usually don't notice me",
                      "the audience generally doesn't notice me",
                      "people typically don't notice me",
                      "the audience rarely notices me",
                      "hardly anyone notices me",
                      "the audience barely notices me",
                      "for the most part the audience doesn't notice me",
                      "audiences tend not to notice me",
                      "the audience pretty much doesn't notice me",
                      "the audience doesn't really notice me",
                      "the audience doesn't notice me at all"]
        for hedge in hedges {
            #expect(issues("I shoot no-flash documentary coverage, so \(hedge).")
                        .contains(.hedgedEffectClaim), "not flagged: \(hedge)")
        }
    }

    // The wording every shipped fixture uses, and the one the runbook prescribes. If this were flagged the
    // check would fire on every correct draft and be switched off within a day (L93).
    @Test func theCorrectAbsoluteClaimIsNotFlagged() {
        let body = "My name is Dan and I'm a professional arts photographer here in NYC. "
            + "I shoot unobtrusive, no-flash documentary coverage, so the audience doesn't notice me "
            + "and the performance isn't disturbed. "
            + "You can see my portfolio at danwrightphotography.com."

        #expect(!issues(body).contains(.hedgedEffectClaim))
    }

    // A hedge somewhere else in the email is not this rule's business. The rule is about the effect claim,
    // and a body that hedges about scheduling or about whether they already have a photographer is
    // ordinary polite writing.
    @Test func aHedgeAboutSomethingElseIsNotFlagged() {
        let body = "If you don't have someone on it already, I'd be glad to talk about your plans. "
            + "Most of my work is concert and choral. I shoot no-flash documentary coverage."

        #expect(!issues(body).contains(.hedgedEffectClaim))
    }

    // The claim and the hedge must be in the SAME sentence. Two separate correct sentences must not be
    // read as one hedged claim just because both words appear in the body.
    @Test func aHedgeInADifferentSentenceIsNotFlagged() {
        let body = "The audience doesn't notice me. Most of my bookings come from repeat clients."

        #expect(!issues(body).contains(.hedgedEffectClaim))
    }

    // The hedge words are short and common enough to sit inside other words, which is why they are
    // matched whole rather than as substrings like every other needle list in this file. "Almost nobody"
    // is not "most", and "soften" is not "often".
    @Test func aHedgeWordInsideAnotherWordIsNotFlagged() {
        #expect(!issues("The lighting almost never softens, and the audience doesn't notice me.")
                    .contains(.hedgedEffectClaim))
    }

    // Advisory, not blocking. The cost of a wrong block is Dan's time on a draft that reads perfectly, and
    // this matcher is a text rule about tone rather than a fact about the text, which is the bar #789 set
    // for a blocker.
    @Test func theFindingIsAdvisoryRatherThanBlocking() {
        #expect(!DraftIssue.hedgedEffectClaim.isBlocking)
    }

    // Every case has a label, which is what Dan actually reads on the card.
    @Test func theFindingSaysWhatIsWrong() {
        #expect(DraftIssue.hedgedEffectClaim.label
                == "Hedges the claim that the audience doesn't notice him")
    }
}
