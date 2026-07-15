import Foundation
import SwiftData

// #940: 'Day doesn't work' (`day_doesnt_work`) is folded into 'Date conflict' (`date_conflict`): the two
// were near-duplicates and, since #924, did exactly the same thing. A one-shot, idempotent launch pass
// rewrites any prospect Dan already dismissed with the old reason, so the Archive never shows a reason
// string that no longer decodes to a DismissReason. Idempotent: guarded by "still carries the old raw
// value", so a second pass is a no-op and no run-once flag is needed. Returns how many it changed.
enum DismissReasonMigration {
    private static let old = "day_doesnt_work"
    private static let replacement = DismissReason.dateConflict.rawValue

    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var changed = 0
        for p in prospects where p.dismissReasonRaw == old {
            p.dismissReasonRaw = replacement
            changed += 1
        }
        return changed
    }
}
