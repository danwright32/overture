import Testing
import Foundation

// #2949: the two halves of Dan's 2026-08-16 complaint that #2807 did not cover.
//
// That complaint had four parts. #2807 shipped the cadence check, which was the biggest, and with it
// closed the whole thing read as handled while half of it was not. Neither of these is a cadence problem,
// so `repeatedSentenceShape` cannot see them:
//
//   1. A sentence that says one thing twice. "I've photographed a few shows in that room, so I'm familiar
//      with the space" restates its own first half, costing a beat and adding nothing.
//   2. "Room", "space" and "rooms" inside four sentences, plus the padding "along with plenty of other
//      rooms around the city".
//
// Advisory, on the same arm as the cadence rule and calibrated the same way: DAN'S OWN compliant drafts
// must pass. Measured across the 70 compliant bodies in `fixtures/prep-eval` and `fixtures/draft-ask`,
// none mentions the room in more than TWO sentences, and neither flagged phrase appears at all.
@Suite("A cold pitch does not say one thing twice (#2949)")
struct RestatedAndRepeatedWordingTests {

    // The exact sentence Dan objected to.
    @Test func asentenceThatRestatesItsOwnFirstHalfIsFlagged() {
        let body = "I've photographed a few shows in that room, so I'm familiar with the space."
        #expect(DraftCheck.findings(in: body).contains(.restatesItself))
    }

    // The claim on its own is fine, and it is the one the runbook asks for: he knows the room. What the
    // rule objects to is saying it twice in one breath.
    @Test func sayingItOnceIsNotFlagged() {
        for body in ["I've photographed a few shows in that room.",
                     "I'm familiar with the space.",
                     "I've photographed at Carnegie Hall for nearly ten years."] {
            #expect(!DraftCheck.findings(in: body).contains(.restatesItself),
                    Comment(rawValue: "\(body) is one claim, not a restatement"))
        }
    }

    // The padding phrase, which is the same defect at sentence scale: it adds nothing about this show.
    @Test func thepaddingPhraseIsFlagged() {
        let body = "I shoot at the Players Theatre along with plenty of other rooms around the city."
        #expect(DraftCheck.findings(in: body).contains(.restatesItself))
    }

    // Four sentences reaching for the same word, which is what Dan actually counted.
    @Test func thesameWordInFourSentencesIsFlagged() {
        let body = """
        I photograph performing arts in New York and saw you are at the Players Theatre on March 10. \
        It is a room I know well. \
        I shoot unobtrusive, no-flash coverage that suits a space that size. \
        The room stays with the performance rather than noticing a photographer.
        """
        #expect(DraftCheck.findings(in: body).contains(.repeatsOneWord))
    }

    // TWO sentences is the most any real compliant draft does, so two must pass or the rule fires on the
    // ordinary case and gets switched off (L93, L172). Measured across all 70 of them.
    @Test func twoMentionsIsWhatRealDraftsDoAndPasses() {
        let body = """
        I photograph performing arts in New York and saw you are at the Players Theatre on March 10. \
        I shoot unobtrusive, no-flash documentary coverage, which suits a room that size. \
        You can see my portfolio at danwrightphotography.com. \
        I would be glad to talk about your photography plans.
        """
        #expect(!DraftCheck.findings(in: body).contains(.repeatsOneWord))
    }

    // THE calibration, and the thing that makes the two above more than fixtures somebody chose: every
    // compliant body this repo holds has to pass BOTH rules. A rule that fires on Dan's own proven drafts
    // is one he turns off.
    @Test func everyCompliantDraftInTheCorpusPasses() throws {
        let cases = try #require(DraftAskCorpus.acceptingBodies())
        #expect(cases.count > 20, "the corpus came back too small to calibrate against")
        for body in cases {
            let found = DraftCheck.findings(in: body)
            #expect(!found.contains(.restatesItself),
                    Comment(rawValue: "a compliant draft reads as restating itself: \(body.prefix(90))"))
            #expect(!found.contains(.repeatsOneWord),
                    Comment(rawValue: "a compliant draft reads as repeating a word: \(body.prefix(90))"))
        }
    }

    // Both are ADVISORY. They are judgements about wording, which is not the bar #789 set for a blocker,
    // and the cost of a wrong block is Dan's time on a draft that reads fine.
    @Test func neitherRuleEverBlocksASend() {
        #expect(!DraftIssue.restatesItself.isBlocking)
        #expect(!DraftIssue.repeatsOneWord.isBlocking)
    }
}
