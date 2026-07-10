import Foundation
import SwiftData
import AppKit

// Every SwiftData mutation a queue row can trigger, moved out of QueueView so the same row
// component (Mark menu, Keep/Dismiss, booking confirm, and so on) behaves identically wherever
// it is shown: originally only the main Queue, now also the Archive lookup. Each function takes
// the full prospects array to find its target by natural key, the same way QueueView's private
// methods always did; nothing here changes existing behavior, it only relocates it.
@MainActor
enum ProspectMutations {
    static func toggleVoiceLearning(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.excludedFromVoiceLearning.toggle()
        if context.saveOrWarn(org: item.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.voiceLearning(excluded: model.excludedFromVoiceLearning, org: item.groupName))
        }
    }

    // Dan marked an auto-detected Gmail reply as not real (#219): revert it and remember that
    // reply so it does not re-flag, while a genuinely new reply still will.
    static func dismissReply(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.dismissAutoReply(now: Date())
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // Dan hand marks one contact's outcome from the conversation surface (attribution only for
    // Booked, never sets the lead booking). Stamps the manual source so detection will not overwrite it.
    static func markContact(_ item: QueueItem, _ recipientId: String, _ resolution: RecipientResolution?, _ bounced: Bool,
                            prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.markOutcomeManually(resolution: resolution, bounced: bounced) }
        model.resumePausedRecipients()
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // Dan manually adds a contact by hand (#399): runs the exact-duplicate/org/venue check first,
    // then creates a fresh Recipient, resumes one pursuit had stopped on, or is blocked if the
    // email already belongs to an active or settled contact. The venue/org flags never block; they
    // only ride along in the confirmation banner.
    static func addRecipientManually(_ item: QueueItem, email: String, name: String?,
                                     prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = ManualRecipientCheck.evaluate(email: trimmedEmail, existingRecipients: model.recipients,
                                                    venue: model.venue)

        switch result.action {
        case .blocked:
            feedback.acknowledge(ActionAck.recipientAlreadyExists(name: trimmedName, org: model.groupName))
            return
        case .resume(let existingId):
            model.updateRecipient(id: existingId) { r in
                r.sendState = (r.sentAt != nil) ? .sent : .pending
                r.suppressionReasonRaw = nil
                r.resolutionRaw = nil
                r.outcomeSourceRaw = nil
            }
        case .create:
            let canonical = ReplyDetection.email(from: trimmedEmail)
            model.addRecipient(Recipient(id: canonical, email: trimmedEmail,
                                         name: (trimmedName?.isEmpty == false) ? trimmedName : nil,
                                         provenance: .manual))
        }

        guard context.saveOrWarn(org: model.groupName, feedback: feedback) else { return }
        switch result.action {
        case .resume:
            feedback.acknowledge(ActionAck.recipientResumed(name: trimmedName, org: model.groupName))
        default:
            feedback.acknowledge(ActionAck.recipientAdded(name: trimmedName, org: model.groupName,
                                                           totalCount: model.recipients.count,
                                                           warnings: warningLines(for: result)))
        }
    }

    private static func warningLines(for result: ManualRecipientCheck.Result) -> [String] {
        var lines: [String] = []
        if result.sharesOrgWith != nil {
            lines.append("Heads up: shares a domain with another contact already on this show.")
        }
        if result.looksLikeVenue {
            lines.append("Heads up: looks like the venue's own domain.")
        }
        return lines
    }

    // Dan removes a recipient by hand (#399): Prospect.removeOrSuppressRecipient decides delete
    // versus stop-pursuing by that recipient's current send state.
    static func removeRecipientManually(_ item: QueueItem, _ recipientId: String, _ name: String?,
                                        prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.removeOrSuppressRecipient(id: recipientId)
        if context.saveOrWarn(org: model.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.recipientRemoved(name: name, org: model.groupName))
        }
    }

    static func dismissContactReply(_ item: QueueItem, _ recipientId: String,
                                    prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.dismissAutoReply() }
        model.resumePausedRecipients()
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // Dan marked an auto-detected bounce as wrong (#398): revert it and remember that bounce
    // message so it does not re-flag, while a genuinely new bounce still will.
    static func dismissContactBounce(_ item: QueueItem, _ recipientId: String,
                                     prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.dismissAutoBounce() }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #388: Dan judged a specific "looks like the venue" heuristic guess to be wrong for this one
    // contact, unblocking it from sending.
    static func dismissVenueMatch(_ item: QueueItem, _ recipientId: String,
                                  prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.looksLikeVenueDismissed = true }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #722: same shape as dismissVenueMatch above, for a suspected press/media contact.
    static func dismissPressContactMatch(_ item: QueueItem, _ recipientId: String,
                                         prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.looksLikePressContactDismissed = true }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func draftReply(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.replyDraftRequestedAt = Date() }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
        _ = try? ReplyClassifyService.startClassify(from: context, now: Date())
    }

    static func editReplyDraft(_ item: QueueItem, _ recipientId: String, _ body: String,
                               prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.applyReplyDraftEdit(body) }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func copyReply(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let recipient = model.recipients.first(where: { $0.id == recipientId }),
              let body = recipient.replyDraftBody, !body.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        model.updateRecipient(id: recipientId) { $0.recordRepliedInGmail(now: Date()) }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func setStatus(_ item: QueueItem, _ status: ReviewStatus, _ reason: DismissReason?,
                          prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.status = status
        model.dismissReasonRaw = reason?.rawValue
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func saveDraft(_ item: QueueItem, _ subject: String, _ body: String,
                         prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.applyEdit(subject: subject, body: body)
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func markConfidenceReviewed(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.confidenceReviewedByDan = true
        if context.saveOrWarn(org: item.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.confidenceConfirmed(org: item.groupName))
        }
    }

    static func correctClassification(_ item: QueueItem, discipline: Discipline?, production: Production?,
                                      prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        ClassificationOverride.correct(model, discipline: discipline, production: production, now: Date())
        if context.saveOrWarn(org: item.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.classificationCorrected(org: item.groupName))
        }
    }

    // #652: Dan sets ONE contact's conversation state by hand from the per-contact review controls.
    // Mirrors markContact's exact pattern: setting a state is Dan actively engaging with this contact,
    // the same signal that already resumes any sibling recipient a reply had auto-paused.
    static func setRecipientConversationState(_ item: QueueItem, _ recipientId: String, _ state: ConversationState,
                                              prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.setConversationState(state, now: Date()) }
        model.resumePausedRecipients()
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // Dan accepts THIS contact's AI-suggested state: it becomes his (manual) and that contact's
    // reminder clock restarts from now.
    static func confirmRecipientConversationState(_ item: QueueItem, _ recipientId: String,
                                                  prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.confirmConversationState(now: Date()) }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // "Remind me later" for ONE contact: steps just that contact's reminder forward, without sending.
    static func remindRecipientLater(_ item: QueueItem, _ recipientId: String,
                                     prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.remindLater(now: Date()) }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func confirmBooking(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.outcome = .booked
        model.outcomeSourceRaw = OutcomeSource.manual.rawValue
        model.outcomeAt = Date()
        model.bookingSuggested = false
        model.suppressUntriedRecipients(reason: .bookedElsewhere)
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func dismissBookingSuggestion(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.bookingSuggested = false
        model.bookingSuggestionDismissed = true
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #611: Dan judged the "already has its own photographer" flag a false positive. Keeps the
    // original note (an audit trail of what Prep found) and tracks the dismissal separately,
    // mirroring dismissBookingSuggestion above.
    static func dismissAlreadyCoveredFlag(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.alreadyCoveredDismissed = true
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #718: Dan's deliberate, confirmed override of the #407 salutation-review send block, for
    // when SalutationStrip's heuristic flagged text he's confident is fine to send as-is. Records
    // the EXACT current draftBody rather than a bare boolean (see
    // Prospect.isSalutationReviewOverridden), so a later edit to different text silently
    // invalidates this without any extra reset logic needed here or in the migration.
    static func overrideSalutationReview(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.draftSalutationReviewOverriddenBody = model.draftBody
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func rejectBooking(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.rejectAutoBooking(bookingId: model.autoBookedFromBookingId, now: Date())
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func setLostReason(_ item: QueueItem, _ reason: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.lostReason = QueueModel.normalizedLostReason(reason)
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // The default a caller gets when it doesn't inject its own; a test injects a fake instead so
    // performSend/sendReply/sendFollowUp/sendConversationNudge are testable without hitting the
    // real network or the GmailAuthManager.shared singleton (#468, SUP-006).
    private static func liveSender() -> MailSender { GmailSender(fromEmail: "dan@danwrightphotography.com") }

    // The confirm dialog itself (step 1 of a send) stays in each screen: it only needs
    // SendConfirmation(prospect:), a pure struct init, not worth extracting. This is step 2, the
    // actual send. markSending/clearSending let each screen show its own live "Sending..." state;
    // onNeedsReconnect lets each screen show its own reconnect prompt.
    static func performSend(_ naturalKey: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback,
                           sender: MailSender = liveSender(),
                           markSending: @escaping (String) -> Void, clearSending: @escaping (String) -> Void,
                           onNeedsReconnect: @escaping () -> Void) {
        guard let model = prospects.first(where: { $0.naturalKey == naturalKey }) else { return }
        markSending(naturalKey)
        Task {
            let sent = await SendService.sendOne(model, now: Date(), sender: sender)
            context.saveOrWarnSendNotConfirmed(org: model.groupName, feedback: feedback)
            clearSending(naturalKey)
            if !sent && !GmailAuthManager.shared.isConnected { onNeedsReconnect() }
        }
    }

    static func sendReply(_ item: QueueItem, _ recipientId: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback,
                          sender: MailSender = liveSender(),
                          markSending: @escaping (String) -> Void, clearSending: @escaping (String) -> Void,
                          onNeedsReconnect: @escaping () -> Void) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let recipient = model.recipients.first(where: { $0.id == recipientId }) else { return }
        markSending(recipientId)
        Task {
            let sent = await SendService.sendReplyDraft(recipient, of: model, now: Date(), sender: sender)
            context.saveOrWarnSendNotConfirmed(org: item.groupName, feedback: feedback)
            clearSending(recipientId)
            if !sent && !GmailAuthManager.shared.isConnected { onNeedsReconnect() }
        }
    }

    // #468 (SUP-006): mirrors performSend/sendReply's markSending/clearSending shape so
    // FollowUpsView's nudge and closing-note sends get the same in-flight feedback (a LiveRunLabel,
    // button disabled while sending) instead of firing a bare Task with the button left clickable.
    static func sendFollowUp(_ naturalKey: String, _ recipientId: String, prospects: [Prospect],
                             context: ModelContext, feedback: ActionFeedback,
                             sender: MailSender = liveSender(),
                             markSending: @escaping (String) -> Void, clearSending: @escaping (String) -> Void) {
        guard let model = prospects.first(where: { $0.naturalKey == naturalKey }),
              let recipient = model.recipients.first(where: { $0.id == recipientId }) else { return }
        let org = model.groupName
        markSending(recipientId)
        Task {
            let sent = await SendService.sendFollowUp(recipient, of: model, now: Date(), sender: sender)
            let saved = context.saveOrWarnSendNotConfirmed(org: org, feedback: feedback)
            clearSending(recipientId)
            // #285: the send fires async in a sheet; acknowledge it ran, success or failure.
            if saved {
                feedback.acknowledge(ActionAck.followUpSent(org: org, success: sent), tone: sent ? .info : .warning)
            }
        }
    }

    static func sendConversationNudge(_ naturalKey: String, _ recipientId: String, isClosing: Bool,
                                      prospects: [Prospect], context: ModelContext, feedback: ActionFeedback,
                                      sender: MailSender = liveSender(),
                                      markSending: @escaping (String) -> Void, clearSending: @escaping (String) -> Void) {
        guard let model = prospects.first(where: { $0.naturalKey == naturalKey }),
              let recipient = model.recipients.first(where: { $0.id == recipientId }) else { return }
        let org = model.groupName
        let kind: ConversationReminder.Kind = isClosing ? .closing : .active(recipient.conversationState ?? .wantsToBook)
        markSending(recipientId)
        Task {
            let sent = await SendService.sendConversationNudge(recipient, of: model, kind: kind, now: Date(), sender: sender)
            let saved = context.saveOrWarnSendNotConfirmed(org: org, feedback: feedback)
            clearSending(recipientId)
            // #285: same async-in-a-sheet acknowledgment, with closing-note vs nudge wording.
            if saved {
                feedback.acknowledge(ActionAck.conversationNudge(org: org, closing: isClosing, success: sent),
                                     tone: sent ? .info : .warning)
            }
        }
    }
}

// The one email awaiting Dan's explicit confirm before it sends (#49), shared by QueueView and
// ArchiveView so both present the identical confirm alert.
struct PendingSend: Identifiable {
    let id: String   // prospect naturalKey
    let confirmation: SendConfirmation
}
