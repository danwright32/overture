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
            for r in p.recipients where r.provenance == .act && r.gmailThreadId == nil {
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
