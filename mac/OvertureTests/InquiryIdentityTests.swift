import Testing
import Foundation
import SwiftData

// #4579 (plan v7 Phase 3, step 5): a press on an inquiry row finds its inquiry by the store identifier, with
// `createdAt` as the witness, through `InquiryIdentity`, and a refusal says its own cause.
//
// ONE TEST PER REFUSAL, each asserting the sentence Dan is shown AND that nothing was written, run through a
// real action (`InquiryMutations.mark`) after the resolve, as `ShowIdentityTests` does for shows (L3).
@MainActor
@Suite("A press on an inquiry finds it by identity, and refuses by name (#4579)")
struct InquiryIdentityTests {

    // HELD by the suite, because a context does not keep its container alive (`ShowIdentityTests`).
    private let container: ModelContainer

    init() throws {
        container = try TestModelContainer.inMemory([Inquiry.self])
    }

    private func context() -> ModelContext { container.mainContext }

    private func make(_ ctx: ModelContext, name: String, event: String) -> Inquiry {
        let inquiry = Inquiry(source: .directEmail, inquirerName: name, inquirerEmail: "\(name)@example.invalid",
                              eventName: event, performanceDate: "2082-10-01", venue: "Quillon Room")
        ctx.insert(inquiry)
        return inquiry
    }

    /// Booked, pressed on a row drawn with `identity`, resolved against `live` as the view resolves it.
    private func pressBooked(_ identity: InquiryIdentity?, name: String, among live: [Inquiry],
                             _ ctx: ModelContext) -> ActionFeedback {
        let feedback = ActionFeedback()
        if let inquiry = InquiryIdentity.inquiry(for: identity, name: name, in: live, feedback: feedback) {
            InquiryMutations.mark(inquiry, as: .booked, context: ctx, feedback: feedback)
        }
        return feedback
    }

    // THE ORDINARY CASE FIRST: every refusal below means something only if the same press on a live row is
    // written (L159).
    @Test func aPressOnALiveInquiryIsWritten() throws {
        let ctx = context()
        let inquiry = make(ctx, name: "Wren Halloway", event: "Lamplight Gala")
        try ctx.save()

        let feedback = pressBooked(InquiryIdentity(inquiry), name: inquiry.inquirerName, among: [inquiry], ctx)

        #expect(inquiry.outcome == .booked, "a press on a live inquiry did not write, so every refusal below proves nothing")
        #expect(feedback.tone != .warning, "a press that was written was answered with a refusal")
    }

    // An inquiry the edit sheet re-keyed is still the one Dan pressed: its key is computed from the event and
    // moves with every correction, which is why the witness is `createdAt` and not the key.
    @Test func aPressOnAnInquiryWhoseEventWasEditedIsStillWritten() throws {
        let ctx = context()
        let inquiry = make(ctx, name: "Wren Halloway", event: "Lamplight Gala")
        try ctx.save()
        let drawn = InquiryIdentity(inquiry)
        let keyBefore = inquiry.naturalKey

        inquiry.eventName = "Lamplight Gala Encore"
        try ctx.save()
        #expect(inquiry.naturalKey != keyBefore, "the edit did not re-key the inquiry, so this proves nothing")

        let feedback = pressBooked(drawn, name: inquiry.inquirerName, among: [inquiry], ctx)

        #expect(inquiry.outcome == .booked, "a press on an inquiry Dan had just edited was refused")
        #expect(feedback.tone != .warning)
    }

    // 1. GONE: the inquiry the row was drawn from was removed. The other inquiry is untouched.
    @Test func aRowWhoseInquiryWasRemovedIsRefusedAndNothingIsWritten() throws {
        let ctx = context()
        let pressed = make(ctx, name: "Wren Halloway", event: "Lamplight Gala")
        let other = make(ctx, name: "Ivo Marchetti", event: "Lamplight Gala")
        try ctx.save()
        let drawn = InquiryIdentity(pressed)

        ctx.delete(pressed)
        try ctx.save()

        let feedback = pressBooked(drawn, name: "Wren Halloway", among: [other], ctx)

        #expect(other.outcome != .booked, "a press on a removed inquiry's row wrote to a different inquiry")
        #expect(!ctx.hasChanges, "the refused press left an unsaved change behind")
        #expect(feedback.message == InquiryIdentity.Refusal.gone.sentence(name: "Wren Halloway"))
        #expect(feedback.tone == .warning)
    }

    // 2. NOT THE ONE DRAWN: the identifier names a live inquiry whose witness disagrees.
    @Test func aRowWhoseIdentifierNamesADifferentInquiryIsRefusedAndNothingIsWritten() throws {
        let ctx = context()
        let live = make(ctx, name: "Wren Halloway", event: "Lamplight Gala")
        try ctx.save()
        let drawn = InquiryIdentity(inquiryID: live.persistentModelID,
                                    createdAt: live.createdAt.addingTimeInterval(-86_400))

        let feedback = pressBooked(drawn, name: "Wren Halloway", among: [live], ctx)

        #expect(live.outcome != .booked, "a press whose witness disagreed was written anyway")
        #expect(!ctx.hasChanges, "the refused press left an unsaved change behind")
        #expect(feedback.message == InquiryIdentity.Refusal.notTheOneDrawn.sentence(name: "Wren Halloway"))
        #expect(feedback.tone == .warning)
    }

    // 3. DRAWN BEFORE ITS FIRST SAVE: the identifier is replaced at that save, so it names nothing afterwards.
    @Test func aRowDrawnBeforeItsInquirysFirstSaveIsRefusedAndNothingIsWritten() throws {
        let ctx = context()
        let inquiry = make(ctx, name: "Wren Halloway", event: "Lamplight Gala")
        let drawn = InquiryIdentity(inquiry)
        // The positive control in the same fixture: before the save, the very same identity resolves (L159).
        #expect(drawn.resolve(in: [inquiry]).inquiry === inquiry,
                Comment(rawValue: "an unsaved inquiry's identity did not resolve even before the save, so the "
                        + "refusal below is not about the save at all"))
        try ctx.save()
        #expect(drawn.inquiryID != inquiry.persistentModelID,
                "the identifier did not change on the first save, so this fixture no longer reaches the case")

        let feedback = pressBooked(drawn, name: "Wren Halloway", among: [inquiry], ctx)

        #expect(inquiry.outcome != .booked, "a row drawn before its inquiry's first save was resolved onto it anyway")
        #expect(!ctx.hasChanges, "the refused press left an unsaved change behind")
        #expect(feedback.message == InquiryIdentity.Refusal.drawnBeforeItsFirstSave.sentence(name: "Wren Halloway"))
        #expect(feedback.tone == .warning)
    }

    // 4. A ROW THE PASS HELD NO IDENTITY FOR is refused as gone, never acted on through anything else.
    @Test func aRowWithNoIdentityIsRefusedAsGone() throws {
        let ctx = context()
        let inquiry = make(ctx, name: "Wren Halloway", event: "Lamplight Gala")
        try ctx.save()

        let feedback = pressBooked(nil, name: "Wren Halloway", among: [inquiry], ctx)

        #expect(inquiry.outcome != .booked, "a row with no identity was acted on")
        #expect(feedback.message == InquiryIdentity.Refusal.gone.sentence(name: "Wren Halloway"))
        #expect(feedback.tone == .warning)
    }

    // Every cause has its own sentence, with and without a name, none empty (L11, L260).
    @Test func everyRefusalSaysItsOwnSentence() {
        for name in ["Wren Halloway", nil] {
            let said = InquiryIdentity.Refusal.allCases.map { $0.sentence(name: name) }
            #expect(Set(said).count == InquiryIdentity.Refusal.allCases.count, "two refusals share one sentence")
            #expect(said.allSatisfy { !$0.isEmpty })
        }
        #expect(InquiryIdentity.Refusal.gone.sentence(name: "Wren Halloway").contains("Wren Halloway"))
    }

    // THE ROW'S KEY. Measured 2026-10-07: two unsaved inquiries' identifiers differ while their descriptions
    // are one string, and the row id used to be that description, so `inquiriesByRowID` kept the first inquiry
    // under both rows and a press on the second acted on the first (L131).
    @Test func twoUnsavedInquiriesDrawTwoRowsEachResolvingToItsOwnInquiry() throws {
        let ctx = context()
        let first = make(ctx, name: "Wren Halloway", event: "Lamplight Gala")
        let second = make(ctx, name: "Ivo Marchetti", event: "Tidewater Benefit")
        // The premise, pinned: if the SDK starts describing unsaved identifiers apart, this says so (L82).
        #expect(first.persistentModelID != second.persistentModelID)
        #expect(String(describing: first.persistentModelID) == String(describing: second.persistentModelID),
                "PINNED 2026-10-07: two unsaved inquiries' identifiers describe themselves as one string")

        let rows = QueueModel.inquiryRows([first, second], now: Date())
        #expect(Set(rows.map(\.id)).count == 2, "two unsaved inquiries drew two rows under one id")
        let byRow = QueueModel.inquiriesByRowID([first, second])
        #expect(byRow.count == 2,
                "the row lookup holds one entry for two unsaved inquiries, so a press on one acts on the other")
        for row in rows {
            let inquiry = byRow[row.id]?.resolve(in: [first, second]).inquiry
            #expect(inquiry.map(InquiryIdentity.rowID(of:)) == row.id,
                    "an unsaved inquiry's row resolves to no inquiry, or to the other one")
        }

        // A row id two inquiries still claim names neither, rather than whichever came first (L521). Unreachable
        // through `rowID` today, so produced over values here.
        let claimed = QueueModel.identitiesByRowID([("shared", InquiryIdentity(first)),
                                                   ("shared", InquiryIdentity(second)),
                                                   ("own", InquiryIdentity(second))])
        #expect(claimed["shared"] == nil, "a row id two inquiries claim was given to one of them")
        #expect(claimed["own"] == InquiryIdentity(second), "the unclaimed row id lost its identity too")

        // And once saved, each keeps its own row, now under its store identifier's description.
        try ctx.save()
        let saved = QueueModel.inquiryRows([first, second], now: Date())
        #expect(Set(saved.map(\.id)) == [String(describing: first.persistentModelID),
                                         String(describing: second.persistentModelID)])
    }
}
