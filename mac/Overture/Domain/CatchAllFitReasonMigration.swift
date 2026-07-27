import Foundation
import SwiftData

// #1600 (milestone 32 Phase 7.1): clear the classifier's retired catch-all fit reason off the rows that
// already carry it.
//
// EventClassifier no longer emits the sentence, but `fitReason` is STORED and only rewritten when the
// hash-gated scout re-emits a row. Changing the classifier alone would therefore leave the line sitting
// on an arbitrary, slowly shrinking subset of the queue for weeks, which is the worst of both: Dan sees
// it on some cards and not others, with nothing to explain the difference.
//
// All 499 rows, including the 85 already dismissed (Dan's decision, 2026-07-26): the sentence is equally
// uninformative on a dismissed row, and two kinds of card in the Archive is an inconsistency nobody
// would remember the reason for.
//
// Idempotent, guarded by "still carries the retired string", so a second pass is a no-op and no run-once
// flag is needed. Returns how many rows it changed.
enum CatchAllFitReasonMigration {
    // copy-inventory:ignore-start  the retired sentence, named only so this pass can find and clear it
    static let retired = "Unclear producer; needs a closer look before pitching."
    // copy-inventory:ignore-end

    @discardableResult
    static func run(in context: ModelContext) -> Int {
        let prospects = (try? context.fetch(FetchDescriptor<Prospect>())) ?? []
        var changed = 0
        for p in prospects where p.fitReason == retired {
            p.fitReason = ""
            changed += 1
        }
        return changed
    }
}
