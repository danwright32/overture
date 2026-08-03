import Foundation
import SwiftData

@MainActor
enum SendService {
    // A performance's recipients in deterministic send order (SwiftData to-many is unordered).
    nonisolated private static func sendOrdered(_ recipients: [Recipient]) -> [Recipient] {
        recipients.sorted {
            $0.sendOrderRank != $1.sendOrderRank ? $0.sendOrderRank < $1.sendOrderRank : $0.id < $1.id
        }
    }

    // The next recipient a manual or throttled send would target for this performance: the first
    // still-sendable one, or nil when the show is fully sent (or not sendable at all). Shared by
    // sendOne and SendConfirmation so the picker and the actual send can never disagree.
    // #2015: `nonisolated` so the QUEUE CARD can ask the same question the send asks, and the two can
    // never disagree about who is about to be emailed. It reads stored properties and decides; none of
    // the Gmail work the rest of this service does is involved.
    nonisolated static func nextPendingRecipient(for prospect: Prospect) -> Recipient? {
        guard prospect.status == .approved, prospect.draftBody != nil else { return nil }
        return sendOrdered(prospect.recipients).first(where: \.isSendablePending)
    }

    // Sends ONE recipient of a performance immediately, bypassing the throttle. This is the manual
    // per-draft "Send" Dan clicks (one click = one email); for a multi-recipient show each click sends
    // the next pending recipient. Manual approval is its own pacing, so no drip needed.
    @discardableResult
    static func sendOne(_ prospect: Prospect, now: Date, sender: MailSender) async -> Bool {
        guard let recipient = nextPendingRecipient(for: prospect) else { return false }
        return await deliver(recipient, of: prospect, now: now, sender: sender)
    }

    // Deliver to one recipient over the shared, salutation-free body (#393), composing that recipient's
    // own greeting at send. Stamps the recipient's send receipt/state, rolls the first send up to the
    // lead level (write-once), freezes the voice pair once (#395), and flips the show to `.contacted`
    // only when no sendable recipient remains. Records the error on the recipient for retry on failure.
    @discardableResult
    private static func deliver(_ recipient: Recipient, of prospect: Prospect,
                                now: Date, sender: MailSender) async -> Bool {
        guard let email = recipient.email, !email.isEmpty, prospect.draftBody != nil else { return false }
        // #641 (#634 Phase C): a directly-addressed performer's own second-person draft wins over the
        // shared third-person body, for BOTH the actual outgoing mail and the voice-learning snapshot
        // below (freezeSentCopy). Recipient.effectiveBody owns that choice now (#789), so the text the
        // draft lint judges is by construction the same text this sends.
        guard let effectiveBody = recipient.effectiveBody else { return false }

        // #1630: composed by OutgoingPitch, which the copy-to-a-contact-form path also reads, so the
        // text Dan pastes into a form is by construction the text this sends.
        //
        // #2030: composed BEFORE the claim below, deliberately. Both of these can refuse, and refusing
        // after the claim would leave the contact stuck at `.sending` with nothing ever sent, needing
        // Dan to resolve by hand. Nothing here writes or awaits, so there is no cost to doing it first.
        guard let pitch = OutgoingPitch.text(for: recipient, of: prospect),
              let mail = OutgoingMail(to: [email], subject: prospect.draftSubject ?? "", body: pitch)
        else { return false }

        // Claim this recipient before the network await (#475/#476). Nothing here awaits, so on the
        // MainActor this check-then-claim-then-persist is atomic with respect to any other call
        // racing the same recipient: whichever call's synchronous prefix runs first flips the state,
        // and any other call's guard sees anything but .pending and backs off immediately. Persisting
        // the claim (not just mutating in memory) before the network call means a crash between here
        // and the outcome leaves the recipient at .sending, surfaced for Dan to check Gmail and
        // resolve by hand (Recipient.isSendStuck), never silently re-queued as still-pending.
        guard recipient.sendState == .pending else { return false }
        recipient.sendState = .sending
        recipient.sendClaimedAt = now
        guard (try? recipient.modelContext?.save()) != nil else {
            // Couldn't even persist the claim: bail rather than race ahead uncertain whether a
            // concurrent caller can see it.
            recipient.sendState = .pending
            recipient.sendClaimedAt = nil
            return false
        }

        do {
            let receipt = try await sender.send(mail)
            recipient.sentAt = now
            recipient.sendState = .sent
            recipient.sendClaimedAt = nil
            recipient.gmailThreadId = receipt.threadId
            recipient.gmailMessageId = receipt.messageID
            recipient.replyTrackingDegraded = receipt.threadIdDegraded
            recipient.sendError = nil
            // Lead-level first-send rollup (#389 Phase 1): set once, never overwritten, so the ~20
            // "was this performance contacted at all" readers keep working unchanged. The thread/
            // message ids also roll up from the first send so follow-up threading (#74) and reply
            // detection keep working until Phase 4 moves them to per-recipient threads.
            if prospect.sentAt == nil {
                prospect.sentAt = now
                prospect.priorRelationshipAtSend = prospect.priorRelationship
                // #4: the rest of the ranking features, frozen for the same reason and at the same
                // moment. Without this, a feedback loop would score this pitch against whatever the
                // newest scout has since written over the row.
                prospect.freezeFeaturesAtSend()
                prospect.gmailThreadId = receipt.threadId
                prospect.gmailMessageId = receipt.messageID
            }
            prospect.freezeSentCopy(subject: mail.subject, body: effectiveBody)
            prospect.sendError = nil
            // Per-click only (no autonomous drip): the show stays approved while any recipient is still
            // sendable, so the Send button persists for the next one. Once the last one goes, it is
            // contacted.
            if !prospect.recipients.contains(where: \.isSendablePending) {
                prospect.status = .contacted
            }
            return true
        } catch {
            recipient.sendState = .pending
            recipient.sendClaimedAt = nil
            recipient.sendError = error.localizedDescription
            prospect.sendError = error.localizedDescription
            return false
        }
    }

    // #468 (SUP-005): the same claim-before-await pattern deliver() uses for the primary send
    // (sendState/sendClaimedAt below), generalized over a claim field so it can guard a secondary
    // send too. The check-then-set-then-persist is synchronous (no await in between), so on the
    // MainActor a second concurrent call against the SAME claim field sees it already set and
    // backs off before ever reaching the network, instead of double-sending.
    private static func claimSecondarySend(_ recipient: Recipient,
                                           _ claim: ReferenceWritableKeyPath<Recipient, Date?>,
                                           now: Date) -> Bool {
        guard recipient[keyPath: claim] == nil else { return false }
        recipient[keyPath: claim] = now
        guard (try? recipient.modelContext?.save()) != nil else {
            recipient[keyPath: claim] = nil
            return false
        }
        return true
    }

    // Sends ONE follow-up nudge for a prospect Dan explicitly chose to re-touch (#45):
    // a short templated message to the same contact. Records the follow-up (count +
    // timestamp) on success so the sequencer paces and caps it. Never resets sentAt or
    // the original outcome; one click = one nudge, never autonomous.
    @discardableResult
    static func sendFollowUp(_ recipient: Recipient, of prospect: Prospect, now: Date, sender: MailSender,
                             config: FollowUpConfig = .init()) async -> Bool {
        // #1740: the same predicate the row and the Due count read, so a contact Dan stood down cannot be
        // nudged from any surface, including one that never asks the Due list.
        guard FollowUp.isAwaitingNudge(recipient, in: prospect), recipient.followUpCount < config.maxFollowUps,
              let email = recipient.email, !email.isEmpty else { return false }
        // Reply on THIS contact's conversation (#74, per-recipient #418 D): same threadId, In-Reply-To
        // the contact's last Message-ID, and a "Re:" subject, so a reply to the nudge lands on the
        // thread reply detection already watches for this contact.
        // #948: subject and body come from the one shared helper the confirmation sheet also reads, so
        // what Dan confirmed is exactly what sends.
        // #2030: built BEFORE the claim below, so a message that cannot be built never leaves the claim
        // held on a nudge that was never sent.
        let content = FollowUp.nudgeContent(originalSubject: prospect.draftSubject, groupName: prospect.groupName,
                                            isMerged: prospect.isMergedConcert,
                                            contactName: recipient.name, venue: prospect.venue,
                                            followUpCount: recipient.followUpCount)
        guard let mail = OutgoingMail(
            to: [email],
            subject: content.subject,
            body: content.body,
            inReplyTo: recipient.gmailMessageId,
            threadId: recipient.gmailThreadId) else { return false }
        // #468: shared with sendConversationNudge's claim below (mutually exclusive by domain
        // state, see the field's doc comment on Recipient), so a fast double-tap on either one
        // is refused rather than reaching the network twice.
        guard claimSecondarySend(recipient, \.nudgeSendClaimedAt, now: now) else { return false }
        do {
            let receipt = try await sender.send(mail)
            recipient.followUpCount += 1
            recipient.lastFollowUpAt = now
            if let m = receipt.messageID { recipient.gmailMessageId = m }   // thread the next reply off the nudge
            recipient.sendError = nil
            recipient.nudgeSendClaimedAt = nil
            return true
        } catch {
            recipient.sendError = error.localizedDescription
            recipient.nudgeSendClaimedAt = nil   // retryable, never stuck claimed
            return false
        }
    }

    // Sends ONE conversation re-touch or closing note for a specific recipient's ACTIVE conversation
    // (#651/#652), not the lead-level rollup: threads on recipient.gmailMessageId/gmailThreadId (that
    // contact's own conversation), same as sendReplyDraft, so a multi-recipient show's nudge lands on
    // the RIGHT contact instead of whichever recipient sent first. The closing variant resolves ONLY
    // this recipient (markOutcomeManually, mirroring what resolveEngagedContacts does per engaged
    // contact) with no cascade to a sibling recipient or the show's own outcome (Dan's 2026-07-08
    // decision, already locked in on Recipient.setConversationState). Re-anchors this recipient's own
    // reminder clock. One click = one nudge, never autonomous.
    @discardableResult
    static func sendConversationNudge(_ recipient: Recipient, of prospect: Prospect,
                                      kind: ConversationReminder.Kind, now: Date, sender: MailSender) async -> Bool {
        guard let email = recipient.email, !email.isEmpty, recipient.sentAt != nil else { return false }
        // #948: subject and body from the one shared helper the confirmation sheet also reads. It returns
        // nil for a kind that is a prompt, not a sendable email, exactly the .needsState/.suggested case.
        //
        // #2030: both refusals now happen BEFORE the claim, so neither can leave it held on a note that
        // was never sent. That is what the explicit claim release here used to be for.
        guard let content = ConversationReminder.nudgeContent(kind: kind, originalSubject: prospect.draftSubject,
                                                              groupName: prospect.groupName,
                                                              isMerged: prospect.isMergedConcert,
                                                              contactName: recipient.name, venue: prospect.venue),
              let mail = OutgoingMail(
                to: [email],
                subject: content.subject,
                body: content.body,
                inReplyTo: recipient.gmailMessageId,
                threadId: recipient.gmailThreadId) else { return false }
        // #468: shared with sendFollowUp's claim above.
        guard claimSecondarySend(recipient, \.nudgeSendClaimedAt, now: now) else { return false }
        do {
            _ = try await sender.send(mail)
            recipient.conversationRemindedAt = now   // re-anchor so it steps forward, not nags
            recipient.sendError = nil
            if case .closing = kind {
                recipient.markOutcomeManually(resolution: .declinedSoft)
            }
            recipient.nudgeSendClaimedAt = nil
            return true
        } catch {
            recipient.sendError = error.localizedDescription
            recipient.nudgeSendClaimedAt = nil   // retryable, never stuck claimed
            return false
        }
    }

    // Sends Dan's approved AI-drafted reply to ONE recipient, on THAT recipient's own Gmail thread
    // (#421): threads on recipient.gmailMessageId/gmailThreadId, NOT the lead rollup (the rollup is the
    // first contact's thread, so replying to a second contact on it would land on the wrong
    // conversation). On success it consumes the draft and re-anchors that contact's clock. One of the
    // two locked send paths (d); the other is copy-out (recordRepliedInGmail), handled in the UI.
    @discardableResult
    static func sendReplyDraft(_ recipient: Recipient, of prospect: Prospect,
                               now: Date, sender: MailSender) async -> Bool {
        guard let email = recipient.email, !email.isEmpty,
              let body = recipient.replyDraftBody, !body.isEmpty else { return false }
        // #468: on its own claim field, not shared with sendFollowUp/sendConversationNudge's
        // (see the field's doc comment on Recipient), since a replied recipient can legitimately
        // be due for a conversation nudge at the same time.
        let subject = recipient.replyDraftSubject
            ?? FollowUp.replySubject(originalSubject: prospect.draftSubject,
                                     groupName: FollowUp.safeDisplayName(prospect.groupName, isMerged: prospect.isMergedConcert))
        // #2030: built before the claim, for the same reason as the two nudges above.
        guard let mail = OutgoingMail(to: [email], subject: subject, body: body,
                                      inReplyTo: recipient.gmailMessageId,
                                      threadId: recipient.gmailThreadId) else { return false }
        guard claimSecondarySend(recipient, \.replySendClaimedAt, now: now) else { return false }
        do {
            let receipt = try await sender.send(mail)
            recipient.gmailMessageId = receipt.messageID          // thread the contact's next reply off ours
            if !receipt.threadId.isEmpty { recipient.gmailThreadId = receipt.threadId }
            recipient.freezeSentReply(now: now)                   // capture the committed copy for voice learning (#463)
            recipient.replyDraftSubject = nil
            recipient.replyDraftBody = nil
            recipient.lastFollowUpAt = now                        // re-anchor this contact's clock
            recipient.sendError = nil
            recipient.replySendClaimedAt = nil
            return true
        } catch {
            recipient.sendError = error.localizedDescription
            recipient.replySendClaimedAt = nil   // retryable, never stuck claimed
            return false
        }
    }

    // #2031: why these contacts cannot share one email, in the words Dan reads, or nil when they can.
    //
    // Only one reason exists, and it is the one the app must never decide on his behalf: the members would
    // not receive the same words. A directly-addressed performer carries their own second-person letter
    // (#641/#789), so putting them on one message with somebody reading a different letter means one of
    // the two gets text written for the other, greeted by the other's name.
    nonisolated static func jointSendRefusal(_ recipients: [Recipient], of prospect: Prospect) -> String? {
        guard Set(recipients.map { $0.effectiveBody ?? "" }).count > 1 else { return nil }
        return ActionAck.jointSendMixedLetters
    }

    // #2031: ONE email to several contacts of a performance, and every one of them recorded as having
    // received THAT email.
    //
    // The group forms from the still-sendable contacts among those passed, so a contact who already had
    // their own email is never written to twice, and a contact held by a guard is never quietly included
    // in somebody else's message.
    @discardableResult
    static func sendJointly(_ prospect: Prospect, to recipients: [Recipient],
                            now: Date, sender: MailSender) async -> Bool {
        let group = sendOrdered(recipients.filter(\.isSendablePending))
        guard !group.isEmpty, jointSendRefusal(group, of: prospect) == nil,
              let pitch = OutgoingPitch.text(forGroup: group, of: prospect),
              let sharedBody = group.first?.effectiveBody,
              let mail = OutgoingMail(to: group.compactMap(\.email),
                                      subject: prospect.draftSubject ?? "", body: pitch)
        else { return false }

        // Claim ALL of them or none, before the network call, on the same reasoning as `deliver`'s single
        // claim (#475/#476). Nothing between the check and the save awaits, so on the MainActor the whole
        // prefix is atomic: a second call racing this group sees them already claimed and backs off. One
        // save, because `modelContext.save()` persists the whole context, so claiming N costs no more
        // round trips than claiming one.
        guard group.allSatisfy({ $0.sendState == .pending }) else { return false }
        for r in group {
            r.sendState = .sending
            r.sendClaimedAt = now
        }
        guard (try? prospect.modelContext?.save()) != nil else {
            for r in group {
                r.sendState = .pending
                r.sendClaimedAt = nil
            }
            return false
        }

        let groupId = UUID().uuidString
        do {
            let receipt = try await sender.send(mail)
            for r in group {
                r.sentAt = now
                r.sendState = .sent
                r.sendClaimedAt = nil
                r.gmailThreadId = receipt.threadId
                r.gmailMessageId = receipt.messageID
                r.replyTrackingDegraded = receipt.threadIdDegraded
                r.sendGroupId = groupId
                r.sendError = nil
            }
            // The lead-level first-send rollup, written once, exactly as `deliver` does it.
            if prospect.sentAt == nil {
                prospect.sentAt = now
                prospect.priorRelationshipAtSend = prospect.priorRelationship
                prospect.freezeFeaturesAtSend()
                prospect.gmailThreadId = receipt.threadId
                prospect.gmailMessageId = receipt.messageID
            }
            prospect.freezeSentCopy(subject: mail.subject, body: sharedBody)
            prospect.sendError = nil
            if !prospect.recipients.contains(where: \.isSendablePending) {
                prospect.status = .contacted
            }
            return true
        } catch {
            // Every member carries the failure, not just the first. A contact left with no trace of the
            // attempt is indistinguishable from one never tried (L47), and this send was attempted on
            // behalf of all of them at once.
            for r in group {
                r.sendState = .pending
                r.sendClaimedAt = nil
                r.sendError = error.localizedDescription
            }
            prospect.sendError = error.localizedDescription
            return false
        }
    }
}
