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

    // #726: Dan judged a specific "looks like a duplicate outreach" heuristic guess to be wrong
    // for this one contact, unblocking it from sending.
    static func dismissDuplicateContactMatch(_ item: QueueItem, _ recipientId: String,
                                             prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.updateRecipient(id: recipientId) { $0.looksLikeDuplicateContactDismissed = true }
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

    // #924: dismiss for a reason, then, when that reason is about the calendar, OFFER to capture the date
    // as a day off. Dan telling Overture "not this day" is the most natural moment to block it, instead of
    // making him say it twice. The offer is a CENTERED picker (via the injected request RootView presents),
    // pre-filled with the show's date or run, not a missable banner: dismissing for a date reason almost
    // always means he'll block it, so a modal he acts on is right. It is still an offer, never automatic:
    // nothing is blocked until he confirms in the picker (or he closes it with Not now).
    static func dismissForReason(_ item: QueueItem, _ reason: DismissReason,
                                 prospects: [Prospect], context: ModelContext,
                                 feedback: ActionFeedback, offer: DayOffOfferRequest) {
        setStatus(item, .dismissed, reason, prospects: prospects, context: context, feedback: feedback)
        guard let o = DayOffOffer.offer(reason: reason, performanceDate: item.performanceDate,
                                        runEndDate: item.runEndDate,
                                        alreadyBlocked: item.hasUnclearedConflict) else { return }
        offer.request(key: item.id, org: item.groupName, start: o.start, end: o.end)
    }

    // #924: add the day(s) off and confirm it, reversibly. Shared by the single-tap dismiss offer and the
    // picker sheet's confirm, so both go through one implementation. Reuses DayOffEditing.add, which runs
    // the conflict sweep, so every other show on those nights is flagged in the same action. A refused
    // range (backwards, too long) says why instead of failing silently.
    @discardableResult
    static func blockDaysOff(start: String, end: String, note: String? = nil,
                             context: ModelContext, feedback: ActionFeedback) -> Bool {
        let range = QueueModel.runDateLabel(start: start, end: end)
        let result = DayOffEditing.add(start: start, end: end, note: note, into: context)
        guard result == .added else {
            feedback.acknowledge(DayOffEditing.message(for: result) ?? "Couldn't block \(range)", tone: .warning)
            return false
        }
        feedback.acknowledge(ActionAck.dayOffBlocked(range: range),
                             action: .init(label: "Undo") {
                                 if let row = DayOffEditing.rows(in: context)
                                     .first(where: { $0.startDate == start && $0.endDate == end }) {
                                     DayOffEditing.remove(row, in: context)
                                 }
                             })
        return true
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

    // #367: queue this one prospect for the next Prep run even though it already has a draft.
    static func reprep(_ item: QueueItem, mode: ReprepMode, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        let draftGranted = ReprepRequest.apply(mode, to: model)
        if context.saveOrWarn(org: item.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.reprepQueued(mode: mode, draftGranted: draftGranted, org: item.groupName))
        }
    }

    // #367/#733: which prospects the bulk re-prep action would actually touch: already has a
    // draft, not yet contacted or dismissed, no re-prep already pending, and not served within the
    // cooldown window. Shared by RootView's menu-disabled check and bulkReprep itself, so what the
    // menu shows enabled always agrees with what a tap would actually queue.
    static func bulkReprepEligible(_ prospects: [Prospect], now: Date) -> [Prospect] {
        prospects.filter {
            $0.hasDraft && ($0.status == .drafted || $0.status == .approved)
                && !$0.reprepDraftRequested && !$0.reprepContactsRequested
                && !ReprepRequest.isInCooldown(lastServedAt: $0.reprepLastServedAt, now: now)
        }
    }

    // #367: apply the requested mode to every eligible prospect in one go; a queued-undrafted
    // prospect is already covered by the normal Prep flow and is skipped rather than
    // double-flagged. #733: also silently skips anything already pending or re-prepped within the
    // cooldown window, reporting the skip in the confirmation rather than a per-prospect dialog.
    static func bulkReprep(_ mode: ReprepMode, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback, now: Date = Date()) {
        let baseEligible = prospects.filter { $0.hasDraft && ($0.status == .drafted || $0.status == .approved) }
        let eligible = bulkReprepEligible(prospects, now: now)
        guard !eligible.isEmpty else {
            if baseEligible.isEmpty {
                feedback.acknowledge(ActionAck.bulkReprepNothingEligible, tone: .warning)
            } else {
                feedback.acknowledge(ActionAck.bulkReprepAllSkipped(count: baseEligible.count), tone: .warning)
            }
            return
        }
        let skippedCount = baseEligible.count - eligible.count
        var draftGrantedCount = 0
        for p in eligible {
            if ReprepRequest.apply(mode, to: p) { draftGrantedCount += 1 }
        }
        if context.saveOrWarn(org: "the queue", feedback: feedback) {
            feedback.acknowledge(ActionAck.bulkReprepQueued(mode: mode, total: eligible.count,
                                                            draftGrantedCount: draftGrantedCount,
                                                            skippedCount: skippedCount))
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
    // #901: "I can shoot this anyway." Dan overrules a date clash, which unlocks drafting and sending a
    // show on a night Overture believes he is booked or away.
    //
    // Offered with an Undo, on the #845 principle: this is the action that lets an email go out for a
    // night he cannot work, so a mis-click has to be reversible from the banner it happened in, rather
    // than needing him to find the row again and work out how to put the flag back.
    static func clearConflict(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              model.hasUnclearedConflict else { return }   // nothing to clear, and nothing to pre-approve
        model.clearConflict()
        if context.saveOrWarn(org: item.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.conflictCleared(org: item.groupName),
                                 action: ActionFeedback.Action(label: "Undo") {
                                     model.restoreConflict()
                                     context.saveOrWarn(org: item.groupName, feedback: feedback)
                                 })
        }
    }

    static func dismissAlreadyCoveredFlag(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.alreadyCoveredDismissed = true
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #769: Dan marks (or releases) the whole ORG, not just this show. The real work lives in
    // OrgDoNotContact, which needs every prospect so it can reach the org's OTHER shows: protecting
    // the next scout while leaving three of their shows drafted and ready to send in the queue would
    // be a feature that looks like it works and still sends the email.
    static func setOrgDoNotContact(_ item: QueueItem, _ on: Bool, prospects: [Prospect],
                                   context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        // #802: the refusal now also takes the org off the WATCHLIST, or a standing watchlist would
        // re-check their calendar every run forever and keep putting their shows in front of Dan.
        // Nothing would send, but that is not what "we'll leave you alone" means. The sources are
        // fetched here because this is where a ModelContext exists; OrgDoNotContact stays pure.
        let sources = (try? context.fetch(FetchDescriptor<WatchedSource>())) ?? []
        if on {
            OrgDoNotContact.mark(orgOf: model, in: prospects, sources: sources)
        } else {
            OrgDoNotContact.unmark(orgOf: model, in: prospects, sources: sources)
        }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #753/#752: Dan's verdict on a performer match. The real work lives on the model, which owns the
    // snapshot revert and the reviewed flag, so these stay thin and there is exactly one implementation
    // of each.
    static func confirmPerformerMatch(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.confirmPerformerMatch()
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    static func dismissPerformerMatch(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.dismissPerformerMatch()
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

    // #789: Dan's deliberate, confirmed override of the draft-lint send block, for a finding he has
    // read and judged fine (or a link he knows is right). Records the EXACT outgoing text of each
    // blocked recipient rather than a bare boolean (see Recipient.isLintOverridden), so a later edit
    // to different text silently reinstates the block with no extra reset logic. Only recipients that
    // are actually blocked and still pending are touched: a clean recipient gains no stale override,
    // and one already sent is left alone.
    static func overrideDraftLint(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        for r in model.recipients where r.sendState == .pending && r.isBlockedByDraftLint {
            r.lintOverriddenBody = r.effectiveBody
        }
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
    // #360: the sending identity comes from SendIdentity (the same value the confirmation's From line
    // reads), so the address Dan is shown before a send can never drift from the one it goes out as.
    private static func liveSender() -> MailSender {
        GmailSender(fromName: SendIdentity.danWright.name, fromEmail: SendIdentity.danWright.email)
    }

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
