import Testing
import Foundation
import SwiftData

// #1583/#1691: Keep IS the acceptance of a date clash Dan can already see on the card.
//
// Before this, Keep did nothing to the clash, and that had a consequence nobody designed. A kept show with
// an open clash is excluded by `PrepQueueBuilder.needsPrepEligible`, which is the SAME predicate
// `StageNavigation.matches(.prep, ...)` decides stage membership with, so the show belonged to NO stage at
// all. The queue is stage-scoped only, so pressing Keep, which reads as "yes, pursue this", made the row
// vanish from every list in the app, including the control that would have let him out of the state. That
// is #1691, and `everyKeptShowStillBelongsToAStage` below is its regression test.
//
// Dan's decision (2026-07-26): keeping a show whose clash is visible IS his acceptance of that clash. A
// second confirmation for the same judgment is the bug, not just the wording.
@MainActor
@Suite("Keep accepts a date clash (#1583)")
struct KeepAcceptsConflictTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    private let vacation = BlockedCalendar.Day(date: "2026-11-14", kind: .dayOff, name: "Vacation").key
    private let wedding = BlockedCalendar.Day(date: "2026-11-14", kind: .bookedShoot,
                                              name: "The One-Man Odyssey").key

    @discardableResult
    private func show(_ ctx: ModelContext, conflict: String? = nil,
                      status: ReviewStatus = .new) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Vienna Philharmonic", discipline: "music",
                         venue: "Stern Auditorium / Perelman Stage", performanceDate: "2026-11-14",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 9, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: status)
        if let conflict { p.setScoutConflict(conflict) }
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    private func keep(_ p: Prospect, in ctx: ModelContext,
                      undo: QueueUndoStack? = nil) {
        ProspectMutations.setStatus(QueueItem(p), .queued, nil, prospects: [p], context: ctx,
                                    feedback: ActionFeedback(), undo: undo, undoLabel: "Keep")
    }

    // MARK: - Keep is the acceptance

    @Test func keepingAConflictedShowAcceptsTheClash() throws {
        let ctx = try context()
        let p = show(ctx, conflict: vacation)
        #expect(p.hasUnclearedConflict)

        keep(p, in: ctx)

        #expect(p.status == .queued)
        #expect(p.hasUnclearedConflict == false)
        #expect(p.conflictClearedKey == vacation)   // the SPECIFIC clash, not a blanket yes
    }

    // The failure path, and the reason the acceptance stores a fingerprint rather than a bare boolean
    // (#718's pattern). Dan waved through being away that night. He never waved through already shooting a
    // wedding that night, so a clash that CHANGES under him is a fact he has not seen and blocks again.
    @Test func aClashThatChangesAfterTheKeepBlocksAgain() throws {
        let ctx = try context()
        let p = show(ctx, conflict: vacation)
        keep(p, in: ctx)
        #expect(p.hasUnclearedConflict == false)

        p.setScoutConflict(wedding)   // the reconcile tick finds a booking on the same night

        #expect(p.hasUnclearedConflict)
    }

    // Accepting stops the BLOCKING, not the TELLING. He is still busy that night, so the sentence stays on
    // the card and the date header keeps saying so. Dan's decision 4.
    @Test func theClashIsStillStatedAfterItIsAccepted() throws {
        let ctx = try context()
        let p = show(ctx, conflict: vacation)
        keep(p, in: ctx)

        let item = QueueItem(p)
        #expect(item.hasUnclearedConflict == false)   // no longer blocks
        #expect(item.hasConflict)                     // but the clash is still true
        #expect(item.conflictNote == "You blocked Nov 14 (Vacation).")
        #expect(QueueModel.groupIsUnavailable([item]), "the date header stopped marking a night he is busy")
    }

    // MARK: - Undo (Dan's decision 7)

    @Test func undoingTheKeepRestoresTheClash() throws {
        let ctx = try context()
        let p = show(ctx, conflict: vacation)
        let stack = QueueUndoStack()
        keep(p, in: ctx, undo: stack)
        #expect(p.hasUnclearedConflict == false)

        let entry = try #require(stack.takeTop())
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [])))

        #expect(p.status == .new)
        #expect(p.hasUnclearedConflict, "the undo left a silent pre-clearance behind")
        #expect(p.conflictClearedKey == nil)
    }

    // The undo restores the clearance that was there BEFORE, which is not always nil: a show Dan had
    // already waved through by hand, then dismissed, then kept again must not lose that older acceptance.
    @Test func undoRestoresAnEarlierAcceptanceRatherThanClearingIt() throws {
        let ctx = try context()
        let p = show(ctx, conflict: vacation, status: .dismissed)
        p.clearConflict()                       // he waved it through by hand at some earlier point
        let stack = QueueUndoStack()
        keep(p, in: ctx, undo: stack)

        let entry = try #require(stack.takeTop())
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [])))

        #expect(p.status == .dismissed)
        #expect(p.conflictClearedKey == vacation)
        #expect(p.hasUnclearedConflict == false)
    }

    @Test func keepingAnUnconflictedShowLeavesTheConflictFieldsAlone() throws {
        let ctx = try context()
        let p = show(ctx)
        let stack = QueueUndoStack()
        keep(p, in: ctx, undo: stack)

        #expect(p.conflictClearedKey == nil)
        #expect(p.hasUnclearedConflict == false)

        let entry = try #require(stack.takeTop())
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: (bookings: [], blockedDates: [])))
        #expect(p.hasUnclearedConflict == false)
    }

    // MARK: - #1691: a kept show is always somewhere

    // The regression test for the vanishing. A clash landing AFTER the keep (the reconcile tick finds a
    // booking) is the one case that can still block a kept show, and it must leave the show reachable.
    @Test func everyKeptShowStillBelongsToAStage() throws {
        let ctx = try context()
        let p = show(ctx, conflict: vacation)
        keep(p, in: ctx)
        p.setScoutConflict(wedding)   // a booking lands after the keep, so it blocks again

        let stage = StageNavigation.stage(containing: p.naturalKey, in: [p], reachedOutKeys: [],
                                          context: .at("2026-08-01"))

        #expect(stage != nil, "#1691: a kept show that matches no stage is rendered nowhere in the queue")
        #expect(stage == .prepBlocked)
    }

    // The two Prep focuses are exact complements over the same rule, so a kept show is in one or the
    // other and never both. Folding the blocked ones into the ordinary Prep count would make that number
    // include shows the Prep run then refuses to draft, which is the exact mismatch #863 exists to stop.
    @Test func aBlockedShowIsCountedApartFromTheOnesReadyToPrep() throws {
        let ctx = try context()
        let blocked = show(ctx, conflict: vacation)
        keep(blocked, in: ctx)
        blocked.setScoutConflict(wedding)
        let ready = show(ctx, status: .queued)
        ready.naturalKey = "ready"

        let counts = StageNavigation.counts(in: [blocked, ready], context: .at("2026-08-01"))

        #expect(counts[.prep] == 1)
        #expect(counts[.prepBlocked] == 1)
        #expect(StageNavigation.naturalKeys(for: .prepBlocked, in: [blocked, ready],
                                            context: .at("2026-08-01")) == [blocked.naturalKey])
    }

    // The Prep RUN's work list is deliberately unchanged: no contacts are researched and no email written
    // for a night Dan cannot work. Only stage MEMBERSHIP changed, so the show is visible without being paid for.
    @Test func theBlockedShowStaysOffThePrepRunsWorkList() throws {
        let ctx = try context()
        let p = show(ctx, conflict: vacation)
        keep(p, in: ctx)
        p.setScoutConflict(wedding)

        #expect(PrepQueueBuilder.needsPrepEligible(p) == false)
    }
}
