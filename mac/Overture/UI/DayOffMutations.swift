import Foundation
import SwiftData

// #1417: removing a blocked range, moved out of DaysOffView so it is testable (#863) and so its
// confirmation is gated on the write actually landing, like every other acknowledgment.
//
// This one matters more than most: a day off that reads as removed but is still on disk keeps every
// show on those nights flagged, so Overture goes on holding back drafts for a night Dan believes he
// freed up. The BLOCKING half lives in ProspectMutations.blockDaysOff (shared with the dismiss-to-day-off
// offer) and is gated the same way.
@MainActor
enum DayOffMutations {
    // The sheet's own "Block some days" form. It says nothing on success: the form closing and the range
    // appearing in the list IS the confirmation, which is the same claim a banner makes and just as wrong
    // over a failed write. `.notSaved` leaves the form open holding the range Dan typed, with the save
    // warning on the banner. (The single-tap dismiss offer and the picker confirm go through
    // ProspectMutations.blockDaysOff, which is gated the same way and does post a banner.)
    enum AddOutcome: Equatable {
        // The refused reason is optional because DayOffEditing.message owns the wording and is entitled
        // to have none. Carrying its nil through, rather than substituting an empty string here, keeps
        // this from ever putting a blank line under the form where a reason should be.
        case added
        case refused(String?)
        case notSaved
    }

    static func add(start: String, end: String, note: String?,
                    export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                    context: ModelContext, feedback: ActionFeedback) -> AddOutcome {
        let result = DayOffEditing.add(start: start, end: end, note: note, export: export, into: context)
        // Every refusal SAYS something. A form that silently declines to add the range Dan just typed
        // looks exactly like a bug, and he would try again rather than fix the range.
        guard result == .added else { return .refused(DayOffEditing.message(for: result)) }
        let range = QueueModel.runDateLabel(start: start, end: end)
        return context.saveOrWarn(org: range, feedback: feedback) ? .added : .notSaved
    }

    // Removing is reversible from the banner it happened in (#845): a mis-clicked Remove otherwise means
    // retyping the range, and the row Dan just deleted is the one thing he can no longer read it off.
    // The Undo sweeps against the SAME export this removal did, rather than re-reading the calendar and
    // possibly judging against different bookings than the removal saw.
    static func remove(_ row: DayOff, export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                       context: ModelContext, feedback: ActionFeedback) {
        let (start, end, note) = (row.startDate, row.endDate, row.note)
        let range = QueueModel.runDateLabel(start: start, end: end)
        DayOffEditing.remove(row, export: export, in: context)
        guard context.saveOrWarn(org: range, feedback: feedback) else { return }
        feedback.acknowledge(ActionAck.dayOffRemoved(range: range),
                             action: .init(label: "Undo") {
                                 DayOffEditing.add(start: start, end: end, note: note,
                                                   export: export, into: context)
                                 context.saveOrWarn(org: range, feedback: feedback)
                             })
    }
}
