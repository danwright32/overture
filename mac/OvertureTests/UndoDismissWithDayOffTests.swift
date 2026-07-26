import Testing
import Foundation
import SwiftData
@testable import Overture

// #1473: one press undoes one whole action, including its side effects.
//
// Dan's decision (2026-07-24), overriding #1414's "out of scope and deliberately unchanged" line for this
// one path: a dismiss and the day off it led to are ONE undo entry. Before this, Cmd+Z reversed only the
// dismiss and left the night blocked, and every other show that block flagged stayed flagged, which is the
// expensive half: a flagged show is held back from drafting and sending with nothing on screen saying why.
//
// The block is confirmed AFTER the dismiss is recorded (Dan picks the days in a sheet), so the entry is
// amended rather than built complete. A block reached from the Days Off sheet directly is a different
// action and never attaches here; it keeps the banner Undo it already had.
@MainActor
@Suite("Undo a dismiss and the day off it led to (#1473)")
struct UndoDismissWithDayOffTests {
    private func context() throws -> ModelContext {
        ModelContext(try ModelContainer(for: Schema([Prospect.self, Recipient.self, DayOff.self]),
                                        configurations: [ModelConfiguration(isStoredInMemoryOnly: true)]))
    }

    @discardableResult
    private func show(_ ctx: ModelContext, key: String, group: String = "Vienna Philharmonic",
                      on date: String, status: ReviewStatus = .queued) -> Prospect {
        let p = Prospect(naturalKey: key, groupName: group, discipline: "music",
                         venue: "Stern Auditorium", performanceDate: date, sourceListingURL: nil,
                         websiteURL: nil, priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                         status: status)
        ctx.insert(p)
        try? ctx.save()
        return p
    }

    // A calendar with nothing in it, so these tests never read Dan's real export off disk.
    private let noExport: DayOffEditing.Export = (bookings: [], blockedDates: [])

    private func dismissEntry(_ ctx: ModelContext, _ p: Prospect, into stack: QueueUndoStack) {
        ProspectMutations.dismissForReason(QueueItem(p), .dateConflict, prospects: [p], context: ctx,
                                           feedback: ActionFeedback(), offer: DayOffOfferRequest(),
                                           undo: stack)
    }

    // MARK: - Attaching the block to the dismiss that led to it

    @Test func aBlockAttachesToTheDismissOfTheSameShow() throws {
        let ctx = try context()
        let p = show(ctx, key: "vpo-18", on: "2026-11-18")
        let stack = QueueUndoStack()
        dismissEntry(ctx, p, into: stack)

        #expect(stack.attachBlockedDaysOff(start: "2026-11-18", end: "2026-11-18", toDismissOf: "vpo-18"))

        let entry = try #require(stack.takeTop())
        #expect(entry.blockedDays == QueueUndoEntry.BlockedDays(start: "2026-11-18", end: "2026-11-18"))
    }

    // The safe fallback, and the reason the attach is keyed rather than unconditional: a block that did not
    // come from the top entry's dismiss must not ride on it, or Cmd+Z on an unrelated action would delete a
    // day off Dan is counting on. It keeps the banner Undo `blockDaysOff` already offers instead.
    @Test func aBlockForADifferentShowAttachesToNothing() throws {
        let ctx = try context()
        let p = show(ctx, key: "vpo-18", on: "2026-11-18")
        let stack = QueueUndoStack()
        dismissEntry(ctx, p, into: stack)

        #expect(stack.attachBlockedDaysOff(start: "2026-12-01", end: "2026-12-01",
                                           toDismissOf: "some-other-show") == false)

        let entry = try #require(stack.takeTop())
        #expect(entry.blockedDays == nil)
    }

    // Keeping a show is not a dismiss, so nothing about it led to a day off.
    @Test func aBlockDoesNotAttachToAKeepOfTheSameShow() throws {
        let ctx = try context()
        let p = show(ctx, key: "vpo-18", on: "2026-11-18", status: .new)
        let stack = QueueUndoStack()
        ProspectMutations.setStatus(QueueItem(p), .queued, nil, prospects: [p], context: ctx,
                                    feedback: ActionFeedback(), undo: stack, undoLabel: "Keep")

        #expect(stack.attachBlockedDaysOff(start: "2026-11-18", end: "2026-11-18",
                                           toDismissOf: "vpo-18") == false)
        #expect(try #require(stack.takeTop()).blockedDays == nil)
    }

    @Test func anEmptyStackTakesNoAttachment() {
        let stack = QueueUndoStack()
        #expect(stack.attachBlockedDaysOff(start: "2026-11-18", end: "2026-11-18",
                                           toDismissOf: "vpo-18") == false)
        #expect(stack.canUndo == false)
    }

    // MARK: - Undoing the whole action

    // The point of the issue, end to end through the real mutations: the show comes back, the night is
    // unblocked, and the OTHER show that block flagged is draftable again in the same press.
    @Test func oneUndoBringsTheShowBackAndUnblocksTheNightItLedTo() throws {
        let ctx = try context()
        let dismissed = show(ctx, key: "vpo-18", on: "2026-11-18")
        let bystander = show(ctx, key: "abt-18", group: "American Ballet Theatre", on: "2026-11-18")
        let stack = QueueUndoStack()
        dismissEntry(ctx, dismissed, into: stack)

        #expect(ProspectMutations.blockDaysOff(start: "2026-11-18", end: "2026-11-18", note: nil,
                                               export: noExport, context: ctx, feedback: ActionFeedback(),
                                               undo: stack, undoDismissOf: "vpo-18"))
        #expect(bystander.hasUnclearedConflict)   // the sweep flagged it when the night was blocked

        let entry = try #require(stack.takeTop())
        #expect(QueueUndo.apply(entry, to: dismissed, in: ctx, export: noExport))

        #expect(dismissed.status == .queued)                  // the show is back where it was
        #expect(DayOffEditing.rows(in: ctx).isEmpty)          // the night is no longer blocked
        #expect(bystander.hasUnclearedConflict == false)      // and the show it flagged is free again
    }

    // The failure path that decides the ORDER of the two halves. When the row has moved on since the
    // dismiss (a scout re-scored it, a send took it, a sweep re-labelled the cut), the entry is stale and
    // undo refuses. The day off must survive that refusal: deleting it would leave Dan with a night he
    // told Overture he cannot work quietly unblocked, and every show on it draftable again.
    @Test func aStaleEntryLeavesTheDayOffAlone() throws {
        let ctx = try context()
        let p = show(ctx, key: "vpo-18", on: "2026-11-18")
        let stack = QueueUndoStack()
        dismissEntry(ctx, p, into: stack)
        ProspectMutations.blockDaysOff(start: "2026-11-18", end: "2026-11-18", note: nil,
                                       export: noExport, context: ctx, feedback: ActionFeedback(),
                                       undo: stack, undoDismissOf: "vpo-18")

        p.markDismissed(reason: .wentBy)   // a retirement sweep re-labels the cut before Dan presses Cmd+Z

        let entry = try #require(stack.takeTop())
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: noExport) == false)
        #expect(DayOffEditing.rows(in: ctx).count == 1)   // the night Dan cannot work stays blocked
    }

    // Dan can also reverse just the block from the banner (that Undo is deliberately kept). Cmd+Z after
    // that finds nothing left to unblock and must still do its own half rather than give up on the show.
    @Test func anAlreadyRemovedBlockStillLetsTheShowComeBack() throws {
        let ctx = try context()
        let p = show(ctx, key: "vpo-18", on: "2026-11-18")
        let stack = QueueUndoStack()
        dismissEntry(ctx, p, into: stack)
        ProspectMutations.blockDaysOff(start: "2026-11-18", end: "2026-11-18", note: nil,
                                       export: noExport, context: ctx, feedback: ActionFeedback(),
                                       undo: stack, undoDismissOf: "vpo-18")

        let row = try #require(DayOffEditing.rows(in: ctx).first)
        DayOffEditing.remove(row, export: noExport, in: ctx)   // the banner Undo, pressed first

        let entry = try #require(stack.takeTop())
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: noExport))
        #expect(p.status == .queued)
        #expect(DayOffEditing.rows(in: ctx).isEmpty)
    }

    // An entry with no block behind it is the ordinary case (every dismiss for a non-calendar reason) and
    // must not go anywhere near the day-off table.
    @Test func aDismissWithNoBlockUndoesTheRowAlone() throws {
        let ctx = try context()
        let p = show(ctx, key: "vpo-18", on: "2026-11-18")
        DayOffEditing.add(start: "2026-12-24", end: "2026-12-26", note: "Away",
                          export: noExport, into: ctx)      // an unrelated block of Dan's
        let stack = QueueUndoStack()
        dismissEntry(ctx, p, into: stack)

        let entry = try #require(stack.takeTop())
        #expect(QueueUndo.apply(entry, to: p, in: ctx, export: noExport))
        #expect(p.status == .queued)
        #expect(DayOffEditing.rows(in: ctx).count == 1)   // his own block is untouched
    }

    // MARK: - Failing to block attaches nothing

    // #1417's rule, one level up: `blockDaysOff` refuses a backwards range and writes nothing, so there is
    // nothing for an undo to take back. An entry promising to remove a day off that was never blocked
    // would make the next Cmd+Z delete whatever else happened to match those dates.
    @Test func aRefusedRangeAttachesNothing() throws {
        let ctx = try context()
        let p = show(ctx, key: "vpo-18", on: "2026-11-18")
        let stack = QueueUndoStack()
        dismissEntry(ctx, p, into: stack)

        #expect(ProspectMutations.blockDaysOff(start: "2026-11-20", end: "2026-11-18", note: nil,
                                               export: noExport, context: ctx, feedback: ActionFeedback(),
                                               undo: stack, undoDismissOf: "vpo-18") == false)

        #expect(DayOffEditing.rows(in: ctx).isEmpty)
        #expect(try #require(stack.takeTop()).blockedDays == nil)
    }
}

// The wires none of the behaviour above can see (#1473). Every rule stays green while the sheet that
// actually blocks the days never hands the stack over, or the window's undo never passes the store.
@Suite("Undo of a dismiss and its day off, wiring (#1473)")
struct UndoDismissWithDayOffWiringTests {
    private func source(_ rel: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(rel, file: file)
    }

    // The sheet is handed the stack by RootView rather than reading it from the environment. An
    // environment lookup that silently came back empty would attach nothing, and a half-undo (the show
    // back, the night still blocked) looks exactly like the bug this issue fixes.
    @Test func theBlockSheetIsHandedTheStackAndTheKeyOfTheDismissItCameFrom() {
        let root = source("Overture/App/RootView.swift")
        let sheet = source("Overture/UI/BlockDaysSheet.swift")
        #expect(root.contains("BlockDaysSheet(pending: pending, undo: undoStack)"))
        #expect(sheet.contains("undo: undo, undoDismissOf: pending.id"))
    }

    // #1500 moved the call from one row to every row in the entry; the claim guarded here is unchanged and
    // is the whole point of #1473: the store goes with it, so the day off half of the undo can run.
    @Test func theWindowsUndoPassesTheStoreSoTheDayOffHalfCanRun() {
        let root = source("Overture/App/RootView.swift")
        #expect(root.contains("QueueUndo.apply(entry, resolving:"))
        #expect(root.contains("}, in: context)"))
    }

    // #1415: an undo restores a row into a stage Dan is usually not looking at, so a working Cmd+Z was
    // pixel-identical to a dead one. Both the success and the skipped paths of performQueueUndo must post a
    // banner. Guarded at the source because the logic lives inside a SwiftUI view, which no test can reach
    // (the #863 lesson); the copy itself is proven behaviourally in ActionAckTests.
    @Test func theWindowsUndoNamesWhatCameBackAndWhereOnBothPaths() {
        let root = source("Overture/App/RootView.swift")
        #expect(root.contains("ActionAck.undoRestored(org: entry.groupName, priorStatus: entry.priorStatus)"))
        #expect(root.contains("ActionAck.undoSkipped(org: entry.groupName)"))
    }
}
