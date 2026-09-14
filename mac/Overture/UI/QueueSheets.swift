import SwiftUI
import SwiftData

// #3658 Phase 8: the eight sheets the queue can raise, and the state that raises them.
//
// WHAT THIS IS FOR. `QueueView.body`'s first line is `let data = makeRenderData()`, the derivation over
// every show in the store. While each of these eight lived as `@State` on `QueueView`, opening a reply
// sheet paid that derivation, and dismissing it paid it again, and neither changes one row of store data.
// Held on an OBSERVED object instead, a write reaches only the views that READ the property, and the one
// reader is `QueueSheetHost` below, whose body is eight modifiers over a content it already holds.
//
// WHY THE STATE MOVED AND THE MODIFIERS DID NOT. `.sheet(item:)` presentation from a nested view is not
// behaviour-neutral on macOS, and eight presenters on one view is L242's shape: all but one request past
// the first is silently ignored. Splitting them across children would change WHICH of the eight can be
// shown at once and in which direction, and "each one still presents correctly" is a happy-path check
// that structurally cannot see either failure (a second condition swallowed, L242, or one flag bound by
// two surfaces so dismissing one leaves the other standing, L238).
//
// So all eight are applied HERE, in one place, in exactly the order they were applied before: the three
// that hung off `mainContent` first, then the five that hung off `body`. That order is preserved
// deliberately, because it is what decides which sheet wins, and this phase is about cost rather than
// about that decision.
//
// WHAT HAPPENS WHEN A SECOND CONDITION ARRIVES WHILE ONE IS OPEN, stated because the phase requires it
// and unchanged by this phase: each flag REPLACES its own previous value, and two DIFFERENT flags are
// both recorded while SwiftUI presents one. `QueueSheetStateTests` drives both cases.

// #1308 Layer 2: the pending "Check reachability" confirm, holding the date's candidate keys.
//
// #3658: lifted out of `QueueView` unchanged, because the holder below has to be able to name its type.
struct ProbeConfirm: Identifiable {
    let id = UUID()
    let keys: [String]
    let dateLabel: String
    // #1597: set only for a multi-date selection, whose sentences come from ProbeSelectionCopy.
    // Absent means the single-date wording, unchanged.
    var title: String? = nil
    var message: String? = nil
}

// #1219: a committing action (Approve or Re-prep) waiting on the self-booking confirm, so the naming
// and the action to run stay out of the button wiring and the confirm reads from one place.
struct SelfBookingGuard: Identifiable {
    let key: String
    let title: String
    let proceedLabel: String
    let message: String
    let proceed: () -> Void
    var id: String { key }
}

// #1500: the night Dan right-clicked, the reason he picked, and the rows that were on screen when he
// picked it. The keys are captured at that moment rather than re-derived on confirm, so a scout landing
// between the menu and the button cannot widen what he agreed to.
struct NightDismiss: Identifiable {
    let dateLabel: String
    let reason: ShowOutcome
    let keys: [String]
    let runs: [String]
    // The narrower set: the shows that play only on this night. Empty when there is no choice to make.
    let keysOnlyThisNight: [String]
    // #3365: through BulkDismiss, never restated here. It was a second copy of the same rule, and the
    // rule has just gained a condition (a one-night reason offers no choice); a copy would have kept
    // the buttons and the sentence above them disagreeing about whether there was one (#863).
    var offersChoice: Bool {
        BulkDismiss.offersChoice(reason: reason, runsPastTheNight: runs,
                                 keysOnlyThisNight: keysOnlyThisNight)
    }
    var id: String { "\(dateLabel)|\(reason.rawValue)" }
}

// What the queue is currently asking Dan, if anything.
//
// EIGHT INDEPENDENT OPTIONALS AND NOT ONE ENUM, and that is a deliberate refusal to change behaviour
// inside a performance change. One enum would make "two conditions at once" impossible to express, which
// sounds like an improvement and is a different product: today the second is RECORDED and not shown, and
// whether it should instead be queued, refused or allowed to replace the first is a question for whoever
// owns that decision, not a side effect of moving where the state lives (L542).
@Observable
final class QueueSheetState {
    // #1436: compose and send Dan's reply to a hire inquiry.
    var replyingTo: Inquiry?
    // #2145: the one reply screen, told which contact on which show it is answering.
    var answeringReply: ReplyTarget?
    // The per-row nudge, waiting on its confirm.
    var pendingRowNudge: PendingRowNudge?
    // #1504: the intake sheet, opened on an existing record.
    var editingInquiry: Inquiry?
    // #2718: Dan's manual route, for when the search found their reply and did not back it.
    var manualLinkTarget: ManualLinkTarget?
    // #1219/#1249: an Approve or a per-row Re-prep landing on a date that already holds a pitch.
    var pendingSelfBookingGuard: SelfBookingGuard?
    // #1308 Layer 2: a reachability probe waiting to be paid for.
    var pendingProbe: ProbeConfirm?
    // #1500: a whole night waiting to be buried.
    var pendingNightDismiss: NightDismiss?

    /// Whether anything at all is being asked. Used by the tests that drive two at once, and by nothing
    /// on the render path: a reader here would put every sheet write back on whoever read it.
    var isAsking: Bool {
        replyingTo != nil || answeringReply != nil || pendingRowNudge != nil || editingInquiry != nil
            || manualLinkTarget != nil || pendingSelfBookingGuard != nil || pendingProbe != nil
            || pendingNightDismiss != nil
    }
}

// The one place the queue's eight sheets are presented.
//
// The content arrives as a CLOSURE, on `QueueScrollHolder`'s precedent (#1774) and for its reason: a
// built view would be constructed in `QueueView.body`, which is the pass this exists to keep out of the
// way. The closure captures the `RenderData` the caller already derived, so raising a sheet re-runs this
// body and the view construction under it, and never the derivation.
struct QueueSheetHost<Content: View>: View {
    @Bindable var sheets: QueueSheetState
    // Read from the pass rather than derived here: a snapshot, correct at the moment the sheet opens,
    // which is the only moment it is read.
    let gmailConnected: Bool
    // #1597: cleared when a probe is approved, so the bar Dan ticked empties with the run he started.
    let probeSelection: ProbeSelectionState
    let onProbe: (Set<String>) -> Void
    let onDismissNight: (NightDismiss, [String]) -> Void
    let onRowNudge: (PendingRowNudge, String?) -> Void
    let content: () -> Content

    // Read from the environment rather than threaded down, because `ReplySheet` composes against them
    // and every ancestor of this view already provides both.
    @Environment(\.modelContext) private var context
    @Environment(ActionFeedback.self) private var feedback

    var body: some View {
        content()
            // #1219/#1249: confirm an Approve or a per-row Re-prep that lands on a date already holding a
            // pitch. First-party branded sheet (SelfBookingConfirmSheet), not a stock system dialog.
            .sheet(item: $sheets.pendingSelfBookingGuard) { pending in
                SelfBookingConfirmSheet(
                    title: pending.title, message: pending.message, proceedLabel: pending.proceedLabel,
                    onProceed: { pending.proceed(); sheets.pendingSelfBookingGuard = nil },
                    onCancel: { sheets.pendingSelfBookingGuard = nil })
            }
            // #1308 Layer 2: confirm an opt-in reachability probe before it spends. Reuses the same
            // first-party branded sheet; the copy states the honest cost (free for shows Dan keeps).
            .sheet(item: $sheets.pendingProbe) { pending in
                SelfBookingConfirmSheet(
                    title: pending.title ?? ReachabilityProbeCopy.confirmTitle(count: pending.keys.count),
                    message: pending.message
                        ?? ReachabilityProbeCopy.confirmMessage(dateLabel: pending.dateLabel,
                                                                count: pending.keys.count),
                    proceedLabel: ReachabilityProbeCopy.confirmProceed,
                    onProceed: {
                        onProbe(Set(pending.keys))
                        probeSelection.clear()
                        sheets.pendingProbe = nil
                    },
                    onCancel: { sheets.pendingProbe = nil })
            }
            // #1500: confirm a whole night before it goes. The count is the point: Dan has to know exactly
            // how much he is about to bury, and which run loses its later dates with it.
            .sheet(item: $sheets.pendingNightDismiss) { pending in
                SelfBookingConfirmSheet(
                    title: BulkDismiss.confirmTitle(count: pending.keys.count, dateLabel: pending.dateLabel),
                    message: BulkDismiss.confirmMessage(count: pending.keys.count, reason: pending.reason,
                                                        runs: pending.runs, dateLabel: pending.dateLabel,
                                                        offeringChoice: pending.offersChoice),
                    proceedLabel: BulkDismiss.confirmProceed(count: pending.keys.count,
                                                             offeringChoice: pending.offersChoice),
                    symbol: "archivebox",
                    // #1500 follow-up (Dan, 2026-07-26): leave the runs where they are and clear only what
                    // plays tonight. Offered only when a night actually holds both kinds.
                    alternativeLabel: pending.offersChoice
                        ? BulkDismiss.confirmProceedOnlyThisNight(count: pending.keysOnlyThisNight.count)
                        : nil,
                    onAlternative: pending.offersChoice
                        ? { onDismissNight(pending, pending.keysOnlyThisNight); sheets.pendingNightDismiss = nil }
                        : nil,
                    onProceed: { onDismissNight(pending, pending.keys); sheets.pendingNightDismiss = nil },
                    onCancel: { sheets.pendingNightDismiss = nil })
            }
            // #1436: compose and send Dan's reply to a hire inquiry, through the SAME screen a scouted
            // show is answered on since #2145. One list should not behave two ways.
            .sheet(item: $sheets.replyingTo) { inquiry in
                ReplySheet(composition: .answering(inquiry, context: context, feedback: feedback),
                           gmailConnected: gmailConnected)
            }
            .sheet(item: $sheets.pendingRowNudge) { pending in
                SendConfirmSheet(confirmation: pending.confirmation,
                                 onSend: { onRowNudge(pending, nil) },
                                 onCancel: { sheets.pendingRowNudge = nil },
                                 // #2575: both kinds this sheet raises are composed end to end by
                                 // Overture, so both get the box.
                                 onSendEdited: { onRowNudge(pending, $0) })
            }
            .sheet(item: $sheets.answeringReply) { target in
                // #2145: the one reply screen, told what it is answering. An inquiry builds its own
                // composition and reaches the same screen.
                ReplySheet(composition: .answering(target.recipient, of: target.prospect,
                                                   context: context, feedback: feedback),
                           gmailConnected: gmailConnected)
            }
            // #1504: the same sheet that logs one, opened on an existing record.
            .sheet(item: $sheets.editingInquiry) { InquiryIntakeSheet(editing: $0) }
            // #2718: Dan's manual route, for when the search found their reply and did not back it.
            .sheet(item: $sheets.manualLinkTarget) { target in
                LinkReplyPicker(prospect: target.prospect, recipient: target.recipient) {
                    sheets.manualLinkTarget = nil
                }
            }
    }
}
