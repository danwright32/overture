import Foundation
import Observation

// #1597: the dates Dan has ticked for one multi-date reachability check, by date-group id. Session state,
// deliberately not persisted: a selection is a thing he is assembling right now, and one surviving a
// relaunch would be a spending decision made days ago and forgotten.
//
// #1774: an object rather than @State on QueueView. As @State, one tick invalidated the entire queue body,
// which re-derived all 724 prospects (QueueModel.items, AgentInputs.from, three StageNavigation sweeps) to
// draw a checkmark. Held here, a tick notifies only the two views that actually read it: the checkbox on
// the date heading and the selection bar. QueueView itself never reads it, which is what makes the tick
// free, and QueueInvalidationGuardTests pins that it stays that way.
@MainActor
@Observable
final class ProbeSelectionState {
    private(set) var dates: Set<String> = []

    func contains(_ groupID: String) -> Bool { dates.contains(groupID) }

    func toggle(_ groupID: String) {
        if dates.contains(groupID) { dates.remove(groupID) } else { dates.insert(groupID) }
    }

    func clear() { dates = [] }
}
