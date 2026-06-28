import Foundation
import SwiftData

// #409: the one-shot seeder that gives every existing performance its Recipient rows by synthesizing
// a single act recipient from the legacy singular contact/send fields. Runs once at launch guarded by
// `recipients.isEmpty`, so it never duplicates or clobbers later edits. The synthesizer is also reused
// by DebugStaging so the legacy->Recipient mapping lives in one place.
enum RecipientBackfill {
    // Build a single act recipient from a prospect's legacy singular fields, or nil when there is
    // neither email nor form (a scout-only performance has no recipient). A form-only act (#368) gets
    // a recipient keyed on its form URL with a nil email.
    static func synthesizedRecipient(from prospect: Prospect) -> Recipient? {
        guard let id = Recipient.makeId(email: prospect.contactEmail,
                                        formURL: prospect.contactFormURL) else { return nil }
        let email = (prospect.contactEmail?.isEmpty == false) ? prospect.contactEmail : nil

        let r = Recipient(id: id, email: email, name: prospect.contactName, role: prospect.contactRole,
                          provenance: .act, contactMethodRaw: prospect.contactMethodRaw,
                          contactConfidenceRaw: prospect.contactConfidenceRaw,
                          contactFormURL: prospect.contactFormURL)
        r.sentAt = prospect.sentAt
        r.sendState = prospect.sentAt != nil ? .sent : .pending
        r.gmailThreadId = prospect.gmailThreadId
        r.gmailMessageId = prospect.gmailMessageId
        r.sendError = prospect.sendError
        r.followUpCount = prospect.followUpCount
        r.lastFollowUpAt = prospect.lastFollowUpAt

        // Mirror the lead's reply/terminal state so a performance already marked replied/booked/lost
        // does not later re-derive wrong (a booked lead must not read as a silent recipient). #410.
        r.replied = prospect.outcome == .replied
        r.repliedAt = prospect.lastReplyAt
        r.lastReplyText = prospect.lastReplyText
        r.lastReplyId = prospect.lastReplyId
        r.dismissedReplyId = prospect.dismissedReplyId
        r.resolution = resolution(for: prospect.outcome)
        return r
    }

    // #410: map the lead outcome onto the single legacy recipient's terminal resolution, so a past
    // booked/lost performance keeps its meaning under the per-recipient derived status.
    static func resolution(for outcome: Outcome) -> RecipientResolution? {
        switch outcome {
        case .booked: return .booked
        case .lostHard: return .declinedHard
        case .lostSoft: return .declinedSoft
        default: return nil
        }
    }

    // Seed rows for every prospect that has none yet. Idempotent: a prospect whose relationship is
    // already populated is skipped, so a relaunch never overwrites manual edits or per-recipient
    // state. Returns how many prospects were seeded.
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var seeded = 0
        for prospect in prospects where prospect.recipients.isEmpty {
            if let r = synthesizedRecipient(from: prospect) {
                prospect.setRecipients([r])
                seeded += 1
            }
        }
        return seeded
    }
}
