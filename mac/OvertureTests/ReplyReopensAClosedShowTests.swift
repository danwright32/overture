import Testing
import Foundation
import SwiftData

// #2915, Dan's call 2026-08-17 and again 2026-08-23: a reply arriving AFTER a show has been closed out
// should reopen the show and clear the ending.
//
// WHICH endings, which is the part that had to be settled because this writes over a fact Dan recorded.
// His answer: only "never heard back". That ending's whole content is "nobody ever answered", and a
// reply flatly refutes it. Every other ending records something that HAPPENED, and a later message does
// not make it not have happened: they said no, they said not now, the rate was too high, he turned them
// down, he booked it. A courtesy note, a change of address or a mailing list blast would otherwise
// resurrect a correctly closed show and overwrite his own judgement.
//
// That is the SAME rule `Recipient.reopenOnReply` has held at the contact level since #1840, where only
// `.stoodDown` is cleared and a booking or a real decline stands. This is that rule at the show level,
// written as one function for the same reason: it has to hold wherever a reply is recorded.
//
// ONLY A REPLY NEWER THAN THE ENDING. Without that a reply detected long ago reopens a show Dan closed
// deliberately afterwards, for ever, on every check. That needs `showOutcomeAt`, and a show whose ending
// carries NO stamp is never auto-reopened: refusing is the safe direction, because the alternative is
// overwriting a recorded fact on the strength of a comparison that could not be made. Every ending
// written before this shipped is in that state, and Dan can still reopen any of them by hand.
@Suite("A reply after a close out reopens a show that was closed as never heard back (#2915)")
struct ReplyReopensAClosedShowTests {
    private let closedAt = Date(timeIntervalSince1970: 1_780_000_000)
    private var later: Date { closedAt.addingTimeInterval(86_400) }
    private var earlier: Date { closedAt.addingTimeInterval(-86_400) }

    private func show(closedAs outcome: ShowOutcome?, at stamp: Date?) -> Prospect {
        let p = Prospect(naturalKey: "aurora", groupName: "Aurora Strings", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: "2026-12-01",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .contacted)
        p.showOutcome = outcome
        p.showOutcomeAt = stamp
        return p
    }

    // MARK: - The one ending a reply refutes

    @Test func areplyAfterNeverHeardBackClearsTheEnding() {
        let p = show(closedAs: .neverHeardBack, at: closedAt)
        #expect(p.reopenOnReply(at: later))
        #expect(p.showOutcome == nil, "the show still reads as never heard back after somebody wrote back")
        #expect(p.showOutcomeAt == nil, "the ending is gone and its stamp is not")
    }

    // MARK: - The endings a reply does not refute

    // Exhaustive over the vocabulary rather than a sample, so an ending added later is JUDGED here
    // rather than defaulting into being clearable (L113). Only the one Dan named may go.
    @Test func noOtherEndingIsEverClearedByAReply() {
        for outcome in ShowOutcome.allCases where outcome != .neverHeardBack {
            let p = show(closedAs: outcome, at: closedAt)
            #expect(!p.reopenOnReply(at: later),
                    Comment(rawValue: "a reply cleared \(outcome.rawValue), which records something that happened"))
            #expect(p.showOutcome == outcome,
                    Comment(rawValue: "\(outcome.rawValue) was overwritten by an inbound message"))
        }
    }

    // The two that would be worst, named on their own so the reason is in front of whoever changes this.
    @Test func abookingIsNeverUndoneByAnInboundMessage() {
        let p = show(closedAs: .booked, at: closedAt)
        #expect(!p.reopenOnReply(at: later))
        #expect(p.showOutcome == .booked)
    }

    @Test func danOwnDecisionToTurnThemDownStands() {
        let p = show(closedAs: .turnedThemDown, at: closedAt)
        #expect(!p.reopenOnReply(at: later))
        #expect(p.showOutcome == .turnedThemDown)
    }

    // MARK: - Newer than the ending, or not at all

    // A reply that predates the close out is the evidence Dan already had when he closed it. Reopening on
    // it would undo his decision using the very thing he made it in spite of, on every single check.
    @Test func areplyOlderThanTheEndingDoesNotReopen() {
        let p = show(closedAs: .neverHeardBack, at: closedAt)
        #expect(!p.reopenOnReply(at: earlier))
        #expect(p.showOutcome == .neverHeardBack)
    }

    // An ending with no stamp cannot be compared, so it is left alone. Fail closed: the alternative is
    // overwriting a recorded fact on the strength of a comparison that was never made. Every ending
    // written before this shipped is in exactly this state.
    @Test func anEndingWithNoStampIsNeverAutoReopened() {
        let p = show(closedAs: .neverHeardBack, at: nil)
        #expect(!p.reopenOnReply(at: later))
        #expect(p.showOutcome == .neverHeardBack)
    }

    // A show with no ending has nothing to reopen, and must not report that it did.
    @Test func ashowThatWasNeverClosedOutReportsNoReopen() {
        let p = show(closedAs: nil, at: nil)
        #expect(!p.reopenOnReply(at: later))
    }

    // MARK: - The stamp has a writer (L46 in the other direction)

    // Closing a pitch out records WHEN, or the rule above can never fire for anything closed from now on.
    @Test func closingAPitchOutStampsTheMoment() {
        let source = SourceGuardHelper.source("Overture/UI/ProspectMutations.swift")
        #expect(!source.isEmpty)
        #expect(SourceGuardHelper.containsCode("model.showOutcomeAt = Date()", in: source),
                "recordOutcome closes a pitch and dates nothing, so no ending it writes can ever be auto-reopened (#2915)")
        // And taking an ending back clears its stamp, or a later close-out with no stamp of its own
        // inherits an older one and is compared against the wrong moment.
        #expect(SourceGuardHelper.containsCode("model.showOutcomeAt = nil", in: source),
                "reopenOutcome clears the ending and leaves its stamp behind (#2915)")
    }

    // MARK: - Both halves of the funnel (L30)

    // An inquiry rides this same reply check and is closed out from the same vocabulary, so the rule has
    // to reach it too. Stated only on the prospect, it would have been the half nobody noticed.
    @Test func anInquiryClosedAsNeverHeardBackIsReopenedTheSameWay() {
        let i = Inquiry(source: .contactForm, inquirerName: "Nessa Halloway",
                        inquirerEmail: "nessa@example.com", eventName: "An Evening of Songs",
                        createdAt: closedAt)
        i.showOutcome = .neverHeardBack
        i.showOutcomeAt = closedAt

        #expect(i.reopenOnReply(at: later))
        #expect(i.showOutcome == nil)
        #expect(i.showOutcomeAt == nil)
    }

    @Test func anInquiryEndingThatAReplyDoesNotRefuteStands() {
        let i = Inquiry(source: .contactForm, inquirerName: "Nessa Halloway",
                        inquirerEmail: "nessa@example.com", eventName: "An Evening of Songs",
                        createdAt: closedAt)
        i.showOutcome = .theySaidNo
        i.showOutcomeAt = closedAt

        #expect(!i.reopenOnReply(at: later))
        #expect(i.showOutcome == .theySaidNo)
    }

    // The two models decide through ONE function, so they cannot come to different answers about the
    // same ending (L16).
    @Test func bothModelsDecideThroughTheOneRule() {
        for file in ["Overture/Domain/Prospect.swift", "Overture/Domain/Inquiry.swift"] {
            let source = SourceGuardHelper.source(file)
            #expect(!source.isEmpty)
            #expect(source.contains("ReplyReopen.shouldClear("),
                    Comment(rawValue: "\(file) decides for itself which endings a reply clears (#2915, L16)"))
        }
    }

    // And an inquiry's own close-out dates itself, or the rule can never fire for one.
    @Test func closingAnInquiryOutStampsTheMoment() {
        let source = SourceGuardHelper.source("Overture/UI/InquiryMutations.swift")
        #expect(!source.isEmpty)
        #expect(SourceGuardHelper.containsCode("inquiry.showOutcomeAt = Date()", in: source),
                "an inquiry ending is undateable, so no reply can ever be compared against it (#2915)")
    }

    // MARK: - Built is not wired (L3)

    @Test func thereplyServiceReopensTheShowItJustFoundAReplyOn() {
        let source = SourceGuardHelper.source("Overture/Integration/ReplyService.swift")
        #expect(!source.isEmpty)
        #expect(SourceGuardHelper.containsCode("p.reopenOnReply(at: now)", in: source),
                "a reply reopens the contact and leaves the show closed out (#2915)")
    }
}
