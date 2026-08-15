import Foundation
import SwiftData

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
    // One row's before-and-after. #1500 made an action able to cover a whole night at once, so the
    // snapshot moved down a level: the entry is what Dan DID, and this is what it did to each show.
    struct Row: Equatable, Sendable {
        let naturalKey: String
        let groupName: String

        // Where the row came FROM, which is what undo restores. Recorded rather than inferred: a keep from
        // the Review stage and a keep from the queue land the row in different places, and guessing at an
        // inverse is exactly the mistake #752's snapshot exists to avoid.
        let priorStatus: ReviewStatus
        let priorShowOutcomeRaw: String?
        // `Prospect.markDismissed` stamps `dismissedAt` only when it is nil, so a show dismissed twice keeps
        // its FIRST exit date. Undoing the second dismissal has to put that original date back rather than
        // clear it, or the row loses the record of when it first left the queue (#16 counts on that date).
        let priorDismissedAt: Date?

        // #1583: the date clash Dan had accepted before this action, because Keep now accepts one. Held as
        // the KEY rather than a "did it accept anything" boolean: a show can already carry an older
        // acceptance, and restoring `nil` over it would silently throw away a judgment he made earlier.
        //
        // Deliberately NOT defaulted anywhere it is recorded, on the same reasoning as `needsPrep`'s own
        // conflict gate. Defaulted to nil it is silently wrong for every action that does NOT touch the
        // clash: undoing a dismiss would restore "nothing accepted" over a real acceptance and re-block a
        // show Dan had waved through, which is invisible from the call site that forgot to pass it.
        let priorConflictClearedKey: String?

        // Where the action LEFT the row. Not restored; this is the precondition.
        let resultingStatus: ReviewStatus
        let resultingShowOutcomeRaw: String?

        // #2691: the night this action DROPPED from a run, when it dropped one rather than dismissing
        // the show. nil for every other action, which is almost all of them.
        //
        // A drop leaves the status and the reason exactly where they were, so `stillApplies` above can
        // never notice one; what it changes is `performanceDate` and the natural key. That is why this
        // row's `naturalKey` is recorded AFTER the drop: it is what the row is keyed on by the time
        // Cmd+Z is pressed, and recording the old key would look up something nothing holds and make the
        // press silently do nothing while looking exactly like a working undo (#1415).
        var droppedNight: String? = nil

        // Is the row still exactly how this action left it? If anything moved it since (a background
        // writer, a later action of Dan's, a scout import), undoing would clobber something newer, so this
        // row no longer applies.
        //
        // Checks the dismiss REASON as well as the status, and that is the case a status-only check misses:
        // re-labelling why a dismissed show was cut leaves it dismissed, so undo would restore the row and
        // silently discard the newer reason.
        func stillApplies(status: ReviewStatus, showOutcomeRaw: String?) -> Bool {
            status == resultingStatus && showOutcomeRaw == resultingShowOutcomeRaw
        }
    }

    // Held as one row plus the rest, rather than an array, so "an entry always covers at least one show"
    // is structural. An empty entry would sit on the stack and swallow a Cmd+Z while appearing to work.
    let primaryRow: Row
    let otherRows: [Row]
    var rows: [Row] { [primaryRow] + otherRows }

    // What Dan did, for the menu title ("Undo Dismiss: The Music Shop"). Held as text rather than an
    // enum because the menu is the only reader, and an enum would invite behaviour to hang off it.
    let actionLabel: String

    // #1500: what the menu calls a whole night ("5 shows on Jul 24"), when the action took more than one
    // show. nil for the ordinary one-show action, which names the show itself.
    let batchLabel: String?

    // The single-row reads every existing caller makes, kept so one action on one show stays the simple
    // thing it was. They speak for the primary row, which for a single-row entry is the only row.
    var naturalKey: String { primaryRow.naturalKey }
    var groupName: String { primaryRow.groupName }
    var priorStatus: ReviewStatus { primaryRow.priorStatus }
    var priorShowOutcomeRaw: String? { primaryRow.priorShowOutcomeRaw }
    var priorDismissedAt: Date? { primaryRow.priorDismissedAt }
    var resultingStatus: ReviewStatus { primaryRow.resultingStatus }
    var resultingShowOutcomeRaw: String? { primaryRow.resultingShowOutcomeRaw }

    // #1473: a stretch of days Dan blocked BECAUSE of this dismiss, so one press takes both back.
    //
    // A `var` with a default, unlike everything above it, and that is forced by the order Dan meets the
    // two halves in: he dismisses the show, and only then picks the days in the sheet the dismissal
    // opened. The entry cannot be built complete, so it is amended once, by `attachBlockedDaysOff`.
    //
    // Held as the two day strings rather than the `DayOff` row, for the reason the natural key is held
    // rather than the `Prospect`: the row can be deleted while this entry is on the stack (Dan can also
    // reverse just the block, from the banner), so it is looked up fresh at undo time and its absence is
    // an ordinary outcome.
    var blockedDays: BlockedDays?

    struct BlockedDays: Equatable, Sendable {
        let start: String       // yyyy-MM-dd, inclusive
        let end: String         // yyyy-MM-dd, inclusive
    }

    // The Edit menu's title for this entry, e.g. "Undo Dismiss: The Music Shop". A WHOLE sentence in one
    // place, not a fragment the menu prefixes: #863's guard rejects a view composing its own copy, and a
    // sentence assembled at the call site is invisible to the copy inventory (#915), so Dan's PR would
    // not show the words he is going to read.
    //
    // #1479: when a block of days off rode along on this dismiss (#1473), the single press reverses both, and
    // un-flags every other show that block held back. The title names that whole action so Dan can tell it
    // apart from a plain dismiss BEFORE he presses; "Undo Dismiss: X" would promise less than the press does.
    // #1500: a whole night says so ("Undo Dismiss: 5 shows on Jul 24"). Naming the first show's org would
    // promise one show back and give back five.
    var undoMenuTitle: String {
        let subject = batchLabel ?? groupName
        if blockedDays != nil {
            return "Undo \(actionLabel) and Days Off: \(subject)"
        }
        return "Undo \(actionLabel): \(subject)"
    }

    func stillApplies(status: ReviewStatus, showOutcomeRaw: String?) -> Bool {
        primaryRow.stillApplies(status: status, showOutcomeRaw: showOutcomeRaw)
    }

    // The one-show action: the shape every caller but #1500's night uses.
    init(naturalKey: String, groupName: String, actionLabel: String,
         priorStatus: ReviewStatus, priorShowOutcomeRaw: String?, priorDismissedAt: Date?,
         priorConflictClearedKey: String?,
         resultingStatus: ReviewStatus, resultingShowOutcomeRaw: String?,
         droppedNight: String? = nil) {
        self.init(actionLabel: actionLabel, batchLabel: nil,
                  primaryRow: Row(naturalKey: naturalKey, groupName: groupName,
                                  priorStatus: priorStatus, priorShowOutcomeRaw: priorShowOutcomeRaw,
                                  priorDismissedAt: priorDismissedAt,
                                  priorConflictClearedKey: priorConflictClearedKey,
                                  resultingStatus: resultingStatus,
                                  resultingShowOutcomeRaw: resultingShowOutcomeRaw,
                                  droppedNight: droppedNight),
                  otherRows: [])
    }

    private init(actionLabel: String, batchLabel: String?, primaryRow: Row, otherRows: [Row]) {
        self.actionLabel = actionLabel
        self.batchLabel = batchLabel
        self.primaryRow = primaryRow
        self.otherRows = otherRows
    }

    // #1500: one action over a whole night, as ONE entry, so Cmd+Z gives the night back in one press
    // rather than one press per card. Refuses an empty set rather than recording an entry that would
    // swallow the next press and appear to have done something.
    static func batch(actionLabel: String, label: String, rows: [Row]) -> QueueUndoEntry? {
        guard let first = rows.first else { return nil }
        return QueueUndoEntry(actionLabel: actionLabel, batchLabel: label,
                              primaryRow: first, otherRows: Array(rows.dropFirst()))
    }
}

extension QueueUndoEntry.Row {
    // Built from the row itself, AFTER the mutation, with the three "prior" values read off it before.
    // Reading the result from the row rather than being told it means the precondition is measured
    // against what actually happened, not against what the caller believed it was doing.
    //
    // #1500: the single place that rule lives, now that two actions record one (one show, or a night).
    @MainActor
    init(recording prospect: Prospect,
         priorStatus: ReviewStatus, priorShowOutcomeRaw: String?, priorDismissedAt: Date?,
         priorConflictClearedKey: String?, droppedNight: String? = nil) {
        self.init(naturalKey: prospect.naturalKey,
                  groupName: prospect.groupName,
                  priorStatus: priorStatus,
                  priorShowOutcomeRaw: priorShowOutcomeRaw,
                  priorDismissedAt: priorDismissedAt,
                  priorConflictClearedKey: priorConflictClearedKey,
                  resultingStatus: prospect.status,
                  resultingShowOutcomeRaw: prospect.showOutcomeRaw,
                  droppedNight: droppedNight)
    }
}

extension QueueUndoEntry {
    @MainActor
    init(recording actionLabel: String, on prospect: Prospect,
         priorStatus: ReviewStatus, priorShowOutcomeRaw: String?, priorDismissedAt: Date?,
         priorConflictClearedKey: String?, droppedNight: String? = nil) {
        let row = Row(recording: prospect, priorStatus: priorStatus,
                      priorShowOutcomeRaw: priorShowOutcomeRaw, priorDismissedAt: priorDismissedAt,
                      priorConflictClearedKey: priorConflictClearedKey, droppedNight: droppedNight)
        self.init(naturalKey: row.naturalKey, groupName: row.groupName, actionLabel: actionLabel,
                  priorStatus: row.priorStatus, priorShowOutcomeRaw: row.priorShowOutcomeRaw,
                  priorDismissedAt: row.priorDismissedAt,
                  priorConflictClearedKey: row.priorConflictClearedKey,
                  resultingStatus: row.resultingStatus,
                  resultingShowOutcomeRaw: row.resultingShowOutcomeRaw,
                  droppedNight: row.droppedNight)
    }
}

// Performing an undo (#1414).
//
// Applies the captured snapshot directly rather than routing back through `markDismissed` /
// `clearDismissal`. Those two derive the exit date (`dismissedAt = dismissedAt ?? now`, and nil on a
// restore), so undoing a RESTORE through them would stamp TODAY over the show's real exit date and
// quietly corrupt the #1403 funnel data, which counts when a show left the queue. The entry already
// holds the true values, so there is nothing to re-derive: put back exactly what was there.
enum QueueUndo {
    // How much of the entry actually came back. #1500 made an entry able to cover several shows, and the
    // caller has to be able to tell "the night is back" from "four of the five are back": since #1134 the
    // store and the visible stage move independently, so a partial restore and a whole one look identical
    // on screen unless the banner says otherwise (#1415).
    struct Outcome: Equatable, Sendable {
        let restored: Int
        let total: Int

        var didAnything: Bool { restored > 0 }
        var isPartial: Bool { restored > 0 && restored < total }
        var missed: Int { total - restored }
    }

    // Applies every row of the entry that is still exactly how the action left it, and reports how many
    // that was. A row that is gone (deleted at runtime by NaturalKeyVenueMigration) or that moved on is an
    // ordinary outcome, not an error, which is why an entry holds keys rather than objects.
    //
    // The precondition is what replaced the "wall". A background writer (the reconcile tick, a scout
    // import, a retirement sweep), a later action of Dan's, and a send that moved the show on are all
    // the same situation seen from here: the row is not what this entry describes, so leave it alone.
    // #1473: the context is REQUIRED rather than optional-with-a-default, so no call site can quietly get
    // the row half of an undo and leave the night blocked. That half-undo is the exact bug this fixes, and
    // it is invisible from the keyboard: the show comes back, so the press looks like it worked.
    @MainActor
    @discardableResult
    static func apply(_ entry: QueueUndoEntry, resolving lookup: (String) -> Prospect?,
                      in context: ModelContext,
                      export: DayOffEditing.Export = DownbeatBridge.loadedExport()) -> Outcome {
        let applicable = entry.rows.compactMap { row -> (Prospect, QueueUndoEntry.Row)? in
            guard let prospect = lookup(row.naturalKey),
                  row.stillApplies(status: prospect.status,
                                   showOutcomeRaw: prospect.showOutcomeRaw) else { return nil }
            return (prospect, row)
        }
        guard !applicable.isEmpty else { return Outcome(restored: 0, total: entry.rows.count) }
        // The precondition is checked BEFORE the day off is touched, not after. A stale entry means Dan's
        // row moved on under him, and taking the block off anyway would silently unblock a night he told
        // Overture he cannot work, freeing every show on it to be drafted and sent.
        //
        // `DayOffEditing.remove` re-runs the conflict sweep, so the shows this block flagged are un-flagged
        // in the same press. A range with no row left (he already took the block back from the banner) is
        // an ordinary outcome: the block is gone, which is what the undo wanted.
        if let blocked = entry.blockedDays,
           let row = DayOffEditing.rows(in: context)
               .first(where: { $0.startDate == blocked.start && $0.endDate == blocked.end }) {
            DayOffEditing.remove(row, export: export, in: context)
        }
        // #2754: a night whose date another card has taken since the drop cannot come back, and this row
        // is then left entirely alone rather than half-undone. Counted as NOT restored, which is the same
        // reading this already gives a row that moved on under Dan: the banner may not say a show is back
        // when it is not (L12). The night is restored FIRST, before the status writes, so the decision and
        // the writes cannot disagree, and `restoreNight` stays the one place that knows the rule (L16).
        var blocked = 0
        for (prospect, row) in applicable {
            if let night = row.droppedNight, prospect.restoreNight(night, in: context) == false {
                blocked += 1
                continue
            }
            prospect.status = row.priorStatus
            prospect.showOutcomeRaw = row.priorShowOutcomeRaw
            prospect.dismissedAt = row.priorDismissedAt
            // #1583: Keep accepts a date clash, so undoing a Keep has to put the clash back. Applied
            // unconditionally rather than only when the action changed it: the entry holds what was there,
            // so restoring it is a no-op for every action that never touched it, and there is no "did this
            // one accept a clash" flag to get wrong.
            prospect.restoreConflictClearance(row.priorConflictClearedKey)
        }
        return Outcome(restored: applicable.count - blocked, total: entry.rows.count)
    }

    // The one-show call, unchanged for every caller that reverses a single action on a single row.
    @MainActor
    @discardableResult
    static func apply(_ entry: QueueUndoEntry, to prospect: Prospect?, in context: ModelContext,
                      export: DayOffEditing.Export = DownbeatBridge.loadedExport()) -> Bool {
        apply(entry, resolving: { _ in prospect }, in: context, export: export).didAnything
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
        QueueWriteTrace.note(QueueWriteTrace.undoStack)
        entries.append(entry)
    }

    // #1473: fold a day off Dan just blocked into the dismiss that led to it, so Cmd+Z reverses the whole
    // action. Returns whether it attached, which is the caller's only way to know: silence would make a
    // half-undo indistinguishable from a whole one.
    //
    // Attaches ONLY to the top entry, and only when that entry is a dismiss of this same show with nothing
    // attached yet. Every other case is left alone deliberately rather than searched for: a block that did
    // not come from the top entry's dismiss riding on it would mean an unrelated Cmd+Z silently deleting a
    // day off Dan is counting on. Nothing is lost by refusing, because `blockDaysOff` offers its own banner
    // Undo for the block either way.
    @discardableResult
    func attachBlockedDaysOff(start: String, end: String, toDismissOf naturalKey: String) -> Bool {
        guard var top = entries.last,
              top.naturalKey == naturalKey,
              top.resultingStatus == .dismissed,
              top.blockedDays == nil else { return false }
        QueueWriteTrace.note(QueueWriteTrace.undoStack)
        top.blockedDays = QueueUndoEntry.BlockedDays(start: start, end: end)
        entries[entries.count - 1] = top
        return true
    }

    // Removes and returns the most recent entry. No redo, by Dan's explicit decision, so a taken entry
    // is discarded rather than parked anywhere it could come back from.
    func takeTop() -> QueueUndoEntry? {
        QueueWriteTrace.note(QueueWriteTrace.undoStack)
        return entries.popLast()
    }

    func clear() {
        QueueWriteTrace.note(QueueWriteTrace.undoStack)
        entries.removeAll()
    }
}

// The App's menu command asking the window to perform an undo (#1414).
//
// A bridge is needed rather than the menu just doing the work, because performing an undo needs the
// ModelContext, the live prospects and the ActionFeedback, all of which live in RootView, and #1413's
// constraint stands: the App must never capture the feedback object. Overture is LSUIElement, so
// closing the window tears RootView down while the process lives on in the menu bar, and a captured
// feedback object would post to something no view observes.
//
// Raising a token instead means the request simply goes unanswered when there is no window, which is
// the correct outcome: there is nothing on screen for an undo to put back. Mirrors DayOffOfferRequest,
// which solves the same shape in the other direction.
@Observable
@MainActor
final class QueueUndoRequest {
    // Monotonic, not a Bool: two undos in a row are two distinct requests, and a flag would collapse
    // the second one into the first if the view had not observed it yet.
    private(set) var token = 0

    func request() {
        QueueWriteTrace.note(QueueWriteTrace.undoRequest)
        token += 1
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
