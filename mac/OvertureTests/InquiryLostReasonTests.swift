import Testing
import Foundation
import SwiftData

// #16 wants "Declined" and "Not a fit" as SEPARATE drop-offs in the year-end Sankey. Until now
// "Mark lost" wrote one undifferentiated soft-lost with no reason, so those two could never be told
// apart afterwards. Unlike the rest of the funnel (#1437 showed the stages are all derivable from
// timestamps already stored), this one is genuinely unrecoverable: nothing in the record says whether
// the client said no or Dan turned it down. Captured at the moment Dan closes the inquiry, which is the
// only moment anyone knows.
@MainActor
@Suite("Why an inquiry ended")
struct InquiryLostReasonTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func make(_ ctx: ModelContext) -> Inquiry {
        let inq = Inquiry(source: .contactForm, inquirerName: "Ada", inquirerEmail: "ada@x.org",
                          eventName: "Gala")
        ctx.insert(inq)
        return inq
    }

    // Each reason closes the inquiry, and each records WHICH it was.
    @Test("each way of losing an inquiry closes it and records which it was")
    func eachReasonClosesAndRecords() throws {
        let ctx = ModelContext(try container())

        for reason in InquiryEnding.danCanChoose {
            let inq = make(ctx)
            InquiryMutations.mark(inq, as: .lost(reason), context: ctx,
                                  feedback: ActionFeedback(), now: Date())

            #expect(!inq.isOpen, "\(reason) left the inquiry open")
            #expect(inq.showOutcome == reason)
            #expect(inq.outcomeSourceRaw == OutcomeSource.manual.rawValue)
        }
    }

    // "They declined" is the hard lost case (they are not interested); Dan's own pass and a silence
    // both leave the door open for future work, which is what lostSoft means.
    @Test("a client's refusal is the hard lost case, Dan's own pass and a silence are not")
    func refusalIsHardTheOthersAreSoft() throws {
        let ctx = ModelContext(try container())
        let declined = make(ctx), ownPass = make(ctx), quiet = make(ctx)

        InquiryMutations.mark(declined, as: .lost(.theySaidNo), context: ctx, feedback: ActionFeedback(), now: Date())
        InquiryMutations.mark(ownPass, as: .lost(.turnedThemDown), context: ctx, feedback: ActionFeedback(), now: Date())
        InquiryMutations.mark(quiet, as: .lost(.neverHeardBack), context: ctx, feedback: ActionFeedback(), now: Date())

        #expect(declined.outcome == .lostHard)
        #expect(ownPass.outcome == .lostSoft)
        #expect(quiet.outcome == .lostSoft)
    }

    // Marking booked must not leave a lost reason behind, or the year-end split double-counts it.
    @Test("a booked inquiry carries no lost reason")
    func bookedHasNoReason() throws {
        let ctx = ModelContext(try container())
        let inq = make(ctx)

        InquiryMutations.mark(inq, as: .booked, context: ctx, feedback: ActionFeedback(), now: Date())

        // #2400: a booking IS an ending, and the same stored value a booked show carries, so the report can
        // add the two halves of the funnel. What must not survive is a stale LOST ending underneath it.
        #expect(inq.showOutcome == .booked)
        #expect(InquiryReporting.ending(for: inq) == .booked)
    }

    // An inquiry closed before this shipped has no stored reason. Reporting must not silently drop it
    // from the lost column: it falls back to what IS derivable from the timestamps (#1437's drop-off
    // edge), so the year-end total still adds up.
    @Test("a lost inquiry with no stored reason still reports as lost, via what is derivable")
    func olderLostInquiriesStillCount() throws {
        let ctx = ModelContext(try container())
        let inq = make(ctx)
        inq.sentAt = Date()
        inq.outcome = .lostSoft
        inq.outcomeSourceRaw = OutcomeSource.manual.rawValue

        #expect(inq.showOutcome == nil)
        #expect(InquiryReporting.stage(for: inq) == .lost)
        // Dan replied and they never answered, so the honest reading is the silence, not a refusal.
        #expect(InquiryReporting.ending(for: inq) == .neverHeardBack)
    }

    // A stored reason always wins over the derived guess: Dan saying "they declined" must not be
    // overwritten by the fact that they happened never to write back.
    @Test("a stored reason wins over the derived one")
    func storedReasonWins() throws {
        let ctx = ModelContext(try container())
        let inq = make(ctx)
        inq.sentAt = Date()   // no reply, so the derived guess would be neverHeardBack

        InquiryMutations.mark(inq, as: .lost(.theySaidNo), context: ctx,
                              feedback: ActionFeedback(), now: Date())

        #expect(InquiryReporting.ending(for: inq) == .theySaidNo)
    }

    // A raw value written by a later version must not read back as one of today's reasons.
    @Test("an unrecognised stored reason reads as unknown, not as a wrong one")
    func unknownRawValueIsNotMisread() throws {
        let ctx = ModelContext(try container())
        let inq = make(ctx)
        inq.showOutcomeRaw = "an_ending_a_later_version_added"

        #expect(inq.showOutcome == nil)
    }
}
