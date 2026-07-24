import Foundation

// The session undo stack for queue actions (#1413, milestone 29), and the record of one reversible
// action. Nothing records into this yet (#1414) and nothing triggers it yet: the Edit menu command is
// held back behind the #1412 spike, which has to prove that owning Cmd+Z does not cost Dan ordinary
// undo inside text fields.
//
// Two of Dan's decisions (2026-07-23 interview) shape this:
//
// 1. A SESSION stack he walks BACKWARD through several actions, with no time limit, reset on quit. He
//    rejected a single 10-second banner-style undo, so this is a real stack rather than one slot.
// 2. Narrowed to keep and dismiss only. That narrowing DELETED the earlier "wall" design (an
//    irreversible action clearing the stack so undo could not reach past it): undoing a dismiss of
//    show A cannot touch an email already sent to show B, so the wall guarded nothing. It is replaced
//    by `stillApplies` below, which covers background writers, later edits and changed rows with ONE
//    rule instead of three.
//
// Deliberately NOT NSUndoManager, for a reason that survived the narrowing: NSUndoManager observes the
// context, so it cannot tell Dan's click from a background write. The reconcile tick, a scout import,
// the retirement sweeps and the launch migrations must all be INVISIBLE to undo, neither pushing onto
// the stack nor clearing it, so Cmd+Z never goes dead through no action of Dan's.

// One reversible queue action. VALUE TYPES ONLY, and the constraint is not fussiness:
//
// Never a `Prospect`: rows are deleted at runtime (`NaturalKeyVenueMigration`), so a captured model
// object can outlive the row it describes. The natural key is looked up fresh at undo time instead.
// Never a `ModelContext`, and never the `ActionFeedback`: the app is LSUIElement, so closing the
// window tears RootView down while the process lives on in the menu bar, and a captured feedback
// object would post its acknowledgment to something no view observes, which is indistinguishable
// from silent failure.
struct QueueUndoEntry: Equatable, Sendable {
    let naturalKey: String
    let groupName: String
    // What Dan did, for the menu title ("Undo Dismiss: The Music Shop"). Held as text rather than an
    // enum because the menu is the only reader, and an enum would invite behaviour to hang off it.
    let actionLabel: String

    // Where the row came FROM, which is what undo restores. Recorded rather than inferred: a keep from
    // the Review stage and a keep from the queue land the row in different places, and guessing at an
    // inverse is exactly the mistake #752's snapshot exists to avoid.
    let priorStatus: ReviewStatus
    let priorDismissReasonRaw: String?
    // `Prospect.markDismissed` stamps `dismissedAt` only when it is nil, so a show dismissed twice keeps
    // its FIRST exit date. Undoing the second dismissal has to put that original date back rather than
    // clear it, or the row loses the record of when it first left the queue (#16 counts on that date).
    let priorDismissedAt: Date?

    // Where the action LEFT the row. Not restored; this is the precondition.
    let resultingStatus: ReviewStatus
    let resultingDismissReasonRaw: String?

    // The Edit menu's title for this entry, e.g. "Undo Dismiss: The Music Shop". A WHOLE sentence in one
    // place, not a fragment the menu prefixes: #863's guard rejects a view composing its own copy, and a
    // sentence assembled at the call site is invisible to the copy inventory (#915), so Dan's PR would
    // not show the words he is going to read.
    var undoMenuTitle: String { "Undo \(actionLabel): \(groupName)" }

    // Is the row still exactly how this action left it? If anything moved it since (a background
    // writer, a later action of Dan's, a scout import), undoing would clobber something newer, so the
    // entry no longer applies.
    //
    // Checks the dismiss REASON as well as the status, and that is the case a status-only check misses:
    // re-labelling why a dismissed show was cut leaves it dismissed, so undo would restore the row and
    // silently discard the newer reason.
    func stillApplies(status: ReviewStatus, dismissReasonRaw: String?) -> Bool {
        status == resultingStatus && dismissReasonRaw == resultingDismissReasonRaw
    }
}

// Owned by `OvertureApp` and injected with `.environment()`, NOT held beside `ActionFeedback`: that is
// `@State` inside RootView, and a Scene-level `.commands` block cannot read view state.
//
// Living on the App rather than the view also settles #1413's open question about the window. Overture
// is LSUIElement, so closing the window is not quitting: the process stays resident in the menu bar. A
// stack owned here therefore SURVIVES closing the window and dies only on quit, which is what Dan asked
// for ("resets on quit"). Had it lived in RootView it would have silently emptied every time he closed
// the window, which is not a thing he would have been told about.
@Observable
@MainActor
final class QueueUndoStack {
    private(set) var entries: [QueueUndoEntry] = []

    var canUndo: Bool { !entries.isEmpty }

    // The Edit menu item's title. A plain "Undo" when there is nothing to undo, rather than nil, because
    // the item is never disabled: it also carries TEXT undo, and a disabled menu item's key equivalent
    // does not fire, so greying it out on an empty stack would kill Cmd+Z inside every text field.
    var undoMenuTitle: String { entries.last?.undoMenuTitle ?? "Undo" }

    func record(_ entry: QueueUndoEntry) {
        entries.append(entry)
    }

    // Removes and returns the most recent entry. No redo, by Dan's explicit decision, so a taken entry
    // is discarded rather than parked anywhere it could come back from.
    func takeTop() -> QueueUndoEntry? {
        entries.popLast()
    }

    func clear() {
        entries.removeAll()
    }
}

// Where a Cmd+Z should go (#1412's second question, answered when that spike passed on 2026-07-24).
//
// The spike proved the app CAN own Cmd+Z without costing Dan ordinary text editing, and in the same
// run it ruled out the obvious wiring. `NSApp.sendAction(undo:)` returns TRUE whenever any text field
// holds focus, even with an empty undo stack and nothing typed: it reports that something ACCEPTED
// the action, not that any work happened. So "forward first, fall back to the queue when that fails"
// would make the queue undo permanently unreachable while a text field has focus.
//
// That is a live failure here rather than a nicety, because focus in this app is often INVISIBLE (a
// TextEditor holds it with no visible ring). Dan would dismiss a show, press Cmd+Z, and watch nothing
// happen, with nothing on screen explaining why.
//
// A pure function, so the rule is testable without the responder chain, which the test bundle cannot
// reach at all. Only its two inputs are read from AppKit.
enum UndoDestination: Equatable, Sendable {
    case textEditing
    case queueAction
    case nothing
}

enum UndoRouting {
    // Typing wins whenever the focused field has REAL pending edits, matching every other Mac app:
    // undoing a dismiss while the cursor sits mid-sentence in an email body would be alarming. It only
    // falls through to the queue when that field has nothing of its own to give back.
    static func destination(textEditingCanUndo: Bool, queueCanUndo: Bool) -> UndoDestination {
        if textEditingCanUndo { return .textEditing }
        if queueCanUndo { return .queueAction }
        return .nothing
    }

    // Whether the menu command hands the keystroke to the responder chain rather than reversing a queue
    // action. Everything except a queue undo forwards, INCLUDING `.nothing`, and that is a safety
    // property rather than a tidiness one.
    //
    // `undoManager?.canUndo` is a weaker signal than what the #1412 spike proved, since the spike passed
    // with an item that ALWAYS forwards. If a focused field's undo manager is not reachable where the
    // app reads it, that read comes back false and a keystroke that would have undone Dan's typing gets
    // dropped. Forwarding on `.nothing` costs nothing (a chain with nothing to give back does nothing)
    // and keeps the shipped behaviour identical to the version verified on screen while the stack is
    // empty, which it is until #1414.
    static func forwardsToResponderChain(_ destination: UndoDestination) -> Bool {
        destination != .queueAction
    }
}
