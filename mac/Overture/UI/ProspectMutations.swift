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

    // #2261: Dan asks for a show's frozen reachability answer to be researched again. A flag, never a
    // clearing of the verdict: the old answer stays on the card until a new one lands on top of it, so a
    // re-check that then fails leaves him no worse off than before he pressed (L5).
    static func requestReachabilityRecheck(_ item: QueueItem, prospects: [Prospect],
                                           context: ModelContext, feedback: ActionFeedback,
                                           now: Date = Date()) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        // Idempotent. Pressing twice must not move the request's timestamp, which is what the row reads to
        // decide it has already been acknowledged.
        guard model.reachabilityRecheckRequestedAt == nil else { return }
        model.reachabilityRecheckRequestedAt = now
        // No banner on success: the row swaps in place to say what will happen, which is the
        // acknowledgement. saveOrWarn still surfaces a FAILED write, which is what a banner is for.
        context.saveOrWarn(org: item.groupName, feedback: feedback)
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

    // #2395: the ONE way an ending reaches a show, whichever menu Dan picked it from: the dismiss menu at
    // triage, the close-out menu on the reached-out row, the full card's "Mark…", or Follow-ups' "Not this
    // one". Four controls, one write, so they cannot each record the same decision slightly differently,
    // which is what left "Declined" and "Closed (not now)" as two names for one stored value (#2388).
    //
    // It REFUSES an ending the show cannot possibly have reached, and that refusal is the same promise the
    // menus make, kept one layer down. A menu offering only the possible half is a fact about a screen; a
    // caller can still pass anything, and an impossible ending recorded once is indistinguishable
    // afterwards from one Dan chose. It says so rather than failing quietly, because a control that does
    // nothing visible reads as broken and gets pressed again.
    //
    // The save is checked, so nothing ever reads as closed out on the strength of a write that did not
    // land (L12).
    @discardableResult
    static func recordOutcome(_ item: QueueItem, _ outcome: ShowOutcome,
                              prospects: [Prospect], context: ModelContext,
                              feedback: ActionFeedback) -> Bool {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return false }
        guard ShowOutcome.menu(wasPitched: model.wasPitched).contains(outcome) else {
            feedback.acknowledge(ShowOutcome.refusedLine(outcome, org: item.groupName,
                                                         wasPitched: model.wasPitched),
                                 tone: .warning)
            return false
        }

        if ShowOutcome.neverPitched.contains(outcome) {
            // The never-pitched half. A show that ended without being sent to LEAVES the queue, which is
            // what dismissing means, and its exit is dated by the model's own pair so the drop-off can be
            // placed in a year (#16).
            model.markDismissed(reason: outcome)
        } else {
            // A pitch that ended is not a dismissal. It went out and it now carries an ending, which is
            // what takes it off the reached-out stage; marking it dismissed would file a real pitch among
            // the shows Dan never sent to.
            model.showOutcome = outcome
            // A booking Dan recorded is HIS call, and the show has to say so or the next Downbeat
            // reconcile claims it and silently moves it from the manual half of the booking split to the
            // automatic one (#2226).
            if outcome == .booked { model.markOutcomeManually(.booked, now: Date()) }
            // #2396: nothing is written onto the contacts. The show's own field is what takes the row off
            // the stage and what every reader of its status goes to, so a copy next to each contact would be
            // a second home for one fact (L83). Contacts keep only routing facts: this address bounced, this
            // person replied, use this one next time.
            model.resumePausedRecipients()
        }
        guard context.saveOrWarn(org: item.groupName, feedback: feedback) else { return false }
        feedback.acknowledge(ShowOutcome.recordedLine(outcome, org: item.groupName))
        return true
    }

    // #2395: Dan takes an ending back. The replacement for the "In conversation" item the full card's
    // "Mark…" menu used to carry, which was never an ending at all: what it actually did was clear one, and
    // that capability has to survive the menu becoming a list of endings. Without it a mis-pressed
    // close-out would be unreachable from the card Dan is looking at.
    //
    // Clears the contact-level record too, for the same reason `resumeStandDown` does: leaving the contacts
    // closed would keep the show reading as closed on a decision he just reversed.
    @discardableResult
    static func reopenOutcome(_ item: QueueItem, prospects: [Prospect], context: ModelContext,
                              feedback: ActionFeedback) -> Bool {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return false }
        guard let had = model.showOutcome else { return false }
        model.showOutcome = nil
        for r in model.recipients where r.resolution != nil {
            r.markOutcomeManually(resolution: nil, bounced: r.bounced)
        }
        guard context.saveOrWarn(org: item.groupName, feedback: feedback) else { return false }
        feedback.acknowledge(ShowOutcome.reopenedLine(had, org: item.groupName))
        return true
    }

    // Dan manually adds a contact by hand (#399): runs the exact-duplicate/org/venue check first,
    // then creates a fresh Recipient, resumes one pursuit had stopped on, or is blocked if the
    // email already belongs to an active or settled contact. The venue/org flags never block; they
    // only ride along in the confirmation banner.
    static func addRecipientManually(_ item: QueueItem, email: String, name: String?,
                                     prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }

        // #2023: this control adds ONE person and its banner names one, so the field is READ rather than
        // checked for an "@". Before this, "a@x.org, b@y.org" became a single contact whose identity was
        // that entire string, which sends and reports success while no reply from either person can ever
        // be matched back to it. Gated on the same `single` the Add button asks, so the two agree.
        let trimmedEmail: String
        switch EmailAddressList.parse(email) {
        case .empty:
            feedback.acknowledge(ActionAck.contactNeedsAddress, tone: .warning)
            return
        case .invalid(let piece):
            // A blank piece is a stray separator, not a second person: saying "one at a time" to somebody
            // who typed ",,olga@x.org" would name a mistake he did not make.
            feedback.acknowledge(piece.isEmpty ? ActionAck.contactBlankAddress
                                               : ActionAck.contactBadAddress(piece), tone: .warning)
            return
        case .addresses(let addresses) where addresses.count > 1:
            feedback.acknowledge(ActionAck.contactOneAtATime, tone: .warning)
            return
        case .addresses(let addresses):
            trimmedEmail = addresses[0]
        }

        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        // #2392: typing an address back in is the reversal of striking it, and is deliberately the only
        // one, matching Dan's no-undo rule for removal at review (#2155: "if they want to add it back
        // they can"). Cleared BEFORE the contact is created, so a refusal can never be left standing
        // behind a contact that is now on the card and quietly drop it at the next import.
        ContactRefusal.allow(email: trimmedEmail, showKey: model.naturalKey,
                             orgKey: model.presenter.flatMap { OrgKey.stored(for: $0) }, in: context)
        let result = applyManualRecipient(email: trimmedEmail, name: trimmedName, to: model)

        if case .blocked = result.action {
            feedback.acknowledge(ActionAck.recipientAlreadyExists(name: trimmedName, org: model.groupName))
            return
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

    // The recipient half of adding a contact by hand, WITHOUT the save or the banner, so the two paths
    // that do it (the Add-contact control above and #2007's manual prep below) share one implementation
    // instead of each deciding for itself what a typed address means. Mutates nothing on `.blocked`: that
    // address already belongs to a live contact on this show, and each caller decides what to say about it.
    @discardableResult
    private static func applyManualRecipient(email: String, name: String?,
                                             to model: Prospect) -> ManualRecipientCheck.Result {
        let result = ManualRecipientCheck.evaluate(email: email, existingRecipients: model.recipients,
                                                   venue: model.venue)
        switch result.action {
        case .blocked:
            break
        case .resume(let existingId):
            model.updateRecipient(id: existingId) { r in
                r.sendState = (r.sentAt != nil) ? .sent : .pending
                r.suppressionReasonRaw = nil
                r.resolutionRaw = nil
                r.outcomeSourceRaw = nil
            }
        case .create:
            model.addRecipient(Recipient(id: ReplyDetection.email(from: email), email: email,
                                         name: (name?.isEmpty == false) ? name : nil,
                                         provenance: .manual))
        }
        return result
    }

    // #2007: what the manual-prep editor already knows about who to send to, for one card.
    //
    // Here rather than in the row factory for two reasons. It has to find this card's prospect in the
    // store, and #1773's guard rightly refuses that spelling in the factory, which runs once per card per
    // render pass. And it reads the booking-history file, which is real disk work. Neither belongs on a
    // render path: the row calls this only when the editor is actually opened.
    static func manualPrepPrefill(_ item: QueueItem, prospects: [Prospect]) -> ManualPrepPrefill.Result {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else {
            // No prospect behind this card is not "nothing was found": it is a lookup that could not run,
            // and saying "checked past emails and the booking sheet" would be a claim about work that
            // never happened (L11). The history is the half that genuinely could not be consulted.
            return ManualPrepPrefill.Result(filled: nil, suggestions: [], emptyReason: .historyUnreadable)
        }
        let history = LocalHistory.importedWithHealth()
        return ManualPrepPrefill.build(for: model, amongst: prospects, history: history.records,
                                       historyUnreadable: history.unreadable)
    }

    // #2007: prep this show BY HAND. No Prep run, no model call, no spend: Dan names the address and
    // writes the email himself, and the show lands in `.drafted` exactly where a prepped one does.
    //
    // For the shows an AI draft helps least: an annual booking he has shot five years running, where the
    // email is one paragraph asking about this year's dates and the drafter's cold-pitch shape gets
    // rewritten anyway.
    static func prepManually(_ item: QueueItem, email: String, name: String?,
                             subject: String, body: String, sendsTogether: Bool = true,
                             prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }

        // #901's gate, and for the same reason it holds the AI path: a pitch for a night he cannot work
        // is the same wrong email whoever wrote it. Checked BEFORE anything is written, so a refusal
        // never leaves half a draft behind. The card offers "I can shoot this anyway" to clear it.
        guard !model.hasUnclearedConflict else {
            feedback.acknowledge(ActionAck.manualPrepBlockedByClash(org: model.groupName), tone: .warning)
            return
        }

        // The same rule the editor's Save button is gated on, so the two cannot disagree. #2023: this also
        // READS the address field, so a string that is not addresses is refused here, before a single
        // write, rather than becoming one contact whose identity is that whole string.
        if let refusal = ManualPrepEditing.refusal(email: email, subject: subject, body: body) {
            feedback.acknowledge(refusal, tone: .warning)
            return
        }
        guard case .addresses(let addresses) = EmailAddressList.parse(email) else { return }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)

        // One Recipient per person, each through the same path the Add-contact control uses, so a
        // `.blocked` result still means what it always did: that address is already a live contact on this
        // show, which is exactly who he meant to write to. Nothing is added for that one and the draft goes
        // ahead against the contact already there, while the people named beside it are still created.
        //
        // The name is only ever applied when he named ONE person, since a single typed name cannot belong
        // to several addresses.
        let trimmedName = (addresses.count == 1) ? name?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        for address in addresses {
            applyManualRecipient(email: address, name: trimmedName, to: model)
        }
        // #2034: the choice he made on the sheet, recorded with the draft it belongs to.
        model.sendsTogetherOverride = sendsTogether
        model.writeManualDraft(subject: subject.trimmingCharacters(in: .whitespacesAndNewlines),
                               body: trimmedBody)

        guard context.saveOrWarn(org: model.groupName, feedback: feedback) else { return }
        feedback.acknowledge(ActionAck.manualPrepSaved(org: model.groupName))
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
    //
    // #2392: and the removal is RECORDED, not merely performed. The delete branch above leaves a still
    // pending row indistinguishable from one never found, so the next prep run re-imports the same
    // address and the removal silently undoes itself. This is the one path both surfaces take (the
    // triage card and the draft-review panel), so a strike means the same thing wherever Dan makes it.
    static func removeRecipientManually(_ item: QueueItem, _ recipientId: String, _ name: String?,
                                        prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        if let email = model.recipients.first(where: { $0.id == recipientId })?.email, !email.isEmpty {
            // Scoped to this SHOW: a contact this show researched is a fact about this show, and refusing
            // it for the whole organisation would strike people it is not true of (L83).
            ContactRefusal.refuse(email: email, scope: .show(model.naturalKey), in: context)
        }
        model.removeOrSuppressRecipient(id: recipientId)
        if context.saveOrWarn(org: model.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.recipientRemoved(name: name, org: model.groupName))
        }
    }

    // #2392: Dan strikes an address the card INHERITED from the organisation ledger (#1598 Phase 5).
    //
    // A separate entry point from the one above because there is genuinely nothing to remove: the show
    // has no contacts of its own, so the address is printed from an answer owned elsewhere and there is
    // no Recipient row on this card at all. His call, 2026-08-09: striking one means "not for this
    // organisation", so it leaves every show that inherits it rather than only this one.
    static func removeInheritedAddress(_ item: QueueItem, email: String,
                                       prospects: [Prospect], context: ModelContext,
                                       feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        // No organisation to attach it to means the address cannot have been inherited in the first
        // place, so there is nothing this could truthfully record. Refuse rather than guess at a nearby
        // scope (L75): a strike written against the wrong key silently spares the address it names and
        // strikes somebody else's.
        guard let presenter = model.presenter, let orgKey = OrgKey.stored(for: presenter) else {
            feedback.acknowledge(ActionAck.inheritedAddressHasNoOrganisation, tone: .warning)
            return
        }
        ContactRefusal.refuse(email: email, scope: .organisation(orgKey), in: context)
        feedback.acknowledge(ActionAck.inheritedAddressRemoved(email: email, org: presenter))
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

    // #2129: draft THIS reply, not every reply waiting. Same run, scoped to one conversation, so the
    // button spends on the one Dan pressed it on and its Cancel abandons only that.
    static func draftOneReply(_ naturalKey: String, _ recipientId: String, prospects: [Prospect],
                              context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == naturalKey }) else { return }
        model.updateRecipient(id: recipientId) { $0.replyDraftRequestedAt = Date() }
        context.saveOrWarn(org: model.groupName, feedback: feedback)
        _ = try? ReplyClassifyService.startClassify(
            from: context, now: Date(),
            only: ReplyClassifyService.Target(naturalKey: naturalKey, recipientId: recipientId))
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
        // #2191: the same routine the in-app send runs, so answering by pasting into Gmail clears the
        // conversation exactly as answering in the app does.
        AnsweredReply.record(on: recipient, in: model, now: Date())
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #1630, step one of the copy-then-confirm control: put the whole pitch on the clipboard (greeting
    // included, via the same OutgoingPitch the send path composes with), open the act's form, and move
    // the row into the state that waits on his answer. It records NO outreach: nothing has been sent
    // yet, and claiming otherwise here is exactly the lie the confirm step exists to prevent.
    static func beginFormPitch(_ item: QueueItem, _ recipientId: String, _ formURL: String,
                               prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let recipient = model.recipients.first(where: { $0.id == recipientId }),
              let pitch = OutgoingPitch.text(for: recipient, of: model) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pitch, forType: .string)
        model.beginFormPitch(recipient, now: Date())
        guard context.saveOrWarn(org: item.groupName, feedback: feedback) else { return }
        if let url = URL(string: formURL), url.scheme != nil {
            NSWorkspace.shared.open(url)
        }
        feedback.acknowledge(ActionAck.formPitchCopied(org: item.groupName))
    }

    // Step two: he says he sent it. This is the moment the outreach becomes real.
    static func recordFormPitch(_ item: QueueItem, _ recipientId: String,
                                prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let recipient = model.recipients.first(where: { $0.id == recipientId }),
              model.recordFormOutreach(recipient, now: Date(), formURL: recipient.contactFormURL) else { return }
        guard context.saveOrWarn(org: item.groupName, feedback: feedback) else { return }
        feedback.acknowledge(ActionAck.formPitchRecorded(org: item.groupName))
    }

    // ...or he says he didn't, which puts the row back exactly where it was rather than leaving it in a
    // half state he has to come back to.
    static func cancelFormPitch(_ item: QueueItem, _ recipientId: String,
                                prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let recipient = model.recipients.first(where: { $0.id == recipientId }) else { return }
        // Covers both directions: backing out before recording, and undoing a record already made.
        if model.undoFormOutreach(recipient) == false {
            recipient.formOutreachStartedAt = nil
        }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #991: Dan refuses a town from a row ("never show me shows in this town"). It adds that row's town
    // to the stored exclude set, which the queue gate reads in union with the seed at queue time, so the
    // refusal re-decides every row at once and this show (and any future one there) drops out. Idempotent
    // (a town already excluded is a no-op), and reversible from the banner. The town comes from the item,
    // decided once in EventPlace.excludableTown, so this stays a thin wiring layer.
    static func excludeTown(_ item: QueueItem, context: ModelContext, feedback: ActionFeedback) {
        guard let town = item.excludableTown else { return }
        switch ExcludedTownEditing.exclude(town: town, into: context) {
        case .added:
            // #1238: blocking a town now REMOVES its shows, not just future ones. The refusal alone was a
            // view-time filter the stage views never applied (#1134), so the show stayed on screen. Dismiss
            // the matching shows (the base query hides dismissed everywhere) and persist. Undo reverses both
            // halves: un-block the town AND bring its shows back, or Undo would leave them stuck dismissed.
            ExcludedTownRetirement.run(in: context)
            // #1417: the one site the issue named. The warning from a failed save was posted and then
            // wiped by the success line below microseconds later, so a refusal that never reached disk
            // read as "Won't show you shows in Newark again" and came back on the next launch.
            guard context.saveOrWarn(org: town, feedback: feedback) else { return }
            let normalized = ExcludedTownEditing.normalize(town)
            feedback.acknowledge(ActionAck.townExcluded(town: town),
                                 action: .init(label: "Undo") {
                                     ExcludedTownEditing.remove(town: town, in: context)
                                     ExcludedTownRetirement.restore(town: normalized, in: context)
                                     context.saveOrWarn(org: town, feedback: feedback)
                                 })
        case .alreadyExcluded:
            feedback.acknowledge(ActionAck.townAlreadyExcluded(town: town))
        case .noTown:
            break   // nothing placeable to exclude; the action is not offered in this case anyway
        }
    }

    // #1719: Dan corrects a producer/house verdict from the row where he can see it is wrong. The gate
    // decides automatically from the store's own venue names, and both of its arms can miss: an
    // organisation that rents out the one room it runs looks like a travelled producer, and one that
    // produces its own work in a room named after it looks like the house.
    //
    // `to` is the standing he wants IN FORCE, including .none, which is the way back. Taking the target
    // state rather than a verb is what lets one call serve the correction and its undo, so the stateful
    // inline control needs no second path and no management sheet (his choice, 2026-07-29).
    static func correctProducer(_ item: QueueItem, to standing: ProducerOverrideEditing.Standing,
                                context: ModelContext, feedback: ActionFeedback) {
        guard let organisation = item.correctableOrganisation else { return }
        let previous = item.producerStanding
        switch standing {
        case .demoted:  ProducerOverrideEditing.demote(organisation, into: context)
        case .promoted: ProducerOverrideEditing.promote(organisation, into: context)
        case .none:     ProducerOverrideEditing.clear(organisation, in: context)
        }
        // #1417's rule: acknowledge only what reached disk, or a correction that failed to save reads as
        // applied and comes back undone on the next launch.
        guard context.saveOrWarn(org: organisation, feedback: feedback) else { return }
        let message: String
        switch standing {
        case .demoted:  message = ActionAck.treatingAsVenue(organisation: organisation)
        case .promoted: message = ActionAck.treatingAsProducer(organisation: organisation)
        case .none:     message = ActionAck.producerCorrectionCleared(organisation: organisation)
        }
        feedback.acknowledge(message, action: .init(label: "Undo") {
            correctProducer(item, to: previous, context: context, feedback: feedback)
        })
    }

    // #1414: `undo` is optional and defaults to nil so this stays the single status setter for every
    // caller, while only KEEP and DISMISS actually record. setStatus also drives approve, unapprove and
    // skip-draft; recording unconditionally here would quietly make those undoable too, well past the
    // scope Dan settled on ("I mostly just need this for keep/dismiss").
    static func setStatus(_ item: QueueItem, _ status: ReviewStatus, _ reason: ShowOutcome?,
                          prospects: [Prospect], context: ModelContext, feedback: ActionFeedback,
                          undo: QueueUndoStack? = nil, undoLabel: String? = nil) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        // Read BEFORE the mutation, so the entry records where the row actually came from rather than
        // an inverse guessed at undo time.
        let priorStatus = model.status
        let priorReason = model.showOutcomeRaw
        let priorExit = model.dismissedAt
        let priorClearedConflict = model.conflictClearedKey
        // #16: routed through the model's own pair so the exit date is stamped on a cut and cleared on
        // any move back into the queue, rather than depending on every caller of this setter to remember.
        if status == .dismissed {
            model.markDismissed(reason: reason)
        } else {
            model.clearDismissal(to: status)
        }
        // #1583: Keep IS Dan's acceptance of a date clash he can already see on the card. He is looking at
        // the sentence naming the night when he presses it, so asking him a second time, through a separate
        // control, is a second confirmation of one judgment. (The live store settled how well the separate
        // control worked: it had never been used once.)
        //
        // Gated on `.queued` because that is what Keep sets and nothing else does; approve, unapprove and
        // skip-draft come through here too and mean nothing about a clash. `clearConflict` is unchanged, so
        // the acceptance is still recorded against the EXACT clash he saw and a clash that changes under him
        // blocks again (#718's pattern).
        if status == .queued { model.clearConflict() }
        if let undo, let undoLabel {
            undo.record(QueueUndoEntry(recording: undoLabel, on: model, priorStatus: priorStatus,
                                       priorShowOutcomeRaw: priorReason, priorDismissedAt: priorExit,
                                       priorConflictClearedKey: priorClearedConflict))
        }
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #1500: one reason, applied to every show Dan can see on one date, as ONE undoable action. His words
    // (2026-07-25): "I need a way to auto dismiss everything on one date."
    //
    // Takes KEYS rather than deciding for itself which shows are on the night: the caller hands over the
    // rows that date group is actually rendering, so a filter or a search that narrows the night narrows
    // this with it, and nothing is buried that was not on screen.
    //
    // Deliberately does NOT offer to capture the date as a day off the way a single calendar-reason
    // dismiss does (#924). Dan's call, 2026-07-26: a bulk dismiss should stay quiet.
    static func dismissAll(_ keys: [String], reason: ShowOutcome, dateLabel: String,
                           prospects: [Prospect], context: ModelContext, feedback: ActionFeedback,
                           undo: QueueUndoStack? = nil) {
        let byKey = Dictionary(prospects.map { ($0.naturalKey, $0) }, uniquingKeysWith: { first, _ in first })
        // Two rows are skipped rather than recorded: one whose key has no prospect left (deleted at runtime
        // by NaturalKeyVenueMigration), and one this exact action already dismissed for this exact reason
        // ("assume it runs twice"). An entry describing a dismissal that did not happen would spend the
        // next Cmd+Z doing nothing while looking exactly like a working undo.
        let targets = keys.compactMap { byKey[$0] }
            .filter { !($0.status == .dismissed && $0.showOutcome == reason) }
        guard !targets.isEmpty else { return }

        let rows = targets.map { model -> QueueUndoEntry.Row in
            let priorStatus = model.status
            let priorReason = model.showOutcomeRaw
            let priorExit = model.dismissedAt
            // #1583: a dismiss never touches the accepted clash, so this records the value it is leaving
            // alone. Passing nil instead would make undoing a bulk dismiss silently re-block every show on
            // the night that Dan had already waved through.
            let priorClearedConflict = model.conflictClearedKey
            // #16: the model's own setter, so the exit date is stamped here exactly as a per-card dismiss
            // stamps it, and a show dismissed twice keeps its FIRST exit date.
            model.markDismissed(reason: reason)
            return QueueUndoEntry.Row(recording: model, priorStatus: priorStatus,
                                      priorShowOutcomeRaw: priorReason, priorDismissedAt: priorExit,
                                      priorConflictClearedKey: priorClearedConflict)
        }
        // #1417: nothing is claimed and nothing is made undoable until the write is confirmed. An undo
        // entry for a dismissal that never reached disk would put back rows that never left.
        guard context.saveOrWarn(org: dateLabel, feedback: feedback) else { return }
        if let undo,
           let entry = QueueUndoEntry.batch(actionLabel: "Dismiss",
                                            label: BulkDismiss.undoLabel(count: rows.count,
                                                                         dateLabel: dateLabel),
                                            rows: rows) {
            undo.record(entry)
        }
        feedback.acknowledge(ActionAck.nightDismissed(count: rows.count, reason: reason,
                                                      dateLabel: dateLabel))
    }

    // #924: dismiss for a reason, then, when that reason is about the calendar, OFFER to capture the date
    // as a day off. Dan telling Overture "not this day" is the most natural moment to block it, instead of
    // making him say it twice. The offer is a CENTERED picker (via the injected request RootView presents),
    // pre-filled with the show's date or run, not a missable banner: dismissing for a date reason almost
    // always means he'll block it, so a modal he acts on is right. It is still an offer, never automatic:
    // nothing is blocked until he confirms in the picker (or he closes it with Not now).
    static func dismissForReason(_ item: QueueItem, _ reason: ShowOutcome,
                                 prospects: [Prospect], context: ModelContext,
                                 feedback: ActionFeedback, offer: DayOffOfferRequest,
                                 undo: QueueUndoStack? = nil) {
        setStatus(item, .dismissed, reason, prospects: prospects, context: context, feedback: feedback,
                  undo: undo, undoLabel: "Dismiss")
        // #939: a same-production show at a different venue nearby widens the offer to the whole
        // engagement, so blocking in one action captures every date, not just this row's own.
        let linked = EngagementLink.group(prospects.map(EngagementLink.Row.init))[item.id]?.map(\.date) ?? []
        guard let o = DayOffOffer.offer(reason: reason, performanceDate: item.performanceDate,
                                        runEndDate: item.runEndDate, linkedDates: linked,
                                        alreadyBlocked: item.hasUnclearedConflict) else { return }
        offer.request(key: item.id, org: item.groupName, start: o.start, end: o.end)
    }

    // #924: add the day(s) off and confirm it, reversibly. Shared by the single-tap dismiss offer and the
    // picker sheet's confirm, so both go through one implementation. Reuses DayOffEditing.add, which runs
    // the conflict sweep, so every other show on those nights is flagged in the same action. A refused
    // range (backwards, too long) says why instead of failing silently.
    // #1416: `export` is a parameter, not a hidden read, for the same reason DayOffEditing.add takes one:
    // the sweep on both sides of this action is testable without a file on disk, so the Undo's WIRING can be
    // pinned and not just the rule behind it (#887). Threading ONE read through also means the block and its
    // undo sweep against the SAME calendar, rather than re-reading the export at undo time and possibly
    // judging against different bookings than the block did.
    // #1473: `undo` and `undoDismissOf` fold this block into the dismiss that led to it, so one press of
    // Cmd+Z takes both back. They are a pair and both optional: the Days Off sheet blocks days that no
    // dismiss led to, and passes neither.
    @discardableResult
    static func blockDaysOff(start: String, end: String, note: String? = nil,
                             export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                             context: ModelContext, feedback: ActionFeedback,
                             undo: QueueUndoStack? = nil, undoDismissOf naturalKey: String? = nil) -> Bool {
        let range = QueueModel.runDateLabel(start: start, end: end)
        let result = DayOffEditing.add(start: start, end: end, note: note, export: export, into: context)
        guard result == .added else {
            feedback.acknowledge(DayOffEditing.message(for: result) ?? "Couldn't block \(range)", tone: .warning)
            return false
        }
        // #1417: DayOffEditing.add persists with a bare `try? context.save()`, so a failed write reached
        // Dan as "Jul 3 to Jul 5 is now blocked" while every show those nights stayed draftable and
        // sendable. Confirm it landed before saying so, and before offering an Undo for it.
        guard context.saveOrWarn(org: range, feedback: feedback) else { return false }
        // #1473: attached only once the write is CONFIRMED, under the same guard as the acknowledgment
        // above. An entry promising to remove a day off that a refused range never wrote would make the
        // next Cmd+Z delete whatever else happened to sit on those dates.
        if let undo, let naturalKey {
            undo.attachBlockedDaysOff(start: start, end: end, toDismissOf: naturalKey)
        }
        // The Undo must reverse the whole action, not just the row: DayOffEditing.remove re-runs the same
        // sweep, so every show this block flagged is un-flagged and draftable again. A show left flagged
        // against a day that is no longer blocked would be held back from drafting and sending, silently.
        feedback.acknowledge(ActionAck.dayOffBlocked(range: range),
                             action: .init(label: "Undo") {
                                 if let row = DayOffEditing.rows(in: context)
                                     .first(where: { $0.startDate == start && $0.endDate == end }) {
                                     DayOffEditing.remove(row, export: export, in: context)
                                 }
                             })
        return true
    }

    // #1740/#1840: Dan is not working this event any more. Held here rather than inside FollowUpsView so
    // the whole decision (which grain, what it records, what it leaves alone) is reachable by a test; the
    // view supplies the save and the acknowledgement around it.
    //
    // It records `.stoodDown` on the contacts, which closes them: the decide clock stops asking and the
    // show reads as stopped rather than declined. It deliberately does NOT touch the lead's own outcome
    // or `outcomeSource`, which are the auto-detection's to move.
    static func standDown(prospect: Prospect, recipient: Recipient, scope: StandDownScope, now: Date) {
        switch scope {
        case .contact:
            recipient.standDownOutreach(now: now)
            recipient.resolution = .stoodDown
        case .show:
            prospect.standDownOutreach(now: now)
            // #2395: the SHOW grain is an ENDING, in the one vocabulary's words: "I turned them down". Dan
            // rejected the old framing outright ("I will never stop working something without closure"), so
            // stopping work on an event is a refusal he made, and the report has to be able to count it.
            // Recorded alongside the stand-down stamp rather than instead of it, because the two are
            // genuinely different facts: the stamp is what stops the nudges, this is how the show ended.
            prospect.showOutcome = .turnedThemDown
            // Every contact, because "I am not working this event" is a statement about all of them, and a
            // contact left open would keep the show reading as active and keep the clock asking.
            for r in prospect.recipients where r.resolution == nil { r.resolution = .stoodDown }
        }
    }

    // The undo. It clears the recorded state as well as the stand-down: leaving the contacts closed would
    // keep the show shut on a decision Dan just reversed.
    static func resumeStandDown(prospect: Prospect, recipient: Recipient, scope: StandDownScope) {
        switch scope {
        case .contact:
            recipient.resumeOutreach()
            if recipient.resolution == .stoodDown { recipient.resolution = nil }
        case .show:
            prospect.resumeOutreach()
            // #2395: the ending goes too. Leaving it would keep the show counted as one Dan turned down
            // after he just took that decision back, and the report would be reading a refusal he undid.
            if prospect.showOutcome == .turnedThemDown { prospect.showOutcome = nil }
            for r in prospect.recipients where r.resolution == .stoodDown { r.resolution = nil }
        }
    }

    static func saveDraft(_ item: QueueItem, _ subject: String, _ body: String,
                         prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.applyEdit(subject: subject, body: body)
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #2010: Dan's own opening for ONE contact of this show. Blank goes back to Overture's own, so
    // clearing the field is an undo rather than a request for an email with no greeting at all.
    //
    // Matched to a recipient by id within this show, never across shows: the id is the canonical address
    // and the same person can be a contact on several, so a global lookup would rewrite the opening on a
    // pitch Dan was not looking at.
    static func saveOpening(_ item: QueueItem, recipientId: String, opening: String,
                            prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              let recipient = model.recipients.first(where: { $0.id == recipientId }) else { return }
        let trimmed = opening.trimmingCharacters(in: .whitespacesAndNewlines)
        recipient.openingOverride = trimmed.isEmpty ? nil : trimmed
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #2034: Dan's choice for THIS event, one email to everybody or one each. Written as the override
    // rather than a plain flag, so a show he has never touched still reads as the default rather than as a
    // decision he made.
    static func setSendsTogether(_ item: QueueItem, _ together: Bool,
                                 prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        model.sendsTogetherOverride = together
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #2033: the opening of a joint email, which belongs to the SHOW because one message has one greeting.
    // Blank clears it back to Overture's own, matching how a per-contact opening behaves.
    static func saveJointOpening(_ item: QueueItem, opening: String,
                                 prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        let trimmed = opening.trimmingCharacters(in: .whitespacesAndNewlines)
        model.jointOpeningOverride = trimmed.isEmpty ? nil : trimmed
        context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    // #367/#1143: re-prep this one show. It applies the requested mode's flags, saves, and then actually
    // LAUNCHES a Prep run scoped to just this show (reusing PrepQueueService.startPrep, the same detached
    // path "Prep kept" uses), rather than only flagging it for some future run Dan has to remember to
    // start. The launch is an injected seam so it stays testable; production defaults to the real service.
    // #1824: async, because the launch now renders this show's own listing page before starting the run, so
    // the draft is grounded in what the show actually is. The caller awaits it from a task rather than
    // blocking the click.
    static func reprep(_ item: QueueItem, mode: ReprepMode, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback,
                       now: Date = Date(),
                       startPrep: @MainActor (ModelContext, Date, Set<String>) async throws -> Void = { ctx, now, keys in
                           _ = try await PrepQueueService.startPrep(from: ctx, now: now, includedKeys: keys)
                       }) async {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }

        // #1828: a show on a night Dan is booked or away for cannot be re-prepped at all.
        // PrepQueueBuilder.needsPrep refuses it BEFORE it reads the re-prep flags, so setting a flag and
        // launching would acknowledge work that the run then silently declines to do. Checked here, ahead
        // of the flags, so no request is left behind to ride a later run just as silently. The card
        // already offers the control in a blocked state saying this (QueueModel.reprepOffer); this is the
        // enforcement under it, since a rule and its wiring are two claims (#1679).
        guard !model.hasUnclearedConflict else {
            feedback.acknowledge(ActionAck.reprepBlockedByClash(org: item.groupName), tone: .warning)
            return
        }

        let draftGranted = ReprepRequest.apply(mode, to: model)
        guard context.saveOrWarn(org: item.groupName, feedback: feedback) else { return }

        // A draft-only re-prep of a show already emailed grants nothing (ReprepRequest gates the draft
        // half on sentAt == nil), so there is no work to run: say why rather than launch an empty run.
        guard mode != .draftOnly || draftGranted else {
            feedback.acknowledge(ActionAck.reprepNothingToRedraft(org: item.groupName))
            return
        }

        // Launch the run for JUST this show. The double-launch guard is startPrep's own in-flight marker
        // (CLAUDE.md "assume it runs twice"): a second click, or a run already going, throws
        // .alreadyRunning, and since the flag is already saved the show simply rides the next run.
        do {
            try await startPrep(context, now, [item.id])
            feedback.acknowledge(ActionAck.reprepStarted(mode: mode, draftGranted: draftGranted, org: item.groupName))
        } catch PrepQueueService.PrepLaunchError.alreadyRunning {
            feedback.acknowledge(ActionAck.reprepRunInFlight(org: item.groupName))
        } catch {
            // Fail loud (CLAUDE.md): a launch that could not start (runner unavailable, write failure)
            // must not leave the badge implying work is under way. The flag stays saved for a later run.
            feedback.acknowledge(error.localizedDescription, tone: .warning)
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

    static func correctClassification(_ item: QueueItem, discipline: Discipline,
                                      prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        ClassificationOverride.correct(model, discipline: discipline, now: Date())
        if context.saveOrWarn(org: item.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.classificationCorrected(org: item.groupName))
        }
    }

    // #1274: Dan renames an ugly scout-generated name. Set the display name and the override so the
    // scout stops clobbering it, and capture the scout's current name once (if not already tracked) so
    // "reset to scout name" has something to restore even before the next scout re-runs. The natural key
    // is deliberately left alone: it stays scout-name-derived, so the next scout's exact-key match still
    // finds this row and never inserts a duplicate.
    static func renameGroup(_ item: QueueItem, to newName: String,
                            prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if model.scoutGroupName == nil { model.scoutGroupName = model.groupName }
        model.groupName = trimmed
        model.groupNameOverriddenByDan = true
        if context.saveOrWarn(org: trimmed, feedback: feedback) {
            feedback.acknowledge(ActionAck.groupRenamed(to: trimmed))
        }
    }

    // #1274: hand the name back to the scout. Restore the latest tracked scout name (kept current by
    // ScoutService.apply) and clear the override so future scouts own the name again.
    static func resetGroupName(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        if let scoutName = model.scoutGroupName { model.groupName = scoutName }
        model.groupNameOverriddenByDan = false
        if context.saveOrWarn(org: model.groupName, feedback: feedback) {
            feedback.acknowledge(ActionAck.groupNameReset(to: model.groupName))
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
    //
    // #1419: both return whether the verdict actually landed, and neither saves when the model reports
    // there was nothing to change. A save that writes nothing is not free: if it FAILS it warns Dan
    // about an action that was never attempted. Neither posts a success acknowledgment (they never
    // have), so the returned Bool is the only thing that distinguishes a real change from a no-op, and
    // it is what an undo stack (#1413) must consult before offering to reverse one of these.
    @discardableResult
    static func confirmPerformerMatch(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) -> Bool {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              model.confirmPerformerMatch() else { return false }
        return context.saveOrWarn(org: item.groupName, feedback: feedback)
    }

    @discardableResult
    static func dismissPerformerMatch(_ item: QueueItem, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback) -> Bool {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }),
              model.dismissPerformerMatch() else { return false }
        return context.saveOrWarn(org: item.groupName, feedback: feedback)
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
    // Internal (not private) so the inquiry first-reply sheet (#1436) reuses the ONE live-sender
    // construction rather than duplicating the identity wiring.
    static func liveSender() -> MailSender {
        GmailSender(fromName: SendIdentity.danWright.name, fromEmail: SendIdentity.danWright.email)
    }

    // The confirm dialog itself (step 1 of a send) stays in each screen: it only needs
    // SendConfirmation(prospect:), a pure struct init, not worth extracting. This is step 2, the
    // actual send. markSending/clearSending let each screen show its own live "Sending..." state;
    // onNeedsReconnect lets each screen show its own reconnect prompt.
    // #2050: what confirming the final-review sheet does. Approving and sending are one action now, so
    // this is the only path a draft takes to a stranger's inbox and there is no separate approved state
    // for Dan to park a show in. His words: "There's no real reason to approve it again on another
    // screen."
    //
    // The approval is committed BEFORE the send rather than after it, and stays committed if the send
    // fails, because a failed send has to be retryable: the show keeps its approval, records its error,
    // and is still rendered by Review (StageNavigation now holds a show there until every contact has been
    // emailed), which is the disappearance this issue was filed about. Approving only what is still
    // `.drafted` keeps this idempotent, so a retry on an already-approved show does not re-approve it.
    static func approveAndSend(_ item: QueueItem, prospects: [Prospect], context: ModelContext,
                               feedback: ActionFeedback,
                               selecting: [String]? = nil, together: Bool? = nil,
                               sender: MailSender = liveSender(),
                               markSending: @escaping (String) -> Void,
                               clearSending: @escaping (String) -> Void,
                               onNeedsReconnect: @escaping () -> Void,
                               onSent: @escaping (_ naturalKey: String, _ fullySent: Bool) -> Void = { _, _ in }) {
        guard let model = prospects.first(where: { $0.naturalKey == item.id }) else { return }
        if model.status == .drafted {
            // Through the same setter every other status change uses, so approving here cannot quietly
            // skip the bookkeeping (the dismissal fields, the conflict rules) that setter owns.
            setStatus(item, .approved, nil, prospects: prospects, context: context, feedback: feedback)
        }
        performSend(item.id, prospects: prospects, context: context, feedback: feedback,
                    selecting: selecting, together: together, sender: sender,
                    markSending: markSending, clearSending: clearSending,
                    onNeedsReconnect: onNeedsReconnect, onSent: onSent)
    }

    // #2017: `selecting` is the contacts Dan ticked on the send sheet, and `together` the choice he made
    // there. Both nil leaves the path every other caller uses untouched.
    static func performSend(_ naturalKey: String, prospects: [Prospect], context: ModelContext, feedback: ActionFeedback,
                           selecting: [String]? = nil, together: Bool? = nil,
                           sender: MailSender = liveSender(),
                           markSending: @escaping (String) -> Void, clearSending: @escaping (String) -> Void,
                           onNeedsReconnect: @escaping () -> Void,
                           // #361: on a successful send, report whether it emptied the show (no pending recipient
                           // left). The queue plays its leaving delight only when the row actually departs, so a
                           // partial send on a multi-recipient show (still someone pending) does not trigger it.
                           onSent: @escaping (_ naturalKey: String, _ fullySent: Bool) -> Void = { _, _ in }) {
        guard let model = prospects.first(where: { $0.naturalKey == naturalKey }) else { return }
        // Written at the COMMIT, not as he flips it, so cancelling the sheet changes nothing about the show.
        if let together { model.sendsTogetherOverride = together }
        let chosen = selecting.map { SendGroup.sendableFor(model, ids: $0) }
        markSending(naturalKey)
        Task {
            // #1208: pull the current Gmail signature right before composing, so an email Dan sends after
            // editing his signature carries the new one (self-throttled, never blocks the send).
            await GmailSignatureService.refreshBeforeSend()
            // #2033: sendNext is the one place the together-or-separately choice is acted on, so this
            // button, the confirmation Dan just read and the card all agree about who is being emailed.
            let sent = await SendService.sendNext(model, to: chosen, now: Date(), sender: sender)
            context.saveOrWarnSendNotConfirmed(org: model.groupName, feedback: feedback)
            clearSending(naturalKey)
            if sent { onSent(naturalKey, SendGroup.pendingGroup(of: model).isEmpty) }
            // #1770: refresh before deciding. A send that just failed is the moment a revoked credential
            // shows itself, so this must not answer from a cache filled before the token died.
            if !sent && !GmailConnection.shared.refreshedIsConnected() { onNeedsReconnect() }
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
            await GmailSignatureService.refreshBeforeSend()   // #1208
            let sent = await SendService.sendReplyDraft(recipient, of: model, now: Date(), sender: sender)
            context.saveOrWarnSendNotConfirmed(org: item.groupName, feedback: feedback)
            clearSending(recipientId)
            if !sent && !GmailConnection.shared.refreshedIsConnected() { onNeedsReconnect() }   // #1770, see sendOne
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
            await GmailSignatureService.refreshBeforeSend()   // #1208
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
            await GmailSignatureService.refreshBeforeSend()   // #1208
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
    // #2017: the sheet lets Dan change WHO the pitch reaches and HOW, so it needs to rebuild what it is
    // showing as he ticks, and to report the choice back when he commits. Built where the prospect is in
    // hand. Nil leaves the sheet exactly as it was, which is what the follow-up and note paths want.
    var rebuild: (@MainActor (_ selected: [String], _ together: Bool) -> SendConfirmation?)? = nil
    var onSendSelection: (@MainActor (_ selected: [String], _ together: Bool) -> Void)? = nil
}
