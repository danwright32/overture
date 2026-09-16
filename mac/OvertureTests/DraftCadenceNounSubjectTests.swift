import Testing
import Foundation

// #3684: the #2807 cadence rule was blind to a trailing clause whose subject is a plain noun.
//
// `commaJoinedConnector` told a clause join from an Oxford comma with an ALLOWLIST of 20 clause
// subjects, all pronouns and determiners. That test is right when it fires and can only ever recognise
// a clause opening on one of those words, so "live performance is the whole of my photography work" was
// discarded as a suspected list item, the sentence reported no shape, and a nil never pairs.
//
// Note which way it failed: the allowlist was calibrated against what the rule must PRESERVE (Dan's
// venue list, which is in his own reference pitch) and against what it must CATCH (#2807's draft, whose
// trailing clauses all open on I or I'm). The third population, a genuine clause with a noun subject,
// fails GREEN, so the check went on passing while blind and its silence read as a clean draft (L324).
//
// The draft below is VERIFIED rather than reconstructed: read 2026-09-07 from the live store's
// `ZORIGINALDRAFTBODY` for the Cabaret Superstar row, which is the drafter's own output before Dan
// edited it (`draftWrittenByDan` false, `draftModel` opus). The paragraph breaks are the stored ones,
// which matters because `hasRepeatedSentenceShape` is paragraph scoped and the whole case turns on
// those two sentences sharing one paragraph.
@Suite("Draft cadence sees a clause whose subject is a noun (#3684)")
struct DraftCadenceNounSubjectTests {

    // The venue is the real one and stays: it is a room, not a person, and the show and the room are
    // both already named in #3684 in public.
    static let theDraftThatGotThrough = """
    Hello,

    I'm Dan Wright, and live performance is the whole of my photography work here in NYC. I shoot \
    unobtrusive documentary coverage without flash, and I'm writing about your Cabaret Superstar run \
    at The Green Room 42, September 25 through October 9.

    I've photographed a few shows in that room, so I know the space. I've also been a photographer at \
    Carnegie Hall for close to ten years, with work at Madison Square Garden, Lincoln Center, and \
    Radio City Music Hall.

    You can see my portfolio at danwrightphotography.com. If you don't already have someone covering \
    them, I'd be glad to talk about your photography plans for the run. I look forward to hearing \
    from you!
    """

    // THE DEFECT. Two adjacent ", and" trailing clauses in one paragraph, which is exactly the pair
    // #2807 shipped for, and the rule said nothing.
    @Test("it flags the draft #3684 found, two comma-and clauses in one paragraph")
    func flagsTheDraftThatGotThrough() {
        #expect(DraftCheck.findings(in: Self.theDraftThatGotThrough).contains(.repeatedSentenceShape))
    }

    // The narrowest statement of the blind spot, with the two halves side by side so neither can pass on
    // its own. Same construction twice; only the SUBJECT of the trailing clause differs, and only the
    // pronoun version was ever visible.
    @Test("a noun subject and a pronoun subject are both clause joins")
    func aNounSubjectIsAClauseJoinToo() {
        let nouns = """
        I'm Dan Wright, and live performance is the whole of my photography work here in NYC. \
        I shoot documentary coverage, and no flash keeps the room as it was.
        """
        let pronouns = """
        I'm Dan Wright, and I photograph live performance here in NYC. \
        I shoot documentary coverage, and I never use flash.
        """
        #expect(DraftCheck.findings(in: nouns).contains(.repeatedSentenceShape))
        #expect(DraftCheck.findings(in: pronouns).contains(.repeatedSentenceShape))
    }

    // A clause whose head verb is NOT closed-class is reached by the other half of the rule, the Oxford
    // comma test. One comma before the connector cannot be a three-item list, whatever words follow.
    @Test("a clause with a lexical verb is still a clause")
    func aLexicalVerbIsStillAClause() {
        let body = """
        I photograph performances here in NYC, and documentary coverage means the room stays as it is. \
        I have shot that space before, and quiet work suits a house that size.
        """
        #expect(DraftCheck.findings(in: body).contains(.repeatedSentenceShape))
    }

    // THE HALF THAT DECIDES WHETHER THIS SHIPS. A widening that refuses Dan's own writing is the defect
    // this repo has shipped before, and `DraftCadenceTests` says so in its own words. Both of its
    // calibration texts are re-asserted HERE as well as there, because a change to the discriminator is
    // exactly the edit that would move them and this file is where somebody making that edit is looking.
    @Test("it still passes Dan's own proven pitch and #2807's target rewrite")
    func itStillPassesTheTextsThatMustPass() {
        #expect(!DraftCheck.findings(in: DraftCadenceTests.dansReferencePitch)
            .contains(.repeatedSentenceShape))
        #expect(!DraftCheck.findings(in: DraftCadenceTests.theTargetShape)
            .contains(.repeatedSentenceShape))
    }

    // The Oxford comma is still a list, which is the whole reason a discriminator exists. Three shapes:
    // a bare list of proper nouns, a list of adjectives, and the one inside Dan's own credential
    // sentence, where a REAL clause join and a REAL list sit in the same sentence and the clause must
    // win because it comes first.
    @Test("an Oxford comma list is still not a connector")
    func anOxfordCommaListIsStillNotAConnector() {
        let venues = """
        I've worked at Madison Square Garden, Lincoln Center, and Radio City Music Hall. My coverage is \
        unobtrusive, quiet, and without flash.
        """
        #expect(!DraftCheck.findings(in: venues).contains(.repeatedSentenceShape))
        // A list that follows a genuine clause join in the same sentence: the join is what the sentence
        // is shaped by, and it is found first.
        let both = """
        I've been a photographer at Carnegie Hall for close to ten years, and the work has taken me to \
        Madison Square Garden, Lincoln Center, and Radio City Music Hall. I shoot without flash, and \
        the audience stays with the music.
        """
        #expect(DraftCheck.findings(in: both).contains(.repeatedSentenceShape))
    }

    // THE CASE THE FINITE-VERB SIGNAL EXISTS FOR, and it is here because a mutation said so. Removing
    // that signal left the whole suite GREEN: every other case in this file either has one comma (settled
    // by the Oxford test) or follows the connector with a pronoun (settled by `clauseSubjects`), so the
    // second half of the discriminator was shipping untested (L151: every outcome a guard's contract
    // enumerates needs a test that PRODUCES it).
    //
    // What it takes to reach it: TWO commas, so the Oxford test says list, AND a trailing clause whose
    // subject is a bare noun, so the subject list says nothing. Only the verb can tell it from
    // "Madison Square Garden, Lincoln Center, and Radio City Music Hall".
    @Test("a two-comma sentence whose trailing clause has a noun subject is still a clause")
    func aNounSubjectAfterTwoCommasIsStillAClause() {
        let body = """
        I'm Dan Wright, a photographer here in NYC, and live performance is my whole practice.         I work without flash, a documentary approach, and the audience is never asked to notice me.
        """
        #expect(DraftCheck.findings(in: body).contains(.repeatedSentenceShape))
    }

    // A two-comma sentence that is a clause join, not a list: an appositive between the subject and the
    // connector. This is the case an Oxford-comma-count rule ALONE gets wrong, which is why the list
    // reading needs BOTH pieces of evidence rather than either.
    @Test("an appositive before the connector does not make it a list")
    func anAppositiveIsNotAList() {
        let body = """
        I'm Dan Wright, a live performance photographer here in NYC, and I shoot without flash. \
        The room is one I know, and I'd come early to walk it.
        """
        #expect(DraftCheck.findings(in: body).contains(.repeatedSentenceShape))
    }

    // The fire rate on the REAL drafted bodies, asserted here as well as in DraftCadenceTests, because a
    // widening is precisely the change that could push it. Measured 2026-09-07 while building this: 2 of
    // 43, both genuine finds of adjacent ", and" clauses the allowlist missed because the word after
    // "and" was "if". The positive control is in the SAME test (L159): a rule that fired on nothing at
    // all would satisfy a rate assertion perfectly.
    @Test("the widening keeps the fire rate on real drafted bodies low")
    func theFireRateStaysLow() throws {
        let corpus = try DraftAskCasesTests.corpus()
        #expect(corpus.cases.count > 30)
        #expect(DraftCheck.findings(in: Self.theDraftThatGotThrough).contains(.repeatedSentenceShape),
                "positive control: the rule and this corpus reader both work")
        let fired = corpus.cases.filter {
            DraftCheck.findings(in: $0.body).contains(.repeatedSentenceShape)
        }
        let rate = Double(fired.count) / Double(corpus.cases.count)
        #expect(rate < 0.1, """
            The cadence rule fires on \(fired.count) of \(corpus.cases.count) real drafted bodies:
            \(fired.map(\.name).joined(separator: "\n"))
            """)
    }

    // Still ADVISORY. #3684 says so explicitly and the reasoning is unchanged by widening what the rule
    // can see: cadence is a judgement about tone rather than a fact about the text, so a wrong block
    // costs Dan time on a draft that reads fine.
    @Test("it still warns rather than blocking the send")
    func itIsStillAdvisory() {
        #expect(!DraftIssue.repeatedSentenceShape.isBlocking)
        #expect(DraftCheck.blockingFindings(in: Self.theDraftThatGotThrough).isEmpty)
        #expect(!DraftCheck.findings(in: Self.theDraftThatGotThrough).isEmpty)
    }
}
