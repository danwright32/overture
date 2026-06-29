import Foundation
import SwiftData

// Releases approved emails one at a time, respecting the throttle, via an injected
// MailSender. The app calls releaseDueSends on a timer / on approve; each call sends
// at most one email so a big approved batch drips out. Records sentAt + threadId on
// success, or sendError on failure (surfaced for retry, never silently lost).

@MainActor
enum SendService {
    struct Outcome: Equatable, Sendable {
        var sent: Int
        var failed: Int
        var throttled: Bool   // there were pending sends but the throttle held them
    }

    // One queued email: a specific recipient of a specific performance. Fan-out (#394) means a show
    // with two acts plus a presenter contributes one PendingSend per pending recipient, not one per show.
    struct PendingSend {
        let prospect: Prospect
        let recipient: Recipient
    }

    // The send queue: one item per still-to-send recipient of an approved, drafted performance,
    // oldest-approved first (FIFO by the performance's ingestedAt as a stand-in for approval order).
    // Reads recipient state, NOT the lead `sentAt` rollup, so a partially-sent show still surfaces its
    // remaining recipients (closes the duplicate-send / stranded-recipient hole, #389).
    static func pending(in context: ModelContext) -> [PendingSend] {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        let drafted = all
            .filter { $0.status == .approved && $0.draftBody != nil }
            .sorted { $0.ingestedAt < $1.ingestedAt }
        var queue: [PendingSend] = []
        for prospect in drafted {
            for recipient in sendOrdered(prospect.recipients) where recipient.isSendablePending {
                queue.append(PendingSend(prospect: prospect, recipient: recipient))
            }
        }
        return queue
    }

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
        let mail = OutgoingMail(to: email, subject: prospect.draftSubject ?? "",
                                body: Salutation.greeting(for: recipient.name) + "\n\n" + body)
        do {
            let receipt = try await sender.send(mail)
            recipient.sentAt = now
            recipient.sendState = .sent
            recipient.gmailThreadId = receipt.threadId
            recipient.gmailMessageId = receipt.messageID
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
            prospect.freezeSentCopy(subject: mail.subject, body: body)
            prospect.sendError = nil
            // Per-click only (no autonomous drip): the show stays approved while any recipient is still
            // sendable, so the Send button persists for the next one. Once the last one goes, it is
            // contacted.
            if !prospect.recipients.contains(where: \.isSendablePending) {
                prospect.status = .contacted
            }
            return true
        } catch {
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
    static func sendFollowUp(_ prospect: Prospect, now: Date, sender: MailSender,
                             config: FollowUpConfig = .init()) async -> Bool {
        guard let email = prospect.contactEmail, prospect.sentAt != nil,
              prospect.outcome == .noResponse, prospect.followUpCount < config.maxFollowUps else { return false }
        // Reply on the original conversation (#74): same threadId, In-Reply-To the first send's
        // Message-ID, and a "Re:" subject. A reply to the nudge then lands on the thread the
        // reply checker already watches, so that engagement isn't silently missed.
        let mail = OutgoingMail(
            to: email,
            subject: FollowUp.replySubject(originalSubject: prospect.draftSubject, groupName: prospect.groupName),
            body: FollowUp.nudgeBody(contactName: prospect.contactName, groupName: prospect.groupName,
                                     venue: prospect.venue, attempt: prospect.followUpCount + 1),
            inReplyTo: prospect.gmailMessageId,
            threadId: prospect.gmailThreadId)
        do {
            _ = try await sender.send(mail)
            prospect.followUpCount += 1
            prospect.lastFollowUpAt = now
            prospect.sendError = nil
            return true
        } catch {
            prospect.sendError = error.localizedDescription
            return false
        }
    }

    // Sends ONE conversation re-touch for an ACTIVE lead Dan chose to nudge, or the post-event
    // closing note (#111). Unlike sendFollowUp this is a separate, UNCAPPED track (it never touches
    // followUpCount) for leads that have already replied, so the silent-sequence guards don't apply.
    // It threads onto the original conversation (#74) so a reply still lands where the reply checker
    // watches. Re-anchors the reminder (conversationRemindedAt); the closing variant resolves the
    // lead to lostSoft (manual) so it stops nagging. One click = one nudge, never autonomous.
    @discardableResult
    static func sendConversationNudge(_ prospect: Prospect, kind: ConversationReminder.Kind,
                                      now: Date, sender: MailSender) async -> Bool {
        guard let email = prospect.contactEmail, prospect.sentAt != nil else { return false }
        let body: String
        switch kind {
        case .active(let state):
            body = ConversationReminder.nudgeBody(for: state, contactName: prospect.contactName,
                                                  groupName: prospect.groupName, venue: prospect.venue)
        case .closing:
            body = ConversationReminder.closingNudgeBody(contactName: prospect.contactName,
                                                         groupName: prospect.groupName, venue: prospect.venue)
        case .needsState, .suggested:
            return false   // a prompt to categorize/confirm, not a sendable email
        }
        let mail = OutgoingMail(
            to: email,
            subject: FollowUp.replySubject(originalSubject: prospect.draftSubject, groupName: prospect.groupName),
            body: body,
            inReplyTo: prospect.gmailMessageId,
            threadId: prospect.gmailThreadId)
        do {
            _ = try await sender.send(mail)
            prospect.conversationRemindedAt = now   // re-anchor so it steps forward, not nags
            prospect.sendError = nil
            if case .closing = kind {
                prospect.outcome = .lostSoft
                prospect.outcomeSourceRaw = OutcomeSource.manual.rawValue
                prospect.outcomeAt = now
            }
            return true
        } catch {
            prospect.sendError = error.localizedDescription
            return false
        }
    }

    // Throttle input: the timestamp of every recipient email already sent, across all performances,
    // so the drip counts EMAILS, not leads (#389). A two-recipient show contributes two send dates.
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

    static func recentSendDates(in context: ModelContext) -> [Date] {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return all.flatMap { $0.recipients.compactMap(\.sentAt) }
    }

    // Sends the next due recipient email if the throttle allows. At most one per call, so an
    // N-recipient approval drips out one address at a time and never bursts past SendThrottle.
    @discardableResult
    static func releaseDueSends(in context: ModelContext, now: Date, sender: MailSender,
                                config: SendThrottleConfig = .default) async -> Outcome {
        let queue = pending(in: context)
        guard let next = queue.first else { return Outcome(sent: 0, failed: 0, throttled: false) }

        let recent = recentSendDates(in: context)
        guard SendThrottle.canSendNow(recentSends: recent, now: now, config: config) else {
            return Outcome(sent: 0, failed: 0, throttled: true)
        }

        let ok = await deliver(next.recipient, of: next.prospect, now: now, sender: sender)
        try? context.save()
        if ok { return Outcome(sent: 1, failed: 0, throttled: queue.count > 1) }
        return Outcome(sent: 0, failed: 1, throttled: false)
    }
}
