import SwiftUI
import SwiftData

// The one place that builds a fully wired ProspectRowView, so QueueView and ArchiveView
// share this construction instead of each repeating the same ~20 line callback list. onSend and
// onSendReply stay as caller supplied closures (not routed through ProspectMutations here) because
// they trigger a screen local confirm dialog and live "Sending..." state; everything else needs
// nothing screen specific and is wired directly to ProspectMutations.
@MainActor
enum ProspectRowFactory {
    @ViewBuilder
    static func row(_ item: QueueItem, today: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback,
                    dayOffOffer: DayOffOfferRequest,
                    // #1770: HANDED IN, never sourced here. This used to read GmailAuthManager.shared
                    // .isConnected, which opens and JSON-decodes the token file: one synchronous disk read
                    // per card, on the main thread, on every scroll frame. It is one fact about the app,
                    // identical for every row, so the caller reads it once (GmailConnection, itself cached)
                    // and passes it down. Deliberately no default: a default would let a call site ship a
                    // silently wrong answer, and being wrong here disables Send on a connected account.
                    gmailConnected: Bool,
                    // #2267: pressing "Check again" spends money, so the caller raises the same
                    // confirmation the date selection uses and starts the run. Optional: a surface with
                    // no run machinery (Archive) simply passes nothing and the control marks the show
                    // for the next check instead, which is what #2261 shipped.
                    onRecheckNow: ((QueueItem) -> Void)? = nil,
                    prepRunning: Bool = false,
                    probeRunning: Bool = false,
                    // #1414: optional so a surface that does not offer undo (and any future caller)
                    // simply passes nothing rather than every call site growing a parameter it ignores.
                    undoStack: QueueUndoStack? = nil,
                    highlightedKey: String?, highlightedRecipientId: String? = nil, outboundSendSince: Date?,
                    replySendSince: @escaping (String) -> Date?,
                    onSend: @escaping () -> Void, onSendReply: @escaping (String) -> Void,
                    // #1219: Re-prep is a committing moment that may need a screen-local self-booking
                    // confirm before it runs (like onSend), so the caller can supply it here.
                    // Omitted (ArchiveView), it falls back to the direct ProspectMutations call.
                    onReprep: ((ReprepMode) -> Void)? = nil,
                    onRestore: (() -> Void)? = nil, showingTooFar: Bool = false,
                    userExcludedTowns: Set<String> = [],
                    allowedSeedTowns: Set<String> = []) -> some View {
        let row = ProspectRowView(
            item: item,
            today: today,
            onKeep: { ProspectMutations.setStatus(item, .queued, nil, prospects: prospects, context: context, feedback: feedback, undo: undoStack, undoLabel: "Keep") },
            onDismiss: { reason in ProspectMutations.dismissForReason(item, reason, prospects: prospects, context: context, feedback: feedback, offer: dayOffOffer, undo: undoStack) },
            onUnapprove: { ProspectMutations.setStatus(item, .drafted, nil, prospects: prospects, context: context, feedback: feedback) },
            onSkipDraft: { ProspectMutations.setStatus(item, .dismissed, .notAFit, prospects: prospects, context: context, feedback: feedback) },
            // #1824: the launch renders this show's listing page first, so it is awaited from a task rather
            // than blocking the click.
            onReprep: onReprep ?? { mode in
                Task { @MainActor in
                    await ProspectMutations.reprep(item, mode: mode, prospects: prospects, context: context,
                                                   feedback: feedback)
                }
            },
            // #2007: prep this show by hand. The prefill is a CLOSURE, called only when the sheet opens:
            // it walks every prospect and reads the booking-history file, and a queue is hundreds of
            // cards, so an idle card must pay nothing for a control it is merely offering.
            onPrepManually: { email, name, subject, body, sendsTogether in
                ProspectMutations.prepManually(item, email: email, name: name, subject: subject,
                                               body: body, sendsTogether: sendsTogether,
                                               prospects: prospects, context: context,
                                               feedback: feedback)
            },
            manualPrepPrefill: { ProspectMutations.manualPrepPrefill(item, prospects: prospects) },
            onSaveDraft: { subject, body in ProspectMutations.saveDraft(item, subject, body, prospects: prospects, context: context, feedback: feedback) },
            onSaveOpening: { recipientId, opening in
                ProspectMutations.saveOpening(item, recipientId: recipientId, opening: opening,
                                              prospects: prospects, context: context, feedback: feedback)
            },
            onSaveJointOpening: { opening in
                ProspectMutations.saveJointOpening(item, opening: opening,
                                                   prospects: prospects, context: context, feedback: feedback)
            },
            onSetSendsTogether: { together in
                ProspectMutations.setSendsTogether(item, together,
                                                   prospects: prospects, context: context, feedback: feedback)
            },
            onSetLostReason: { reason in ProspectMutations.setLostReason(item, reason, prospects: prospects, context: context, feedback: feedback) },
            onSend: onSend,
            onOverrideSalutationReview: { ProspectMutations.overrideSalutationReview(item, prospects: prospects, context: context, feedback: feedback) },
            onOverrideDraftLint: { ProspectMutations.overrideDraftLint(item, prospects: prospects, context: context, feedback: feedback) },
            onDismissReply: { ProspectMutations.dismissReply(item, prospects: prospects, context: context, feedback: feedback) },
            // #1752: Dan says where this card's room is. The answer is stored against the ROOM, so it
            // reaches every show played there and every show that arrives there later, which is why it
            // goes through the same recorder the Sources sheet's list uses rather than writing this row.
            onNameRoom: { venue, location in
                WatchlistMutations.saveRoomPlace(room: UnplacedRooms.Room(key: venue, name: venue, showCount: 0),
                                                 to: location, context: context, feedback: feedback)
            },
            onBeginFormPitch: { rid, formURL in
                ProspectMutations.beginFormPitch(item, rid, formURL, prospects: prospects, context: context, feedback: feedback)
            },
            onRecordFormPitch: { rid in
                ProspectMutations.recordFormPitch(item, rid, prospects: prospects, context: context, feedback: feedback)
            },
            onCancelFormPitch: { rid in
                ProspectMutations.cancelFormPitch(item, rid, prospects: prospects, context: context, feedback: feedback)
            },
            onMarkContact: { rid, resolution, bounced in
                ProspectMutations.markContact(item, rid, resolution, bounced, prospects: prospects, context: context, feedback: feedback)
            },
            // #2395: an ending goes to the SHOW, through the one write every menu shares.
            onRecordOutcome: { outcome in
                ProspectMutations.recordOutcome(item, outcome, prospects: prospects,
                                                context: context, feedback: feedback)
            },
            onReopenOutcome: {
                ProspectMutations.reopenOutcome(item, prospects: prospects,
                                                context: context, feedback: feedback)
            },
            onSetRecipientConversationState: { rid, state in
                ProspectMutations.setRecipientConversationState(item, rid, state, prospects: prospects, context: context, feedback: feedback)
            },
            onConfirmRecipientConversationState: { rid in
                ProspectMutations.confirmRecipientConversationState(item, rid, prospects: prospects, context: context, feedback: feedback)
            },
            onAddRecipient: { email, name in
                ProspectMutations.addRecipientManually(item, email: email, name: name,
                                                        prospects: prospects, context: context, feedback: feedback)
            },
            onRemoveRecipient: { rid in
                let name = item.contacts.first(where: { $0.id == rid })?.displayName
                ProspectMutations.removeRecipientManually(item, rid, name,
                                                          prospects: prospects, context: context, feedback: feedback)
            },
            // #2392: an address struck at triage. A contact this show researched goes through the SAME
            // path the draft-review panel's Remove uses, so the two are one implementation; an inherited
            // one has no row here and is refused for the ORGANISATION instead (Dan's call, 2026-08-09).
            onRemoveContactAddress: { address in
                if let rid = address.recipientId {
                    let name = item.contacts.first(where: { $0.id == rid })?.displayName
                    ProspectMutations.removeRecipientManually(item, rid, name,
                                                              prospects: prospects, context: context,
                                                              feedback: feedback)
                } else {
                    ProspectMutations.removeInheritedAddress(item, email: address.email,
                                                             prospects: prospects, context: context,
                                                             feedback: feedback)
                }
            },
            onDismissContactReply: { rid in ProspectMutations.dismissContactReply(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDismissContactBounce: { rid in ProspectMutations.dismissContactBounce(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDismissVenueMatch: { rid in ProspectMutations.dismissVenueMatch(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDismissPressContactMatch: { rid in ProspectMutations.dismissPressContactMatch(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDismissDuplicateContactMatch: { rid in ProspectMutations.dismissDuplicateContactMatch(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDraftReply: { rid in ProspectMutations.draftReply(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onSendReply: onSendReply,
            onCopyReply: { rid in ProspectMutations.copyReply(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onEditReplyDraft: { rid, body in ProspectMutations.editReplyDraft(item, rid, body, prospects: prospects, context: context, feedback: feedback) },
            // #1038: a run-level cancel (the reply-classify run drafts every queued reply in one pass), so
            // it takes no recipient id: it writes the sentinel the runner checks on its heartbeat.
            onCancelReplyDraft: { ReplyClassifyService.requestCancel() },
            onCorrectClassification: { d in
                ProspectMutations.correctClassification(item, discipline: d, prospects: prospects, context: context, feedback: feedback)
            },
            onRename: { name in ProspectMutations.renameGroup(item, to: name, prospects: prospects, context: context, feedback: feedback) },
            onResetGroupName: { ProspectMutations.resetGroupName(item, prospects: prospects, context: context, feedback: feedback) },
            // #2267: mark it either way, so the request survives a run that dies before reaching this
            // show, and only THEN hand it to the caller to confirm and start. Marking first is what makes
            // the card show "researching" rather than snapping back to an unpressed control.
            onRequestRecheck: {
                ProspectMutations.requestReachabilityRecheck(item, prospects: prospects,
                                                             context: context, feedback: feedback)
                onRecheckNow?(item)
            },
            prepRunning: prepRunning,
            probeRunning: probeRunning,
            onConfirmBooking: { ProspectMutations.confirmBooking(item, prospects: prospects, context: context, feedback: feedback) },
            onDismissBookingSuggestion: { ProspectMutations.dismissBookingSuggestion(item, prospects: prospects, context: context, feedback: feedback) },
            onRejectBooking: { ProspectMutations.rejectBooking(item, prospects: prospects, context: context, feedback: feedback) },
            onDismissAlreadyCoveredFlag: { ProspectMutations.dismissAlreadyCoveredFlag(item, prospects: prospects, context: context, feedback: feedback) },
            onClearConflict: { ProspectMutations.clearConflict(item, prospects: prospects, context: context, feedback: feedback) },
            onSetOrgDoNotContact: { on in ProspectMutations.setOrgDoNotContact(item, on, prospects: prospects, context: context, feedback: feedback) },
            onConfirmPerformerMatch: { ProspectMutations.confirmPerformerMatch(item, prospects: prospects, context: context, feedback: feedback) },
            onDismissPerformerMatch: { ProspectMutations.dismissPerformerMatch(item, prospects: prospects, context: context, feedback: feedback) },
            onRestore: onRestore,
            gmailConnected: gmailConnected,
            outboundSendSince: outboundSendSince,
            replySendSince: replySendSince,
            highlightedRecipientId: highlightedRecipientId,
            showingTooFar: showingTooFar,
            userExcludedTowns: userExcludedTowns,
            allowedSeedTowns: allowedSeedTowns,
            onExcludeTown: { ProspectMutations.excludeTown(item, context: context, feedback: feedback) },
            onCorrectProducer: { standing in
                ProspectMutations.correctProducer(item, to: standing, context: context, feedback: feedback)
            }
        )
        // #236: tag each row with its key so a deep link can scroll to it, and highlight the target.
        let highlighted = highlightedKey == item.id
        let framed = row
            .padding(highlighted ? OVSpacing.sm : 0)
            .background(highlighted ? OVColor.gold.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .id(item.id)
        // #244: a sent draft Dan hand edited is a voice learning candidate. Let him opt a poor
        // example out (or back in) from a right click, so the loop never learns from a rushed send.
        //
        // #1773: the same two branches as before, but expressed through @ViewBuilder rather than by
        // wrapping each side in a type-erasing box. Erasure hides a card's real type from SwiftUI, and
        // type is what SwiftUI uses to decide whether a subtree can be updated in place or has to be
        // thrown away and rebuilt; inside a lazy list of tall cards that turned every render pass into
        // a teardown and rebuild of every visible card.
        //
        // Deliberately NOT one always-attached menu with conditional CONTENTS, which would be tidier
        // still: whether macOS draws an empty right-click menu for a card with no items is not
        // something any test here can answer, and getting it wrong would put a blank menu on every
        // untriaged card. This shape keeps the behaviour provably identical to what shipped before.
        if item.voiceLearningCandidate {
            framed.contextMenu {
                Button(item.excludedFromVoiceLearning ? "Learn from this email again"
                                                      : "Don't learn from this email") {
                    ProspectMutations.toggleVoiceLearning(item, prospects: prospects, context: context, feedback: feedback)
                }
            }
        } else {
            framed
        }
    }
}
