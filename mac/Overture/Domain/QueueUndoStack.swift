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

    // The title the Edit menu shows for this entry, e.g. "Dismiss: The Music Shop".
    var menuLabel: String { "\(actionLabel): \(groupName)" }

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

    // The Edit menu item's title, nil when there is nothing to undo (the item is then disabled).
    var topLabel: String? { entries.last?.menuLabel }

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
