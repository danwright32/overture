import Foundation
import SwiftData

// Phase 1 (#391): the one-writer-per-fact migration onto the recipients model. Every existing
// performance predates Recipient and carries its single contact in the legacy singular fields
// (contactEmail/contactName/.../sentAt/gmailThreadId/...). This synthesizes that contact as
// recipients[0] (provenance .act) so the new per-recipient code paths have data to read, then runs
// once at launch guarded by recipients.isEmpty so it never duplicates or clobbers later edits.
//
// The same synthesizer seeds DebugStaging's in-session leads, so the legacy->Recipient mapping lives
// in exactly one place (consolidation): a staged lead and a backfilled one carry identical recipients.
enum RecipientBackfill {
    // Build recipients[0] from a prospect's legacy singular fields, or nil when there is no contact
    // to make a recipient from (a scout-only performance has zero recipients).
    static func synthesizedRecipient(from prospect: Prospect) -> Recipient? {
        guard let email = prospect.contactEmail, !email.isEmpty else { return nil }

        var r = Recipient(id: ReplyDetection.email(from: email),
                          email: email,
                          name: prospect.contactName,
                          role: prospect.contactRole,
                          provenance: .act,
                          contactMethodRaw: prospect.contactMethodRaw,
                          contactConfidenceRaw: prospect.contactConfidenceRaw,
                          contactFormURL: prospect.contactFormURL)

        r.sentAt = prospect.sentAt
        r.sendState = prospect.sentAt != nil ? .sent : .pending
        r.gmailThreadId = prospect.gmailThreadId
        r.gmailMessageId = prospect.gmailMessageId
        r.sendError = prospect.sendError
        r.followUpCount = prospect.followUpCount
        r.lastFollowUpAt = prospect.lastFollowUpAt

        // Mirror the lead's reply state so a performance already marked replied does not read as a
        // silent recipient (which would later draw a wrong follow-up). The first-send/sentAt rollup
        // itself is untouched.
        r.replied = prospect.outcome == .replied
        r.repliedAt = prospect.lastReplyAt
        r.lastReplyText = prospect.lastReplyText
        r.lastReplyId = prospect.lastReplyId
        r.dismissedReplyId = prospect.dismissedReplyId

        return r
    }

    // Seed recipients[0] for every prospect that has none yet. Idempotent: a prospect whose
    // recipients are already populated is skipped, so a relaunch never overwrites manual edits or
    // later per-recipient state. Returns how many prospects were seeded.
    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var seeded = 0
        for prospect in prospects where prospect.recipients.isEmpty {
            guard let recipient = synthesizedRecipient(from: prospect) else { continue }
            prospect.setRecipients([recipient])
            seeded += 1
        }
        return seeded
    }
}
