import Testing
import Foundation
import SwiftData

// #2400, phase 7 of docs/plans/2026-08-09-one-outcome-vocabulary.md.
//
// An inbound inquiry had its own three reasons, which were already three of the five under different
// spellings. The precedent was already in the code: `neverHeardBack` was deliberately given one shared
// stored value across both halves of the funnel so the two could be added together. This finishes that job
// for the other two, so a season report reads one column in one pass instead of reconciling two
// vocabularies for the same dozen facts.
//
// Decided with Dan on 2026-08-09 when asked directly.
@MainActor
@Suite("An inquiry ends in the same words a show does (#2400)")
struct InquiryEndingsTests {

    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                                     DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private func inquiry(_ ctx: ModelContext, name: String = "Ada Whitfield") -> Inquiry {
        let i = Inquiry(source: .contactForm, inquirerName: name, inquirerEmail: "ada@example.org",
                        eventName: "Winter Gala", performanceDate: "2026-12-04", venue: "Merkin Hall",
                        notes: nil)
        ctx.insert(i)
        return i
    }

    // MARK: one vocabulary, both halves

    // The four ways an inquiry ends badly are the four a pitch ends badly. Asserted against the shared
    // list rather than a copy of it, so adding a value to one half cannot leave the other behind.
    @Test func theEndingsOfferedAreTheSharedOnes() {
        #expect(InquiryEnding.danCanChoose == ShowOutcome.pitched.filter { $0 != .booked })
    }

    // A booking has its own control on the row, so it is deliberately not in the lost list, but it is the
    // same stored value a booked show carries: the report has to be able to add them.
    @Test func abookingIsTheSameValueOnBothHalves() throws {
        let ctx = try context()
        let i = inquiry(ctx)

        InquiryMutations.mark(i, as: .booked, context: ctx, feedback: ActionFeedback())

        #expect(i.showOutcome == .booked)
        #expect(i.outcome == .booked)
    }

    @Test func everyEndingIsStoredOnTheOneField() throws {
        for ending in InquiryEnding.danCanChoose {
            let ctx = try context()
            let i = inquiry(ctx)

            InquiryMutations.mark(i, as: .lost(ending), context: ctx, feedback: ActionFeedback())

            #expect(i.showOutcome == ending)
        }
    }

    // The same value spells the same on both halves of the funnel. This is the property that lets a season
    // report add a lost pitch and a lost inquiry together, and it is the whole reason the vocabulary is
    // shared rather than merely similar.
    @Test func thestoredSpellingMatchesTheShowSide() throws {
        let ctx = try context()
        let i = inquiry(ctx)
        InquiryMutations.mark(i, as: .lost(.theySaidNo), context: ctx, feedback: ActionFeedback())

        #expect(i.showOutcomeRaw == ShowOutcome.theySaidNo.rawValue)
    }

    // Marking a previously-lost inquiry booked clears the stale ending, or the year-end total would count
    // the same inquiry in two groups.
    @Test func markingItBookedClearsAStaleEnding() throws {
        let ctx = try context()
        let i = inquiry(ctx)
        InquiryMutations.mark(i, as: .lost(.neverHeardBack), context: ctx, feedback: ActionFeedback())

        InquiryMutations.mark(i, as: .booked, context: ctx, feedback: ActionFeedback())

        #expect(i.showOutcome == .booked)
    }

    // MARK: what the reporting reads

    // Dan's own answer always wins. An inquiry closed before the answer was captured falls back to what the
    // timestamps can honestly support, so it still lands in the lost column rather than vanishing.
    @Test func thereportingReadsTheStatedEnding() throws {
        let ctx = try context()
        let i = inquiry(ctx)
        InquiryMutations.mark(i, as: .lost(.turnedThemDown), context: ctx, feedback: ActionFeedback())

        #expect(InquiryReporting.ending(for: i) == .turnedThemDown)
    }

    @Test func aclosedInquiryWithNoStatedEndingFallsBackToSilence() throws {
        let ctx = try context()
        let i = inquiry(ctx)
        i.outcome = .lostSoft   // closed by a build that never captured a reason

        #expect(InquiryReporting.ending(for: i) == .neverHeardBack)
    }

    @Test func anopenInquiryHasNoEnding() throws {
        let ctx = try context()
        let i = inquiry(ctx)

        #expect(InquiryReporting.ending(for: i) == nil)
        #expect(i.showOutcome == nil)
    }

    // MARK: carrying the old three across

    @Test func theyDeclinedBecomesTheySaidNo() throws {
        let ctx = try context()
        let i = inquiry(ctx)
        i.lostReasonRaw = "they_declined"
        i.outcome = .lostHard

        _ = ShowOutcomeBackfill.runForInquiries(in: ctx)

        #expect(i.showOutcome == .theySaidNo)
    }

    // "Not a fit for me" was DAN'S pass, not their refusal, so it becomes the ending that says so. Reading
    // it as `theySaidNo` would record a refusal nobody made, and would then teach the reporting that an
    // inquirer turned him down when in fact he turned them down.
    @Test func notAFitForMeBecomesTurnedThemDown() throws {
        let ctx = try context()
        let i = inquiry(ctx)
        i.lostReasonRaw = "not_a_fit"
        i.outcome = .lostSoft

        _ = ShowOutcomeBackfill.runForInquiries(in: ctx)

        #expect(i.showOutcome == .turnedThemDown)
    }

    // The one that already shared its stored value carries across unchanged, which is the point: it was
    // right all along and this is the rest of the vocabulary catching up to it.
    @Test func neverHeardBackCarriesAcrossUnchanged() throws {
        let ctx = try context()
        let i = inquiry(ctx)
        i.lostReasonRaw = "never_heard_back"
        i.outcome = .lostSoft

        _ = ShowOutcomeBackfill.runForInquiries(in: ctx)

        #expect(i.showOutcome == .neverHeardBack)
    }

    @Test func abookedInquiryComesAcrossAsBooked() throws {
        let ctx = try context()
        let i = inquiry(ctx)
        i.outcome = .booked

        _ = ShowOutcomeBackfill.runForInquiries(in: ctx)

        #expect(i.showOutcome == .booked)
    }

    // An OPEN inquiry is not an ending. Somebody is waiting on a reply, and closing it here would take it
    // off the queue that exists to stop that being forgotten.
    @Test func anopenInquiryIsLeftOpen() throws {
        let ctx = try context()
        let i = inquiry(ctx)

        let result = ShowOutcomeBackfill.runForInquiries(in: ctx)

        #expect(i.showOutcome == nil)
        #expect(result.leftOpen == 1)
    }

    // A closed inquiry with no recorded reason gets the honest fallback rather than nothing, so it stays in
    // the year-end total. This mirrors what the reporting already did with the same fallback.
    @Test func aclosedInquiryWithNoReasonIsRecordedAsSilence() throws {
        let ctx = try context()
        let i = inquiry(ctx)
        i.outcome = .lostSoft

        _ = ShowOutcomeBackfill.runForInquiries(in: ctx)

        #expect(i.showOutcome == .neverHeardBack)
    }

    @Test func itIsIdempotent() throws {
        let ctx = try context()
        let i = inquiry(ctx)
        i.lostReasonRaw = "they_declined"
        i.outcome = .lostHard

        let first = ShowOutcomeBackfill.runForInquiries(in: ctx)
        let second = ShowOutcomeBackfill.runForInquiries(in: ctx)

        #expect(first.filled == 1)
        #expect(second.filled == 0)
        #expect(i.showOutcome == .theySaidNo)
    }

    // An unrecognised stored reason is counted and left alone, never guessed at. A guess would file the
    // inquiry under an ending nobody chose, indistinguishable afterwards from one Dan gave.
    @Test func anunrecognisedReasonIsCountedAndLeftAlone() throws {
        let ctx = try context()
        let i = inquiry(ctx)
        i.lostReasonRaw = "a_reason_that_never_existed"
        i.outcome = .lostHard

        let result = ShowOutcomeBackfill.runForInquiries(in: ctx)

        #expect(i.showOutcome == nil)
        #expect(result.unrecognised == 1)
    }
}
