import Testing
@testable import Overture

// #11: a deterministic self-check over a drafted email, surfaced before it reaches Dan's
// approval, so review is judgment not cleanup. Catches AI-tells / performative enthusiasm,
// em dashes, and the two stance failures from a real drafting session: presuming the
// booking, or hedging like a cold pitch at a warm/repeat client.
@Suite("Draft self-check")
struct DraftCheckTests {
    @Test func passesTheVersionDanActuallySent() {
        let good = """
        Hi Emma,

        I'm looking forward to being there again this year. If you'd like me to photograph \
        this year's event as well, just say the word.

        Best,
        Dan
        """
        #expect(DraftCheck.findings(in: good).isEmpty)
    }

    @Test func flagsPerformativeEnthusiasmAndExclamations() {
        #expect(DraftCheck.findings(in: "I'd love to photograph this.").contains { $0 == .performativeEnthusiasm })
        #expect(DraftCheck.findings(in: "I'm thrilled and can't wait.").contains { $0 == .performativeEnthusiasm })
        #expect(DraftCheck.findings(in: "Looking forward to it!").contains { $0 == .performativeEnthusiasm })
    }

    @Test func flagsEmDashes() {
        #expect(DraftCheck.findings(in: "I shoot performances — and I'm local.").contains { $0 == .emDash })
    }

    @Test func flagsPresumingTheBooking() {
        #expect(DraftCheck.findings(in: "Happy to lock in the photography plans for the concert.").contains { $0 == .presumesBooking })
        #expect(DraftCheck.findings(in: "I'll plan to cover the performance.").contains { $0 == .presumesBooking })
    }

    @Test func flagsColdHedgeAtAWarmClient() {
        #expect(DraftCheck.findings(in: "If you haven't arranged a photographer yet, I'm available.").contains { $0 == .coldHedge })
    }

    // #456: a draft must never ask the contact for a fact Overture already holds (the date or
    // venue). The deterministic guard fires ONLY when that fact is known; asking is legitimate
    // when Overture doesn't have it.
    @Test func flagsAskingForADateOvertureAlreadyKnows() {
        // The real #438 case that slipped through prompt-only enforcement.
        #expect(DraftCheck.findings(in: "Sounds great. Let me know the date and I'll be there.",
                                    knownsDate: true).contains { $0 == .asksForKnownFact })
        #expect(DraftCheck.findings(in: "When is the show?", knownsDate: true).contains { $0 == .asksForKnownFact })
        #expect(DraftCheck.findings(in: "What day works for you to have me there?", knownsDate: true).contains { $0 == .asksForKnownFact })
    }

    @Test func flagsAskingForAVenueOvertureAlreadyKnows() {
        #expect(DraftCheck.findings(in: "Happy to come. What venue is it at?", knownsVenue: true).contains { $0 == .asksForKnownFact })
        #expect(DraftCheck.findings(in: "Where is the performance being held?", knownsVenue: true).contains { $0 == .asksForKnownFact })
    }

    @Test func doesNotFlagAskingForAFactOvertureDoesNotHave() {
        // No date on file: asking the contact for it is the right thing to do.
        #expect(!DraftCheck.findings(in: "Let me know the date and I'll be there.", knownsDate: false).contains { $0 == .asksForKnownFact })
        #expect(!DraftCheck.findings(in: "What venue is it at?", knownsVenue: false).contains { $0 == .asksForKnownFact })
    }

    @Test func doesNotFlagADraftThatStatesTheKnownFact() {
        // Referencing the date/venue Overture knows is exactly what we want; only ASKING is wrong.
        let good = "I'll be at the Cathedral of St. John the Divine on April 12 to photograph the concert."
        #expect(!DraftCheck.findings(in: good, knownsDate: true, knownsVenue: true).contains { $0 == .asksForKnownFact })
    }

    @Test func knownFactCheckIsOffByDefault() {
        // The legacy single-argument call site keeps its exact behavior: no known-fact context,
        // so the new flag never fires for callers that don't opt in.
        #expect(!DraftCheck.findings(in: "Let me know the date.").contains { $0 == .asksForKnownFact })
    }

    // #458: the #39 / Phase C concession rule, ported from prose in the runbook into code. A cold
    // pitch must never offer a discount or free/complimentary work, and the rate must stay the
    // canonical $250/hr + tax. Instruction-only enforcement is exactly what failed in #438/#456.
    @Test func flagsConcessionLanguage() {
        #expect(DraftCheck.findings(in: "I can offer a discount for this one.").contains { $0 == .concessionLanguage })
        #expect(DraftCheck.findings(in: "Happy to do it for free.").contains { $0 == .concessionLanguage })
        #expect(DraftCheck.findings(in: "I can throw in a complimentary print.").contains { $0 == .concessionLanguage })
        #expect(DraftCheck.findings(in: "My pricing is flexible.").contains { $0 == .concessionLanguage })
    }

    @Test func doesNotFlagFeelFreeAsConcession() {
        // "feel free" is natural warm phrasing, not an offer of free work.
        #expect(!DraftCheck.findings(in: "Feel free to reach out with any questions.").contains { $0 == .concessionLanguage })
    }

    @Test func flagsANonCanonicalRate() {
        #expect(DraftCheck.findings(in: "My rate is $200 an hour.").contains { $0 == .nonCanonicalRate })
        #expect(DraftCheck.findings(in: "It would be $1,500 for the evening.").contains { $0 == .nonCanonicalRate })
    }

    @Test func doesNotFlagTheCanonicalRate() {
        let good = "My rate is $250 an hour plus tax, with a one-hour minimum."
        #expect(!DraftCheck.findings(in: good).contains { $0 == .nonCanonicalRate })
        #expect(!DraftCheck.findings(in: good).contains { $0 == .concessionLanguage })
    }
}
