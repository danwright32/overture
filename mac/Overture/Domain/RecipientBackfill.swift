import Foundation
import SwiftData

enum RecipientBackfill {
    // #418 A1 (#416 repair): a performance contacted through the OLD lead-level send path has its
    // sentAt/gmailThreadId on the Prospect but its act recipient row carries no thread (sendState still
    // .pending), so per-recipient detection has nothing to watch. Copy the lead sentAt/gmailThreadId/
    // gmailMessageId down to the act recipient(s) and flip them to .sent. Guarded and idempotent:
    //   - only legacy shows (lead has sentAt + thread) are considered;
    //   - a show where ANY recipient already carries a thread is skipped (a #415-era send already
    //     stamped per-recipient state, so its genuinely-pending recipients must NOT be touched);
    //   - only `.act` recipients lacking a thread are repaired (a manually-added presenter that was
    //     never sent stays .pending).
    // Run once at launch. Returns how many recipient rows were repaired (0..N).
    @discardableResult
    static func repairThreadDown(in context: ModelContext) -> Int {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var repaired = 0
        for p in prospects {
            guard p.sentAt != nil, let leadThread = p.gmailThreadId, !leadThread.isEmpty else { continue }
            if p.recipients.contains(where: { $0.gmailThreadId != nil }) { continue }
            // #2717: and never onto a form or DM contact. A thread here is a conversation, and since
            // #2715 the only conversation such a contact may hold is one Dan ATTACHED by hand. Handing it
            // the lead's thread instead would give it one nobody linked, and the card would then tell him
            // Overture is watching a conversation he never chose.
            //
            // The outer guard already makes this unreachable today, since it needs a lead-level
            // `gmailThreadId` and `recordFormOutreach` deliberately never writes one, so this is the rule
            // stated where it belongs rather than left resting on a fact two functions away (L30).
            for r in p.recipients where r.provenance == .act && r.gmailThreadId == nil
                && r.outreachChannel != .contactForm {
                r.gmailThreadId = leadThread
                r.gmailMessageId = p.gmailMessageId
                r.sentAt = p.sentAt
                r.sendState = .sent
                repaired += 1
            }
        }
        return repaired
    }
}
