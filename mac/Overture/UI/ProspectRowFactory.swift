import SwiftUI
import SwiftData

// The one place that builds a fully wired ProspectRowView, so QueueView and ArchiveView
// share this construction instead of each repeating the same ~20 line callback list. onSend and
// onSendReply stay as caller supplied closures (not routed through ProspectMutations here) because
// they trigger a screen local confirm dialog and live "Sending..." state; everything else needs
// nothing screen specific and is wired directly to ProspectMutations.
@MainActor
enum ProspectRowFactory {
    static func row(_ item: QueueItem, today: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback,
                    highlightedKey: String?, highlightedRecipientId: String? = nil, outboundSendSince: Date?,
                    replySendSince: @escaping (String) -> Date?,
                    onSend: @escaping () -> Void, onSendReply: @escaping (String) -> Void,
                    onRestore: (() -> Void)? = nil) -> AnyView {
        let model = prospects.first(where: { $0.naturalKey == item.id })
        let row = ProspectRowView(
            item: item,
            today: today,
            onKeep: { ProspectMutations.setStatus(item, .queued, nil, prospects: prospects, context: context, feedback: feedback) },
            onDismiss: { reason in ProspectMutations.setStatus(item, .dismissed, reason, prospects: prospects, context: context, feedback: feedback) },
            onApprove: { ProspectMutations.setStatus(item, .approved, nil, prospects: prospects, context: context, feedback: feedback) },
            onUnapprove: { ProspectMutations.setStatus(item, .drafted, nil, prospects: prospects, context: context, feedback: feedback) },
            onSkipDraft: { ProspectMutations.setStatus(item, .dismissed, .notInterested, prospects: prospects, context: context, feedback: feedback) },
            onReprep: { mode in ProspectMutations.reprep(item, mode: mode, prospects: prospects, context: context, feedback: feedback) },
            onSaveDraft: { subject, body in ProspectMutations.saveDraft(item, subject, body, prospects: prospects, context: context, feedback: feedback) },
            onSetLostReason: { reason in ProspectMutations.setLostReason(item, reason, prospects: prospects, context: context, feedback: feedback) },
            onSend: onSend,
            onOverrideSalutationReview: { ProspectMutations.overrideSalutationReview(item, prospects: prospects, context: context, feedback: feedback) },
            onDismissReply: { ProspectMutations.dismissReply(item, prospects: prospects, context: context, feedback: feedback) },
            onMarkContact: { rid, resolution, bounced in
                ProspectMutations.markContact(item, rid, resolution, bounced, prospects: prospects, context: context, feedback: feedback)
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
            onDismissContactReply: { rid in ProspectMutations.dismissContactReply(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDismissContactBounce: { rid in ProspectMutations.dismissContactBounce(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDismissVenueMatch: { rid in ProspectMutations.dismissVenueMatch(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDismissPressContactMatch: { rid in ProspectMutations.dismissPressContactMatch(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDismissDuplicateContactMatch: { rid in ProspectMutations.dismissDuplicateContactMatch(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onDraftReply: { rid in ProspectMutations.draftReply(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onSendReply: onSendReply,
            onCopyReply: { rid in ProspectMutations.copyReply(item, rid, prospects: prospects, context: context, feedback: feedback) },
            onEditReplyDraft: { rid, body in ProspectMutations.editReplyDraft(item, rid, body, prospects: prospects, context: context, feedback: feedback) },
            onMarkConfidenceReviewed: { ProspectMutations.markConfidenceReviewed(item, prospects: prospects, context: context, feedback: feedback) },
            onCorrectClassification: { d, p in
                ProspectMutations.correctClassification(item, discipline: d, production: p, prospects: prospects, context: context, feedback: feedback)
            },
            onConfirmBooking: { ProspectMutations.confirmBooking(item, prospects: prospects, context: context, feedback: feedback) },
            onDismissBookingSuggestion: { ProspectMutations.dismissBookingSuggestion(item, prospects: prospects, context: context, feedback: feedback) },
            onRejectBooking: { ProspectMutations.rejectBooking(item, prospects: prospects, context: context, feedback: feedback) },
            onDismissAlreadyCoveredFlag: { ProspectMutations.dismissAlreadyCoveredFlag(item, prospects: prospects, context: context, feedback: feedback) },
            onConfirmPerformerMatch: { ProspectMutations.confirmPerformerMatch(item, prospects: prospects, context: context, feedback: feedback) },
            onDismissPerformerMatch: { ProspectMutations.dismissPerformerMatch(item, prospects: prospects, context: context, feedback: feedback) },
            onRestore: onRestore,
            gmailConnected: GmailAuthManager.shared.isConnected,
            outboundSendSince: outboundSendSince,
            replySendSince: replySendSince,
            highlightedRecipientId: highlightedRecipientId
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
        if let model, model.sentAt != nil, model.originalDraftBody != nil {
            return AnyView(framed.contextMenu {
                Button(model.excludedFromVoiceLearning ? "Learn from this email again"
                                                       : "Don't learn from this email") {
                    ProspectMutations.toggleVoiceLearning(item, prospects: prospects, context: context, feedback: feedback)
                }
            })
        }
        return AnyView(framed)
    }
}
