import Testing
import Foundation

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
                       priorStatus: priorStatus, priorShowOutcomeRaw: nil, priorDismissedAt: nil, priorConflictClearedKey: nil,
                       resultingStatus: .dismissed, resultingShowOutcomeRaw: "not_a_fit")
    }

    // MARK: - The stack

    @Test func aFreshStackHasNothingToUndo() {
        let stack = QueueUndoStack()

        #expect(stack.canUndo == false)
        #expect(stack.undoMenuTitle == "Undo")   // a plain verb, never a dangling "Undo :"
    }

    @Test func recordingAnActionMakesItUndoableAndNamesIt() {
        let stack = QueueUndoStack()
        stack.record(dismissal())

        #expect(stack.canUndo)
        #expect(stack.undoMenuTitle == "Undo Dismiss: The Music Shop")
    }

    // #1479: since #1473 one press can reverse a dismiss AND the days off it led to (which un-flags every
    // other show that block held back). The menu title Dan reads right before pressing must name that whole
    // action, so he can tell the two cases apart before committing to the press.
    @Test func aDismissThatAlsoBlockedNightsNamesTheWholeAction() {
        let stack = QueueUndoStack()
        var entry = dismissal()
        entry.blockedDays = QueueUndoEntry.BlockedDays(start: "2026-11-18", end: "2026-11-18")
        stack.record(entry)

        #expect(stack.undoMenuTitle == "Undo Dismiss and Days Off: The Music Shop")
    }

    // The other half of the same distinction: an ordinary dismiss with no block behind it must NOT claim to
    // undo any days off, or the title would promise more than the press performs.
    @Test func aDismissWithNoBlockDoesNotClaimToUndoDaysOff() {
        let stack = QueueUndoStack()
        stack.record(dismissal())

        #expect(stack.undoMenuTitle == "Undo Dismiss: The Music Shop")
        #expect(!stack.undoMenuTitle.contains("Days Off"))
    }

    // Dan's answer 1: he walks BACKWARD through several actions, not just the last one.
    @Test func severalActionsComeBackOffInReverseOrder() {
        let stack = QueueUndoStack()
        stack.record(dismissal(key: "a", org: "First Org"))
        stack.record(dismissal(key: "b", org: "Second Org"))
        stack.record(dismissal(key: "c", org: "Third Org"))

        #expect(stack.undoMenuTitle == "Undo Dismiss: Third Org")
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
        #expect(stack.undoMenuTitle == "Undo")   // a plain verb, never a dangling "Undo :"
    }

    // MARK: - The precondition that replaced the wall

    // The ordinary case: nothing has touched the row since, so the entry still describes it.
    @Test func anUntouchedRowCanStillBeUndone() {
        let entry = dismissal()

        #expect(entry.stillApplies(status: .dismissed, showOutcomeRaw: "not_a_fit"))
    }

    // A background writer moved it (a scout import, a retirement sweep, the reconcile tick). Those are
    // INVISIBLE to undo by design: they must never push or clear the stack, so the entry survives, but
    // it must also never reverse a change Dan did not make.
    @Test func aRowAnotherWriterMovedIsNoLongerUndoable() {
        let entry = dismissal()

        #expect(entry.stillApplies(status: .queued, showOutcomeRaw: nil) == false)
    }

    // The subtle one. Re-labelling WHY a dismissed show was cut leaves it dismissed, so a check on
    // status alone would wave this through and undo would restore the row while silently discarding
    // the newer reason. The reason is part of what the action left behind, so it is part of the check.
    @Test func aRowWhoseDismissReasonWasRelabelledIsNoLongerUndoable() {
        let entry = dismissal()

        #expect(entry.stillApplies(status: .dismissed, showOutcomeRaw: "too_far") == false)
    }

    // MARK: - What an undo has to put back

    // The entry carries the state to RESTORE, not just the state to check, because a keep from the
    // Review stage and a keep from the queue land the row in different places and undo has to know
    // which one it came from. Guessing at an inverse is what #752's snapshot exists to avoid.
    @Test func anEntryCarriesWhereTheRowCameFromNotJustWhereItWent() {
        let entry = dismissal(from: .approved)

        #expect(entry.priorStatus == .approved)
        #expect(entry.priorShowOutcomeRaw == nil)
        #expect(entry.priorDismissedAt == nil)
    }

    // A show dismissed twice keeps its FIRST exit date (Prospect.markDismissed only stamps
    // dismissedAt when it is nil), so undoing the second dismissal must put the original date back
    // rather than clearing it, or the row would lose the record of when it first left the queue.
    @Test func anEntryCarriesTheExitDateItFound() {
        let firstExit = Date(timeIntervalSince1970: 1_780_000_000)
        let entry = QueueUndoEntry(naturalKey: "k", groupName: "Org", actionLabel: "Dismiss",
                                   priorStatus: .dismissed, priorShowOutcomeRaw: "too_far",
                                   priorDismissedAt: firstExit, priorConflictClearedKey: nil,
                                   resultingStatus: .dismissed, resultingShowOutcomeRaw: "not_a_fit")

        #expect(entry.priorDismissedAt == firstExit)
    }

    // MARK: - Where a Cmd+Z goes (#1412's second question)

    // The #1412 spike (passed 2026-07-24, verified by hand in the draft body editor, the Add-a-Lead
    // sheet and the inline rename field) proved the app CAN own Cmd+Z without costing Dan ordinary
    // text editing. It also ruled out the obvious wiring, and that is what this rule exists for.
    //
    // `NSApp.sendAction(undo:)` returns TRUE whenever any text field holds focus, even with an empty
    // undo stack and nothing typed: it reports that something ACCEPTED the action, not that work
    // happened. So "forward first, fall back to the queue if that fails" would make the queue undo
    // permanently unreachable while any text field has focus. In this app that is a live failure
    // rather than a nicety, because focus is often INVISIBLE (a TextEditor holds it with no visible
    // ring), so Dan would dismiss a show, press Cmd+Z, and watch nothing happen with no way to tell why.
    //
    // The rule instead asks whether the focused field has REAL pending edits.

    @Test func typingBeingUndoableWinsOverTheQueue() {
        // Every Mac app behaves this way, and undoing a dismiss while the cursor sits mid-sentence in
        // an email body would be alarming.
        #expect(UndoRouting.destination(textEditingCanUndo: true, queueCanUndo: true) == .textEditing)
    }

    // THE case the rule exists for: a text field holds focus but has nothing to undo, so the keystroke
    // falls through instead of being swallowed.
    @Test func aFocusedFieldWithNothingToUndoLetsTheQueueUndoThrough() {
        #expect(UndoRouting.destination(textEditingCanUndo: false, queueCanUndo: true) == .queueAction)
    }

    @Test func withNothingToUndoAnywhereTheKeystrokeDoesNothing() {
        #expect(UndoRouting.destination(textEditingCanUndo: false, queueCanUndo: false) == .nothing)
    }

    // And text editing still wins when the queue stack is empty, so Cmd+Z keeps working normally in a
    // fresh session before Dan has kept or dismissed anything at all.
    @Test func typingIsStillUndoableBeforeAnyQueueActionHasHappened() {
        #expect(UndoRouting.destination(textEditingCanUndo: true, queueCanUndo: false) == .textEditing)
    }

    // MARK: - What the menu item actually does with that decision

    // The Edit menu command itself is three lines of AppKit the test bundle cannot reach (NSApp, the
    // responder chain, NSMenu). This is the branch inside it, pulled out so the DECISION is covered
    // even though the plumbing is not: a guard and its wiring are two separate claims (#887).

    @Test func aTextEditingUndoIsHandedToTheResponderChain() {
        #expect(UndoRouting.forwardsToResponderChain(.textEditing))
    }

    // The safety property, and the reason this is not simply `destination == .textEditing`.
    //
    // `undoManager?.canUndo` is a WEAKER signal than what the #1412 spike actually proved: the spike
    // passed with an item that ALWAYS forwards. If a focused field's undo manager is not reachable
    // where the app reads it, that read comes back false, and a keystroke that would have undone Dan's
    // typing would be silently dropped instead. Forwarding on `.nothing` costs nothing (a chain with
    // nothing to give back does nothing) and keeps the shipped behaviour identical to the version
    // verified on screen for as long as the stack stays empty.
    @Test func aKeystrokeWithNothingToUndoIsStillHandedOnRatherThanDropped() {
        #expect(UndoRouting.forwardsToResponderChain(.nothing))
    }

    // The one case that must NOT forward. Once #1414 fills the stack, forwarding here would hand Dan's
    // "undo that dismiss" to a text field that already said it had nothing to give back, and the
    // dismiss would stay put with nothing on screen explaining why.
    @Test func aQueueUndoIsNeverHandedToTheResponderChain() {
        #expect(UndoRouting.forwardsToResponderChain(.queueAction) == false)
    }
}

// The last wire (#1413), which nothing above can see. Every rule in the suite above stays green if the
// command group is never declared, bound to the wrong key, or reads a title it composes itself, and the
// feature would then do nothing at all. That is the #887 lesson, and the same shape as
// DismissDayOffWiringGuardTests.
//
// Pins the WIRING only, never the words: the menu's sentence belongs to QueueUndoStack and is asserted
// there. Pinning copy in a source guard is what #1451 had to undo.
@Suite("Undo menu wiring (#1413)")
struct UndoMenuWiringGuardTests {
    private func source(_ rel: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(rel, file: file)
    }

    @Test func theAppReplacesTheSystemUndoGroupAndBindsCommandZ() {
        let app = source("Overture/App/OvertureApp.swift")
        #expect(!app.isEmpty)
        // Replacing (not adding to) .undoRedo is mandatory: a .commands key equivalent is matched by
        // NSMenu before the event reaches the first responder, so a second Undo item would never win.
        #expect(app.contains("CommandGroup(replacing: .undoRedo)"))
        #expect(app.contains("keyboardShortcut(\"z\", modifiers: .command)"))
        // Redo exists only to give back what replacing the group took away from text fields.
        #expect(app.contains("keyboardShortcut(\"z\", modifiers: [.command, .shift])"))
    }

    @Test func theMenuItemReadsItsTitleFromTheStackAndCallsTheRouter() {
        let app = source("Overture/App/OvertureApp.swift")
        #expect(app.contains("Button(undoStack.undoMenuTitle)"))   // the title comes from the model
        #expect(app.contains("performUndo()"))
        #expect(app.contains("UndoRouting.destination("))
        #expect(app.contains("UndoRouting.forwardsToResponderChain("))
    }

    // The item must never be disabled. A disabled menu item's key equivalent does not fire, and this
    // same item carries TEXT undo, so greying it out on an empty stack would kill Cmd+Z inside every
    // text field in the app: exactly what the #1412 gate existed to protect.
    //
    // Pins the exact regression rather than the absence of `.disabled` in general, because the file
    // legitimately disables the Add-a-Lead command, and `undoStack.canUndo` legitimately appears inside
    // the routing call. What must never come back is that value reaching a `.disabled`.
    @Test func theUndoItemIsNeverDisabled() {
        let app = source("Overture/App/OvertureApp.swift")
        #expect(app.contains(".disabled(!undoStack") == false)
        #expect(app.contains(".disabled(!undoStack.canUndo)") == false)
    }

    // Owned by the App and injected, because a Scene-level .commands block cannot read RootView's state,
    // and because on the App it survives closing the window (Overture is LSUIElement, so a close is not
    // a quit) instead of silently emptying every time Dan closes it.
    @Test func theStackIsOwnedByTheAppAndInjectedIntoTheViews() {
        let app = source("Overture/App/OvertureApp.swift")
        #expect(app.contains("private var undoStack = QueueUndoStack()"))
        #expect(app.contains(".environment(undoStack)"))
    }
}
