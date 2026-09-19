import Testing
import Foundation
import SwiftData

// #3373: dropping the night a kept row was kept for returns it to Scout.
//
// Dan's call, 2026-09-18: "always back to scout. if prepped, delete the prep so we don't risk a bad email
// going out". A keep is a decision about a NIGHT as often as about the run, so carrying it forward onto a
// date he never triaged spends prep on it, and a draft already written names the night he just dropped.
//
// Every test injects `now` (L130) and drives the real mutation, never the helper alone (L3).
@MainActor
@Suite("Dropping the night a kept run was kept for (#3373)")
struct KeptNightDropTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private let now = Date(timeIntervalSince1970: 1_786_000_000)
    private let export: DayOffEditing.Export = (bookings: [], blockedDates: [], health: .ok)

    // An invented run, three nights, in the shape the live store holds.
    private func run(_ ctx: ModelContext, status: ReviewStatus,
                     nights: [String] = ["2026-08-19", "2026-09-30", "2026-10-21"]) -> Prospect {
        let name = "The Lantern Cabaret"
        let p = Prospect(naturalKey: Prospect.makeNaturalKey(groupName: name, performanceDate: nights[0],
                                                             venue: "The Tin Room"),
                         groupName: name, discipline: "music", venue: "The Tin Room",
                         performanceDate: nights[0], sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 7, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        p.runEndDate = nights.last
        p.runNights = nights
        p.status = status
        ctx.insert(p)
        return p
    }

    private func draft(_ p: Prospect) {
        p.draftSubject = "Photographing The Lantern Cabaret on Aug 19"
        p.draftBody = "Hi, I would love to photograph your Aug 19 show."
        p.draftVariant = "warm"
        p.draftModel = "some-model"
        p.draftEditedByDan = true
        p.originalDraftSubject = "An earlier subject"
        p.originalDraftBody = "An earlier body naming Aug 19."
    }

    private func dropFirstNight(_ p: Prospect, _ ctx: ModelContext, undo: QueueUndoStack) {
        ProspectMutations.dismissForReason(QueueItem(p), .dateConflict, prospects: [p], context: ctx,
                                           feedback: ActionFeedback(), offer: DayOffOfferRequest(),
                                           undo: undo, now: now, export: export)
    }

    @Test("a kept run whose kept night is dropped goes back to Scout on its next night")
    func aKeptRunReturnsToScout() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, status: .queued)
        try ctx.save()

        dropFirstNight(p, ctx, undo: QueueUndoStack())

        #expect(p.performanceDate == "2026-09-30")
        #expect(p.status == .new, "the keep was about Aug 19, and Sep 30 has never been triaged")
    }

    @Test("a drafted run loses its draft in the same write, so no email naming the dropped night can go")
    func aDraftedRunLosesItsDraft() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, status: .drafted)
        draft(p)
        try ctx.save()

        dropFirstNight(p, ctx, undo: QueueUndoStack())

        #expect(p.status == .new)
        #expect(p.draftBody == nil)
        #expect(p.draftSubject == nil)
        #expect(p.draftVariant == nil)
        #expect(p.draftModel == nil)
        #expect(p.draftEditedByDan == false)
        #expect(p.originalDraftBody == nil)
        #expect(p.originalDraftSubject == nil)
        #expect(p.hasDraft == false)
    }

    @Test("an approved run goes back to Scout too, whatever stage it had reached")
    func anApprovedRunReturnsToScout() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, status: .approved)
        draft(p)
        try ctx.save()

        dropFirstNight(p, ctx, undo: QueueUndoStack())

        #expect(p.status == .new)
        #expect(p.hasDraft == false)
    }

    // Undo is the inverse or it is not undo (L574): every field the drop changed comes back.
    @Test("one undo puts back the night, the stage and every draft field")
    func undoRestoresEverything() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, status: .drafted)
        draft(p)
        p.draftWrittenByDan = true
        try ctx.save()
        let undo = QueueUndoStack()

        dropFirstNight(p, ctx, undo: undo)
        let entry = try #require(undo.takeTop())
        let outcome = QueueUndo.apply(entry, resolving: { _ in p }, in: ctx, export: export)

        #expect(outcome.restored == 1)
        #expect(p.performanceDate == "2026-08-19")
        #expect(p.status == .drafted)
        #expect(p.draftSubject == "Photographing The Lantern Cabaret on Aug 19")
        #expect(p.draftBody == "Hi, I would love to photograph your Aug 19 show.")
        #expect(p.draftVariant == "warm")
        #expect(p.draftModel == "some-model")
        #expect(p.draftEditedByDan == true)
        #expect(p.draftWrittenByDan == true)
        #expect(p.originalDraftSubject == "An earlier subject")
        #expect(p.originalDraftBody == "An earlier body naming Aug 19.")
    }

    // Outside the rule: a row already sent is a live conversation, not a kept row.
    @Test("a run that has already been emailed keeps its stage and its record")
    func aSentRunIsLeftAlone() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, status: .approved)
        draft(p)
        p.sentAt = now
        try ctx.save()

        dropFirstNight(p, ctx, undo: QueueUndoStack())

        #expect(p.status == .approved)
        #expect(p.draftBody != nil)
    }

    @Test("an untriaged run stays untriaged and nothing else about it changes")
    func anUntriagedRunIsUnchanged() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, status: .new)
        try ctx.save()

        dropFirstNight(p, ctx, undo: QueueUndoStack())

        #expect(p.status == .new)
        #expect(p.performanceDate == "2026-09-30")
    }

    // The same rule on the other control that drops a night (L30: the class, not the instance). The night
    // dismiss is offered on Scout only today, where nothing is kept, so this pins the rule in the shared
    // path rather than a case Dan can reach there now.
    @Test("the whole-night dismiss applies the same rule and undoes it the same way")
    func theNightDismissAppliesTheSameRule() throws {
        let ctx = ModelContext(try container())
        let p = run(ctx, status: .drafted)
        draft(p)
        try ctx.save()
        let undo = QueueUndoStack()

        ProspectMutations.dismissAll([p.naturalKey], reason: .pitchingOtherShows, dateLabel: "Aug 19",
                                     prospects: [p], context: ctx, feedback: ActionFeedback(),
                                     undo: undo, now: now, export: export)

        #expect(p.status == .new)
        #expect(p.hasDraft == false)

        let entry = try #require(undo.takeTop())
        QueueUndo.apply(entry, resolving: { _ in p }, in: ctx, export: export)
        #expect(p.status == .drafted)
        #expect(p.draftBody == "Hi, I would love to photograph your Aug 19 show.")
    }
}
