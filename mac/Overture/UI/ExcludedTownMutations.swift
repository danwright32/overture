import Foundation
import SwiftData

// #1417: the skip-list actions that SAY something to Dan, moved out of ExcludedTownsView so each is a
// plain function a test can call (#863). Same rule as WatchlistMutations: the success line is posted
// only after the change is confirmed on disk, because ExcludedTownEditing persists with a bare
// `try? context.save()` whose failure went nowhere.
//
// Each action's Undo is its mirror action, so the way back is the same code path as the way there and
// a failed Undo warns exactly like a failed action (#845).
@MainActor
enum ExcludedTownMutations {
    // #1221: un-skip a built-in seed town, reversible from the banner it happened in (#845).
    static func allow(_ town: String, context: ModelContext, feedback: ActionFeedback) {
        let shown = ExcludedTownEditing.displayName(town)
        ExcludedTownEditing.allowSeedTown(town, into: context)
        guard context.saveOrWarn(org: shown, feedback: feedback) else { return }
        feedback.acknowledge(ActionAck.townUnexcluded(town: shown),
                             action: .init(label: "Undo") {
                                 reskip(town, context: context, feedback: feedback)
                             })
    }

    // The way back the other direction: re-skip a built-in town, Undo re-allows it.
    static func reskip(_ town: String, context: ModelContext, feedback: ActionFeedback) {
        let shown = ExcludedTownEditing.displayName(town)
        ExcludedTownEditing.reskipSeedTown(town, in: context)
        guard context.saveOrWarn(org: shown, feedback: feedback) else { return }
        feedback.acknowledge(ActionAck.townExcluded(town: shown),
                             action: .init(label: "Undo") {
                                 allow(town, context: context, feedback: feedback)
                             })
    }

    // Reversible from the banner it happened in (#845): a mis-clicked Remove otherwise means retyping the
    // town, and the row Dan just deleted is the one place he could have read it off. The Undo re-excludes
    // exactly what was removed.
    static func remove(_ town: String, context: ModelContext, feedback: ActionFeedback) {
        let shown = ExcludedTownEditing.displayName(town)
        ExcludedTownEditing.remove(town: town, in: context)
        guard context.saveOrWarn(org: shown, feedback: feedback) else { return }
        feedback.acknowledge(ActionAck.townUnexcluded(town: shown),
                             action: .init(label: "Undo") {
                                 ExcludedTownEditing.exclude(town: town, into: context)
                                 context.saveOrWarn(org: shown, feedback: feedback)
                             })
    }
}
