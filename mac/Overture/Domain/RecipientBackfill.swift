import Foundation
import SwiftData

// #409: the ONE seeder that gives every existing performance its Recipient rows. Two inputs, in
// priority order, so there is a single path (no dual-seeder data loss):
//   1. the legacy recipients JSON blob (recipientsRaw, #391) decoded into rows — authoritative for
//      any performance that already had recipients (it may carry a presenter, a manual add, or
//      accumulated per-recipient state);
//   2. otherwise, synthesize a single act recipient from the legacy singular contact/send fields.
// Runs once at launch guarded by `recipients.isEmpty`, so it never duplicates or clobbers later
// edits. The synthesizer is also reused by DebugStaging so the legacy->Recipient mapping lives in one
// place.
enum RecipientBackfill {
    // The legacy JSON-blob element shape (#391), decoded ONLY to migrate old data into rows (#409).
    private struct LegacyRecipient: Codable {
        var id: String
        var email: String?
        var name: String?
        var role: String?
        var provenanceRaw: String
        var contactMethodRaw: String?
        var contactConfidenceRaw: String?
        var contactFormURL: String?
        var sendStateRaw: String
        var sentAt: Date?
        var gmailThreadId: String?
        var gmailMessageId: String?
        var sendError: String?
        var followUpCount: Int
        var lastFollowUpAt: Date?
        var replied: Bool
        var repliedAt: Date?
        var lastReplyId: String?
        var dismissedReplyId: String?
        var lastReplyText: String?
        var bounced: Bool
        var resolutionRaw: String?
    }

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
            if let rows = rowsFromLegacyBlob(prospect.recipientsRaw), !rows.isEmpty {
                prospect.setRecipients(rows)
                seedOutcomeResolution(prospect)
                seeded += 1
            } else if let r = synthesizedRecipient(from: prospect) {
                prospect.setRecipients([r])
                seeded += 1
            }
        }
        return seeded
    }

    // #410 for the blob path: legacy blobs predate `resolution` (Phase 1 never wrote it), so a
    // booked/lost performance migrated from the blob would carry no resolution and re-derive as
    // Active under the per-recipient status. When the lead is booked/lost and no recipient yet
    // carries a resolution, attribute it to the act recipient (or the first). The synthesize path
    // already sets this, so this only fills the blob path.
    private static func seedOutcomeResolution(_ prospect: Prospect) {
        guard let res = resolution(for: prospect.outcome),
              !prospect.recipients.contains(where: { $0.resolution != nil }),
              let target = prospect.recipients.first(where: { $0.provenance == .act })
                ?? prospect.recipients.first else { return }
        target.resolution = res
    }

    private static func rowsFromLegacyBlob(_ raw: String) -> [Recipient]? {
        guard !raw.isEmpty, let data = raw.data(using: .utf8),
              let legacy = try? JSONDecoder().decode([LegacyRecipient].self, from: data) else { return nil }
        return legacy.map(row(from:))
    }

    private static func row(from l: LegacyRecipient) -> Recipient {
        let r = Recipient(id: l.id, email: l.email, name: l.name, role: l.role,
                          provenance: RecipientProvenance(rawValue: l.provenanceRaw) ?? .act,
                          contactMethodRaw: l.contactMethodRaw, contactConfidenceRaw: l.contactConfidenceRaw,
                          contactFormURL: l.contactFormURL)
        r.sendStateRaw = l.sendStateRaw
        r.sentAt = l.sentAt
        r.gmailThreadId = l.gmailThreadId
        r.gmailMessageId = l.gmailMessageId
        r.sendError = l.sendError
        r.followUpCount = l.followUpCount
        r.lastFollowUpAt = l.lastFollowUpAt
        r.replied = l.replied
        r.repliedAt = l.repliedAt
        r.lastReplyId = l.lastReplyId
        r.dismissedReplyId = l.dismissedReplyId
        r.lastReplyText = l.lastReplyText
        r.bounced = l.bounced
        r.resolutionRaw = l.resolutionRaw
        return r
    }
}
