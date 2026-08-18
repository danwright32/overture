import Testing
import Foundation

// #2807: monotony of CONSTRUCTION inside one draft.
//
// Dan, 2026-08-16, reading a real cold pitch: "this draft is a lot of short sentences and doesn't feel
// great". Three of the sentences were long, so length was not it. Three consecutive sentences were built
// the same way (independent clause, comma, "and"/"so", trailing clause) and two of them ended on the same
// "so ..." effect tail. Every sentence was individually compliant, because every drafting rule is scoped
// to ONE sentence and each supplies its own canonical phrasing; nothing governed variety within one email.
//
// WHY THIS DETECTOR AND NOT THE OBVIOUS ONE. The first instinct is to count first-person sentence
// openings, since the draft has six of eight. Measured against Dan's own proven reference pitch (kept in
// the dan-wright-brand-voice skill and reproduced below), that detector refuses it: five of six sentences
// open in first person, three consecutively, a HIGHER rate than the draft he complained about. It would
// have shipped the exact defect already recorded once here, a lint that blocks Dan's own text.
//
// What separates the two texts is construction. Dan's pitch runs compound, simple, compound,
// fronted-subordinate, compound, simple, and no two NEIGHBOURS are built the same way. The bad draft puts
// two "so ..." tails side by side. So the rule is: inside one paragraph, no two consecutive sentences may
// carry the same connector construction.
//
// Paragraph-scoped, deliberately, and that is load-bearing rather than an implementation detail. The
// issue's own reference rewrite, the shape it holds up as correct, splits those two "so" tails across a
// paragraph break and keeps both. A break resets the cadence for a reader, and it is the other half of
// what #2807 asks for ("break the body into short paragraphs"), so a drafter can clear this finding by
// varying the construction OR by paragraphing, and both are the fix.
//
// NO PARAGRAPH-COUNT CHECK EXISTS, and that is measured rather than an omission: Dan's proven reference
// pitch is a SINGLE block of six sentences, so any rule capping sentences per paragraph refuses it. The
// paragraph instruction lives in the runbook and the skill as prose, where it has always lived.
@Suite("Draft cadence: two sentences in a row built the same way (#2807)")
struct DraftCadenceTests {

    // The draft Dan read on 2026-08-16, with the venue renamed (this repo is public and the real room
    // belongs to somebody). The rename touches sentence two only, which is a simple sentence carrying no
    // connector, so the cadence under test is byte-for-byte the one he read.
    static let badDraft = """
    My name is Dan Wright, and I'm an arts photographer here in New York City. I'm getting in touch \
    about your August 18 show at The Lantern Room. I shoot documentary coverage, no flash and nothing \
    posed, so the performance isn't disturbed. I've photographed a few shows in that room, so I'm \
    familiar with the space. I've been a photographer at Carnegie Hall for close to ten years, and the \
    work has also taken me to Madison Square Garden, Lincoln Center, and Radio City Music Hall, along \
    with plenty of other rooms around the city.

    You can see my portfolio at danwrightphotography.com. If you don't have someone on it already, I'd \
    be glad to talk about your photography plans for the night. I look forward to hearing from you!
    """

    // Dan's OWN proven cold pitch, quoted verbatim from the dan-wright-brand-voice skill. Verbatim on
    // purpose: a detector that refuses this text is a defect however well it scores on the bad draft, so
    // rewording it here would throw away the only half of the calibration that can go wrong quietly.
    static let dansReferencePitch = """
    Hello!
    My name is Dan and I'm a professional arts photographer here in NYC. I'm writing in regard to your \
    upcoming concert at Carnegie Hall. I have been a photographer at Carnegie Hall for nearly 10 years \
    and my work has brought me to many other prestigious venues in NYC such as Madison Square Garden, \
    Lincoln Center, and Radio City Music Hall. When you have a moment, I would love to speak about your \
    photography plans for the performance. I invite you to take a look at my portfolio here \
    (www.danwrightphotography.com) and give me an email back. I look forward to hearing from you!
    """

    // The same facts as `badDraft`, rewritten in #2807 as the target shape: the restatement folded into
    // the show reference, the padding cut, and the body broken into three short paragraphs.
    static let theTargetShape = """
    My name is Dan Wright, and I'm an arts photographer here in New York City. I'm getting in touch \
    about your August 18 show at The Lantern Room. It's a room I've photographed a few shows in, so I \
    know the space.

    The work is documentary coverage, no flash and nothing posed, so the performance isn't disturbed. \
    I've been a photographer at Carnegie Hall for close to ten years, and it's also taken me to Madison \
    Square Garden, Lincoln Center, and Radio City Music Hall.

    You can see my portfolio at danwrightphotography.com. If you don't have someone on it already, I'd \
    be glad to talk about your photography plans for the night. I look forward to hearing from you!
    """

    // Calibration, half one: the text Dan objected to.
    @Test("it flags the draft Dan read on 2026-08-16")
    func flagsTheDraftDanObjectedTo() {
        #expect(DraftCheck.findings(in: Self.badDraft).contains(.repeatedSentenceShape))
    }

    // Calibration, half two, and the half that decides whether this ships at all.
    @Test("it passes Dan's own proven cold pitch")
    func passesDansOwnProvenColdPitch() {
        #expect(!DraftCheck.findings(in: Self.dansReferencePitch).contains(.repeatedSentenceShape),
                "a cadence rule that refuses Dan's reference pitch is the defect this repo has shipped before")
    }

    @Test("it passes the rewrite #2807 holds up as the target shape")
    func passesTheTargetShape() {
        #expect(!DraftCheck.findings(in: Self.theTargetShape).contains(.repeatedSentenceShape))
    }

    // A TONE rule by the bar #789 set for a blocker (a fact about the text, never a judgment about its
    // wording), so it warns beside hedgedEffectClaim and asksForNothing rather than stopping the send.
    @Test("it warns rather than blocking the send")
    func itIsAdvisory() {
        #expect(!DraftIssue.repeatedSentenceShape.isBlocking)
        #expect(DraftCheck.blockingFindings(in: Self.badDraft).isEmpty)
        #expect(!DraftCheck.findings(in: Self.badDraft).isEmpty)
    }

    // The paragraph break IS the second fix, so the same two sentences must read differently either side
    // of one. Both halves in one test: a negative alone would pass on a rule that never fires.
    @Test("a paragraph break between two so-tails clears it, one block does not")
    func aParagraphBreakSeparatesTwoTails() {
        let oneBlock = """
        I shoot documentary coverage, no flash and nothing posed, so the performance isn't disturbed. \
        I've photographed a few shows in that room, so I know the space.
        """
        let broken = """
        I shoot documentary coverage, no flash and nothing posed, so the performance isn't disturbed.

        I've photographed a few shows in that room, so I know the space.
        """
        #expect(DraftCheck.findings(in: oneBlock).contains(.repeatedSentenceShape))
        #expect(!DraftCheck.findings(in: broken).contains(.repeatedSentenceShape))
    }

    // Not only the "so" tail: any construction repeated back to back is the same defect, and a rule that
    // knew one shape would pass on every paraphrase while reading as protection (L96).
    @Test("it flags two fronted subordinate clauses in a row")
    func flagsTwoFrontedClauses() {
        let body = """
        When you have a moment, I'd be glad to talk about your photography plans. If you don't have \
        someone on it already, I can send over a few recent galleries.
        """
        #expect(DraftCheck.findings(in: body).contains(.repeatedSentenceShape))
    }

    @Test("it flags the same comma connector twice in a row")
    func flagsTheSameCommaConnectorTwice() {
        let body = """
        I photograph performances here in NYC, but I don't work with flash. The room is one I know, but \
        I'd still come early to walk it.
        """
        #expect(DraftCheck.findings(in: body).contains(.repeatedSentenceShape))
    }

    // The false positive this rule is one careless regex away from. An Oxford comma inside a list is not
    // a clause join, and Dan's own pitch carries one, so a matcher that read it as a connector would
    // refuse his reference text for a reason that has nothing to do with cadence.
    @Test("an Oxford comma in a list is not a connector")
    func anOxfordCommaListIsNotAConnector() {
        let body = """
        I've worked at Madison Square Garden, Lincoln Center, and Radio City Music Hall. My coverage is \
        unobtrusive, quiet, and without flash.
        """
        #expect(!DraftCheck.findings(in: body).contains(.repeatedSentenceShape))
    }

    // The greeting ends in a comma, not in a sentence mark, so a naive split glues it onto the sentence
    // below and donates a comma that invents a construction the sentence does not have. #2545 moved the
    // greeting INSIDE the body, so every draft the app mails now carries one.
    //
    // No blank line between them here, deliberately: that is the shape where it matters, and it is the
    // shape Dan's own reference pitch has ("Hello!" directly above the first sentence). With a blank line
    // the paragraph split separates them anyway and this would prove nothing (it was written that way
    // first, and mutating the filter away left the suite green).
    @Test("a greeting line is not read as part of the first sentence")
    func aGreetingLineIsNotASentence() {
        let body = """
        Hi Emma,
        So you know who's writing, my name is Dan Wright. I've photographed a few shows in that room, \
        so I know the space.
        """
        #expect(!DraftCheck.findings(in: body).contains(.repeatedSentenceShape))
    }

    // Two short simple sentences in a row are not this defect. The rule is about a repeated CONNECTOR
    // CONSTRUCTION, so a sentence carrying no connector can never pair with anything, and Dan's complaint
    // was explicitly not about sentence length.
    @Test("plain sentences with no connector never pair")
    func plainSentencesNeverPair() {
        let body = """
        You can see my portfolio at danwrightphotography.com. I look forward to hearing from you.
        """
        #expect(!DraftCheck.findings(in: body).contains(.repeatedSentenceShape))
    }

    // How often does this fire on the REAL drafted bodies this repo has (L147)? A rule that fires on the
    // ordinary case gets switched off within a day (L93), so the fire rate is asserted rather than hoped
    // for, against the shared corpus of 43 real cold-pitch bodies.
    //
    // The positive control is in the SAME test on purpose (L159): a rule that fired on nothing at all
    // would satisfy the rate assertion perfectly.
    @Test("it fires on almost none of the real drafted bodies")
    func theFireRateOnRealBodiesIsLow() throws {
        let corpus = try DraftAskCasesTests.corpus()
        #expect(corpus.cases.count > 30)
        #expect(DraftCheck.findings(in: Self.badDraft).contains(.repeatedSentenceShape),
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
}
