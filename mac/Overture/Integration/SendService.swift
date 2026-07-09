import Foundation
import SwiftData

@MainActor
enum SendService {
    // A performance's recipients in deterministic send order (SwiftData to-many is unordered).
    private static func sendOrdered(_ recipients: [Recipient]) -> [Recipient] {
        recipients.sorted {
            $0.sendOrderRank != $1.sendOrderRank ? $0.sendOrderRank < $1.sendOrderRank : $0.id < $1.id
        }
    }

    // The next recipient a manual or throttled send would target for this performance: the first
    // still-sendable one, or nil when the show is fully sent (or not sendable at all). Shared by
    // sendOne and SendConfirmation so the picker and the actual send can never disagree.
    static func nextPendingRecipient(for prospect: Prospect) -> Recipient? {
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
        guard let email = recipient.email, !email.isEmpty, let body = prospect.draftBody else { return false }
        // #641 (#634 Phase C): a directly-addressed performer's own second-person draft wins over the
        // shared third-person body, for BOTH the actual outgoing mail and the voice-learning snapshot
        // below (freezeSentCopy), computed once so neither can drift from what was really sent.
        let effectiveBody = (recipient.provenance == .performer ? recipient.overrideBody : nil) ?? body

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

        let mail = OutgoingMail(to: email, subject: prospect.draftSubject ?? "",
                                body: Salutation.greeting(for: recipient.name) + "\n\n" + effectiveBody)
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

    // Sends ONE follow-up nudge for a prospect Dan explicitly chose to re-touch (#45):
    // a short templated message to the same contact. Records the follow-up (count +
    // timestamp) on success so the sequencer paces and caps it. Never resets sentAt or
    // the original outcome; one click = one nudge, never autonomous.
    @discardableResult
    static func sendFollowUp(_ recipient: Recipient, of prospect: Prospect, now: Date, sender: MailSender,
                             config: FollowUpConfig = .init()) async -> Bool {
        guard recipient.isAwaitingFollowUp, recipient.followUpCount < config.maxFollowUps,
              let email = recipient.email, !email.isEmpty else { return false }
        // Reply on THIS contact's conversation (#74, per-recipient #418 D): same threadId, In-Reply-To
        // the contact's last Message-ID, and a "Re:" subject, so a reply to the nudge lands on the
        // thread reply detection already watches for this contact.
        let mail = OutgoingMail(
            to: email,
            subject: FollowUp.replySubject(originalSubject: prospect.draftSubject, groupName: prospect.groupName),
            body: FollowUp.nudgeBody(contactName: recipient.name, groupName: prospect.groupName,
                                     venue: prospect.venue, attempt: recipient.followUpCount + 1),
            inReplyTo: recipient.gmailMessageId,
            threadId: recipient.gmailThreadId)
        do {
            let receipt = try await sender.send(mail)
            recipient.followUpCount += 1
            recipient.lastFollowUpAt = now
            if let m = receipt.messageID { recipient.gmailMessageId = m }   // thread the next reply off the nudge
            recipient.sendError = nil
            return true
        } catch {
            recipient.sendError = error.localizedDescription
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
        let body: String
        switch kind {
        case .active(let state):
            body = ConversationReminder.nudgeBody(for: state, contactName: recipient.name,
                                                  groupName: prospect.groupName, venue: prospect.venue)
        case .closing:
            body = ConversationReminder.closingNudgeBody(contactName: recipient.name,
                                                         groupName: prospect.groupName, venue: prospect.venue)
        case .needsState, .suggested:
            return false   // a prompt to categorize/confirm, not a sendable email
        }
        let mail = OutgoingMail(
            to: email,
            subject: FollowUp.replySubject(originalSubject: prospect.draftSubject, groupName: prospect.groupName),
            body: body,
            inReplyTo: recipient.gmailMessageId,
            threadId: recipient.gmailThreadId)
        do {
            _ = try await sender.send(mail)
            recipient.conversationRemindedAt = now   // re-anchor so it steps forward, not nags
            recipient.sendError = nil
            if case .closing = kind {
                recipient.markOutcomeManually(resolution: .declinedSoft)
            }
            return true
        } catch {
            recipient.sendError = error.localizedDescription
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
        let subject = recipient.replyDraftSubject
            ?? FollowUp.replySubject(originalSubject: prospect.draftSubject, groupName: prospect.groupName)
        let mail = OutgoingMail(to: email, subject: subject, body: body,
                                inReplyTo: recipient.gmailMessageId, threadId: recipient.gmailThreadId)
        do {
            let receipt = try await sender.send(mail)
            recipient.gmailMessageId = receipt.messageID          // thread the contact's next reply off ours
            if !receipt.threadId.isEmpty { recipient.gmailThreadId = receipt.threadId }
            recipient.freezeSentReply(now: now)                   // capture the committed copy for voice learning (#463)
            recipient.replyDraftSubject = nil
            recipient.replyDraftBody = nil
            recipient.lastFollowUpAt = now                        // re-anchor this contact's clock
            recipient.sendError = nil
            return true
        } catch {
            recipient.sendError = error.localizedDescription
            return false
        }
    }
}
