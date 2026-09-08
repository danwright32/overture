import Testing
import Foundation

// #3685: the closing hedge pluralises its pronoun on a multi night run and loses its antecedent.
//
// Found 2026-09-07 in a real drafted cold pitch (Cabaret Superstar, The Green Room 42, September 25 to
// October 9), read from the live store's `ZORIGINALDRAFTBODY`, which is the drafter's own output:
//
//   You can see my portfolio at danwrightphotography.com. If you don't already have someone covering
//   THEM, I'd be glad to talk about your photography plans for the run. I look forward to hearing from
//   you!
//
// "them" has nothing to point at. The previous sentence's only nouns are "my portfolio" and a domain;
// the show is named two paragraphs up as a singular "run", and the individual nights are never a noun
// phrase in the email at all.
//
// The failure is at the SEAM of two rules that are each right: the canonical hedge is singular and
// anchored, and the multi night rule requires the RUN to be referenced rather than its opening night.
// The drafter did both correctly and agreed the pronoun with the performances it now had in mind.
@Suite("The closing hedge's pronoun has something to point at (#3685)")
struct DraftHedgeAntecedentTests {

    static let theDraft = """
    Hello,

    I'm Dan Wright, a live performance photographer here in NYC. I'm writing about your Cabaret \
    Superstar run at The Green Room 42, September 25 through October 9.

    You can see my portfolio at danwrightphotography.com. If you don't already have someone covering \
    them, I'd be glad to talk about your photography plans for the run. I look forward to hearing \
    from you!
    """

    @Test("it flags the hedge Dan's real draft carried")
    func flagsTheRealDraft() {
        #expect(DraftCheck.findings(in: Self.theDraft).contains(.hedgePronounHasNoAntecedent))
    }

    // THE HALF THAT DECIDES WHETHER THIS SHIPS. The canonical hedge, from the runbook and the skill,
    // is singular and anchored and must pass; and so must the edit Dan himself made to this very
    // draft, which is his own writing and would be the defect this repo has shipped before.
    @Test("it passes the canonical singular hedge and Dan's own edit")
    func passesTheTextsThatMustPass() {
        let canonical = """
        If you don't have someone on it already, I'd be glad to talk about your photography plans \
        for the night.
        """
        let dansOwnEdit = """
        If nobody's covering it yet, I'd be glad to talk through your photography plans for any of \
        the nights.
        """
        #expect(!DraftCheck.findings(in: canonical).contains(.hedgePronounHasNoAntecedent))
        #expect(!DraftCheck.findings(in: dansOwnEdit).contains(.hedgePronounHasNoAntecedent))
    }

    // "these performances" is a DETERMINER and a noun, not a bare pronoun, and it is one of the two fixed
    // wordings the runbook now recommends. This case is here because the rule got it wrong first: it
    // matched "on these" and reported the REMEDY as the defect.
    //
    // "them" and "they" are never determiners and are matched wherever they appear; "these" and "those"
    // are matched only where they end their clause, which is the only cheap way to tell the pronoun from
    // the determiner. Both halves are asserted, because a rule that simply stopped matching the
    // demonstratives would pass the first expectation for the wrong reason.
    @Test("a determiner before a noun is not a bare pronoun")
    func aDeterminerIsNotAPronoun() {
        let remedy = "If nobody is on these performances yet, I'd be glad to talk about your plans."
        let bare = "If nobody is on these, I'd be glad to talk about your plans."
        #expect(!DraftCheck.findings(in: remedy).contains(.hedgePronounHasNoAntecedent))
        #expect(DraftCheck.findings(in: bare).contains(.hedgePronounHasNoAntecedent))
    }

    // "them" is never a determiner, so it is matched wherever it sits rather than only at a clause end.
    // The lookahead was briefly applied to all four pronouns and this is the case that broke: an adverb
    // or a conjunction after the pronoun is ordinary English.
    @Test("a pronoun followed by an adverb is still a pronoun")
    func anAdverbAfterThePronounIsFine() {
        let body = "If you don't already have someone covering them and it is not too late, I'd be glad to talk."
        #expect(DraftCheck.findings(in: body).contains(.hedgePronounHasNoAntecedent))
    }

    // The fix the runbook and the skill now ask for: name the noun. Both wordings they give.
    @Test("naming the noun clears it")
    func namingTheNounClearsIt() {
        for fixed in ["If you don't already have someone covering the run, I'd be glad to talk about "
                      + "your photography plans.",
                      "If nobody is on these performances yet, I'd be glad to talk about your "
                      + "photography plans."] {
            #expect(!DraftCheck.findings(in: fixed).contains(.hedgePronounHasNoAntecedent))
        }
    }

    // A pronoun that really does have an antecedent is not the defect. This is the whole reason the rule
    // looks for one rather than banning the word: a plural pronoun is correct wherever a plural noun is
    // in reach.
    @Test("a plural pronoun with a real antecedent is fine")
    func aRealAntecedentIsFine() {
        let sameSentence = """
        You have four nights in the run, and if you don't already have someone covering them, I'd be \
        glad to talk about your photography plans.
        """
        let sentenceBefore = """
        The run plays six performances. If you don't already have someone covering them, I'd be glad \
        to talk about your photography plans.
        """
        #expect(!DraftCheck.findings(in: sameSentence).contains(.hedgePronounHasNoAntecedent))
        #expect(!DraftCheck.findings(in: sentenceBefore).contains(.hedgePronounHasNoAntecedent))
    }

    // The reach is the hedge's own sentence and the one before it, and that boundary is the rule rather
    // than an implementation detail: a pronoun reaching further than that is the defect whatever it
    // eventually finds. Asserted with the SAME noun at both distances, so only the distance differs.
    @Test("a noun two sentences back is out of reach")
    func aNounTwoSentencesBackIsOutOfReach() {
        let inReach = """
        The run plays six performances. If you don't already have someone covering them, I'd be glad \
        to talk.
        """
        let outOfReach = """
        The run plays six performances. You can see my portfolio at danwrightphotography.com. If you \
        don't already have someone covering them, I'd be glad to talk.
        """
        #expect(!DraftCheck.findings(in: inReach).contains(.hedgePronounHasNoAntecedent))
        #expect(DraftCheck.findings(in: outOfReach).contains(.hedgePronounHasNoAntecedent))
    }

    // It reads the HEDGE's object and nothing else, so a "them" elsewhere in the draft is not this rule's
    // business and cannot answer it either.
    @Test("a plural pronoun outside the hedge is neither flagged nor an answer")
    func onlyTheHedgesObjectIsRead() {
        let elsewhere = """
        I've photographed several rooms like this and know them well. I'd be glad to talk about your \
        photography plans.
        """
        #expect(!DraftCheck.findings(in: elsewhere).contains(.hedgePronounHasNoAntecedent))
    }

    // The fire rate on the REAL drafted bodies. Measured 2026-09-07 while building this: ZERO of 43. The
    // positive control is in the SAME test (L159), because a rule that fired on nothing at all would
    // satisfy a rate assertion perfectly.
    @Test("it fires on none of the real drafted bodies")
    func itFiresOnNoneOfTheRealBodies() throws {
        let corpus = try DraftAskCasesTests.corpus()
        #expect(corpus.cases.count > 30)
        #expect(DraftCheck.findings(in: Self.theDraft).contains(.hedgePronounHasNoAntecedent),
                "positive control: the rule and this corpus reader both work")
        let fired = corpus.cases.filter {
            DraftCheck.findings(in: $0.body).contains(.hedgePronounHasNoAntecedent)
        }
        #expect(fired.isEmpty, """
            The hedge rule fires on \(fired.count) of \(corpus.cases.count) real drafted bodies:
            \(fired.map(\.name).joined(separator: "\n"))
            """)
    }

    @Test("it warns rather than blocking the send")
    func itIsAdvisory() {
        #expect(!DraftIssue.hedgePronounHasNoAntecedent.isBlocking)
    }
}
