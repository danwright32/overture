import Testing
import Foundation
@testable import Overture

// The session undo stack (#1413, milestone 29). The STACK only: nothing records into it yet (#1414)
// and nothing triggers it from the Edit menu yet (gated on the #1412 spike).
//
// Shape comes from Dan's 2026-07-23 interview, and two of his answers are load-bearing here:
//
// 1. A SESSION stack he can walk BACKWARD through several actions, with no time limit, reset on quit.
//    He rejected a single 10-second banner-style undo. So this is a real stack, not one slot.
// 2. Narrowed to keep and dismiss only. That narrowing DELETED the earlier "wall" design (where an
//    irreversible action cleared the stack so undo could never reach past it), because undoing a
//    dismiss of show A cannot touch an email already sent to show B. It is replaced by the
//    per-entry precondition below, which covers background writers, later edits and changed rows
//    with ONE rule instead of three.
//
// Entries hold VALUE TYPES ONLY. Never a Prospect (rows are deleted at runtime), never a
// ModelContext, never the ActionFeedback (the app is LSUIElement, so closing the window tears
// RootView down while the process lives on in the menu bar; a captured feedback object would post
// to something no view observes, which looks exactly like silent failure).
@MainActor
@Suite("The session undo stack (#1413)")
struct QueueUndoStackTests {

    private func dismissal(key: String = "k1", org: String = "The Music Shop",
                           from priorStatus: ReviewStatus = .new) -> QueueUndoEntry {
        QueueUndoEntry(naturalKey: key, groupName: org, actionLabel: "Dismiss",
                       priorStatus: priorStatus, priorDismissReasonRaw: nil, priorDismissedAt: nil,
                       resultingStatus: .dismissed, resultingDismissReasonRaw: "not_a_fit")
    }

    // MARK: - The stack

    @Test func aFreshStackHasNothingToUndo() {
        let stack = QueueUndoStack()

        #expect(stack.canUndo == false)
        #expect(stack.topLabel == nil)
    }

    @Test func recordingAnActionMakesItUndoableAndNamesIt() {
        let stack = QueueUndoStack()
        stack.record(dismissal())

        #expect(stack.canUndo)
        #expect(stack.topLabel == "Dismiss: The Music Shop")
    }

    // Dan's answer 1: he walks BACKWARD through several actions, not just the last one.
    @Test func severalActionsComeBackOffInReverseOrder() {
        let stack = QueueUndoStack()
        stack.record(dismissal(key: "a", org: "First Org"))
        stack.record(dismissal(key: "b", org: "Second Org"))
        stack.record(dismissal(key: "c", org: "Third Org"))

        #expect(stack.topLabel == "Dismiss: Third Org")
        #expect(stack.takeTop()?.naturalKey == "c")
        #expect(stack.takeTop()?.naturalKey == "b")
        #expect(stack.takeTop()?.naturalKey == "a")
        #expect(stack.canUndo == false)
    }

    // No redo, explicitly: a taken entry is GONE, not parked somewhere it could come back from.
    @Test func takingAnEntryDiscardsItRatherThanParkingItForRedo() {
        let stack = QueueUndoStack()
        stack.record(dismissal())
        _ = stack.takeTop()

        #expect(stack.canUndo == false)
        #expect(stack.takeTop() == nil)
    }

    @Test func takingFromAnEmptyStackIsHarmless() {
        let stack = QueueUndoStack()

        #expect(stack.takeTop() == nil)
        #expect(stack.canUndo == false)
    }

    @Test func clearingDropsEverything() {
        let stack = QueueUndoStack()
        stack.record(dismissal(key: "a"))
        stack.record(dismissal(key: "b"))

        stack.clear()

        #expect(stack.canUndo == false)
        #expect(stack.topLabel == nil)
    }

    // MARK: - The precondition that replaced the wall

    // The ordinary case: nothing has touched the row since, so the entry still describes it.
    @Test func anUntouchedRowCanStillBeUndone() {
        let entry = dismissal()

        #expect(entry.stillApplies(status: .dismissed, dismissReasonRaw: "not_a_fit"))
    }

    // A background writer moved it (a scout import, a retirement sweep, the reconcile tick). Those are
    // INVISIBLE to undo by design: they must never push or clear the stack, so the entry survives, but
    // it must also never reverse a change Dan did not make.
    @Test func aRowAnotherWriterMovedIsNoLongerUndoable() {
        let entry = dismissal()

        #expect(entry.stillApplies(status: .queued, dismissReasonRaw: nil) == false)
    }

    // The subtle one. Re-labelling WHY a dismissed show was cut leaves it dismissed, so a check on
    // status alone would wave this through and undo would restore the row while silently discarding
    // the newer reason. The reason is part of what the action left behind, so it is part of the check.
    @Test func aRowWhoseDismissReasonWasRelabelledIsNoLongerUndoable() {
        let entry = dismissal()

        #expect(entry.stillApplies(status: .dismissed, dismissReasonRaw: "too_far") == false)
    }

    // MARK: - What an undo has to put back

    // The entry carries the state to RESTORE, not just the state to check, because a keep from the
    // Review stage and a keep from the queue land the row in different places and undo has to know
    // which one it came from. Guessing at an inverse is what #752's snapshot exists to avoid.
    @Test func anEntryCarriesWhereTheRowCameFromNotJustWhereItWent() {
        let entry = dismissal(from: .approved)

        #expect(entry.priorStatus == .approved)
        #expect(entry.priorDismissReasonRaw == nil)
        #expect(entry.priorDismissedAt == nil)
    }

    // A show dismissed twice keeps its FIRST exit date (Prospect.markDismissed only stamps
    // dismissedAt when it is nil), so undoing the second dismissal must put the original date back
    // rather than clearing it, or the row would lose the record of when it first left the queue.
    @Test func anEntryCarriesTheExitDateItFound() {
        let firstExit = Date(timeIntervalSince1970: 1_780_000_000)
        let entry = QueueUndoEntry(naturalKey: "k", groupName: "Org", actionLabel: "Dismiss",
                                   priorStatus: .dismissed, priorDismissReasonRaw: "too_far",
                                   priorDismissedAt: firstExit,
                                   resultingStatus: .dismissed, resultingDismissReasonRaw: "not_a_fit")

        #expect(entry.priorDismissedAt == firstExit)
    }
}
