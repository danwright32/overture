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

    // The send queue: approved prospects with a draft and a contact email, not yet
    // sent, oldest-approved first (FIFO by ingestedAt as a stand-in for approval order).
    static func pending(in context: ModelContext) -> [Prospect] {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return all
            .filter { $0.status == .approved && $0.sentAt == nil && $0.draftBody != nil && $0.contactEmail != nil }
            .sorted { $0.ingestedAt < $1.ingestedAt }
    }

    // Sends ONE specific prospect immediately, bypassing the throttle. This is the
    // manual per-draft "Send" Dan clicks (one click = one email); manual approval is
    // its own pacing, so no drip needed. Records the receipt or the error for retry.
    @discardableResult
    static func sendOne(_ prospect: Prospect, now: Date, sender: MailSender) async -> Bool {
        guard prospect.status == .approved, prospect.sentAt == nil,
              let email = prospect.contactEmail, let body = prospect.draftBody else { return false }
        let mail = OutgoingMail(to: email, subject: prospect.draftSubject ?? "", body: body)
        do {
            let receipt = try await sender.send(mail)
            prospect.sentAt = now
            prospect.status = .contacted
            prospect.gmailThreadId = receipt.threadId
            prospect.gmailMessageId = receipt.messageID
            prospect.priorRelationshipAtSend = prospect.priorRelationship
            prospect.freezeSentCopy(subject: mail.subject, body: body)
            prospect.sendError = nil
            return true
        } catch {
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

    static func recentSendDates(in context: ModelContext) -> [Date] {
        let all = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        return all.compactMap { $0.sentAt }
    }

    // Sends the next due email if the throttle allows. At most one per call.
    @discardableResult
    static func releaseDueSends(in context: ModelContext, now: Date, sender: MailSender,
                                config: SendThrottleConfig = .default) async -> Outcome {
        let queue = pending(in: context)
        guard let next = queue.first else { return Outcome(sent: 0, failed: 0, throttled: false) }

        let recent = recentSendDates(in: context)
        guard SendThrottle.canSendNow(recentSends: recent, now: now, config: config) else {
            return Outcome(sent: 0, failed: 0, throttled: true)
        }

        let mail = OutgoingMail(
            to: next.contactEmail ?? "",
            subject: next.draftSubject ?? "",
            body: next.draftBody ?? ""
        )
        do {
            let receipt = try await sender.send(mail)
            next.sentAt = now
            next.status = .contacted
            next.gmailThreadId = receipt.threadId
            next.gmailMessageId = receipt.messageID
            next.priorRelationshipAtSend = next.priorRelationship
            next.freezeSentCopy(subject: mail.subject, body: mail.body)
            next.sendError = nil
            try? context.save()
            return Outcome(sent: 1, failed: 0, throttled: queue.count > 1)
        } catch {
            next.sendError = error.localizedDescription
            try? context.save()
            return Outcome(sent: 0, failed: 1, throttled: false)
        }
    }
}
