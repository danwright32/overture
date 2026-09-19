import Foundation
import SwiftData

// #3325, plan 3.6: the picker's choices reach the store BEFORE the run starts, in this order, and a save
// that fails aborts the launch.
//
// 1. Every row is looked up by its key and every decision is checked by the one writer
//    (`Prospect.recordNightDecisions`), which refuses a night the run no longer plays. A scout can run
//    while the sheet is open, so a night the sheet offered can be gone by the press.
// 2. One save. If it fails, nothing launches: a run prepped on decisions that were never recorded would
//    draft for nights the store does not say he chose.
// 3. The keys handed to the launch are re-read from the rows, never from the sheet's selection (plan 3.2).
//    The picker never re-keys a row, so today they are the same keys; reading them back is what keeps that
//    true if it ever does.
//
// Plan 3.5's four stored refusal causes all came from routing a skip through a card dismissal (`.cannotCheck`,
// a key another card holds, an in-batch collision). The picker does not dismiss, so none can arise here.
// What remains is a row whose nights moved under the sheet, which clears by construction on the next open
// (the sheet is rebuilt from the store), and a failed save, which aborts the whole launch and says so. Neither
// outlives the attempt, so neither needs a stored cause (L11: each gets its own words).
@MainActor
enum PrepNightCommitting {

    struct Outcome: Equatable {
        var launchKeys: Set<String>
        var leftOut: [String]   // group names, for the sentence Dan reads
    }

    struct SaveFailed: Error, LocalizedError {
        let underlying: String
        var errorDescription: String? { "Prep did not start: the nights you chose could not be saved. \(underlying)" }
    }

    static func apply(_ choice: PrepSelectionSheet.Choice, in context: ModelContext,
                      save: (ModelContext) throws -> Void = { try $0.save() }) throws -> Outcome {
        var launching: [Prospect] = []
        var leftOut: [String] = []
        for key in choice.keys.sorted() {
            guard let p = try Prospect.stored(key: key, in: context) else { continue }
            if let commit = choice.commits[key] {
                do {
                    try p.recordNightDecisions(pitched: commit.pitched, skipped: commit.skipped)
                } catch is Prospect.NightDecisionRefusal {
                    leftOut.append(p.groupName)
                    continue
                }
            }
            launching.append(p)
        }
        do {
            try save(context)
        } catch {
            context.rollback()
            throw SaveFailed(underlying: error.localizedDescription)
        }
        return Outcome(launchKeys: Set(launching.map(\.naturalKey)), leftOut: leftOut)
    }
}
