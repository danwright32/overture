import Foundation
import SwiftData

// #3620: adding, removing and freeing a date from a weekly block, as the sheet performs them: each says what
// it did only once the write has landed, and each removal is reversible from the banner it happened in,
// exactly as `DayOffMutations` does for a range (#1417, #845). The rules themselves live in
// `WeeklyDayOffEditing`; this is the acknowledgement around them.
@MainActor
enum WeeklyDayOffMutations {

    static func add(weekday: Int, firstDate: String?, lastDate: String?, note: String?,
                    export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                    context: ModelContext, feedback: ActionFeedback) -> DayOffMutations.AddOutcome {
        let result = WeeklyDayOffEditing.add(weekday: weekday, firstDate: firstDate, lastDate: lastDate,
                                             note: note, export: export, into: context)
        guard result == .added else { return .refused(WeeklyDayOffEditing.message(for: result)) }
        let label = WeeklyDayOffEditing.label(weekday: weekday, firstDate: firstDate, lastDate: lastDate)
        return context.saveOrWarn(org: label, feedback: feedback) ? .added : .notSaved
    }

    // The Undo puts back the WHOLE rule, freed dates included: a rule restored without them would block the
    // weeks Dan had freed, which is a change he never made.
    static func remove(_ rule: WeeklyDayOff, export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                       context: ModelContext, feedback: ActionFeedback) {
        let (weekday, first, last, note, freed) = (rule.weekday, rule.firstDate, rule.lastDate, rule.note,
                                                   rule.freedDates)
        let label = WeeklyDayOffEditing.label(weekday: weekday, firstDate: first, lastDate: last)
        WeeklyDayOffEditing.remove(rule, export: export, in: context)
        guard context.saveOrWarn(org: label, feedback: feedback) else { return }
        feedback.acknowledge(ActionAck.dayOffRemoved(range: label),
                             action: .init(label: "Undo") {
                                 WeeklyDayOffEditing.add(weekday: weekday, firstDate: first, lastDate: last,
                                                         note: note, freedDates: freed,
                                                         export: export, into: context)
                                 context.saveOrWarn(org: label, feedback: feedback)
                             })
    }

    enum FreeOutcome: Equatable {
        case freed
        case refused(String)
        case notSaved
    }

    static func free(_ date: String, from rule: WeeklyDayOff,
                     export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                     context: ModelContext, feedback: ActionFeedback) -> FreeOutcome {
        let day = EasternDate.dayLabel(date) ?? date
        guard WeeklyDayOffEditing.free(date, from: rule, export: export, in: context) == .freed else {
            return .refused(WeeklyDayOffEditing.freeRefusal(date: date, weekday: rule.weekday))
        }
        guard context.saveOrWarn(org: day, feedback: feedback) else { return .notSaved }
        feedback.acknowledge(ActionAck.dayOffRemoved(range: day),
                             action: .init(label: "Undo") {
                                 WeeklyDayOffEditing.reblock(date, on: rule, export: export, in: context)
                                 context.saveOrWarn(org: day, feedback: feedback)
                             })
        return .freed
    }

    static func reblock(_ date: String, on rule: WeeklyDayOff,
                        export: DayOffEditing.Export = DownbeatBridge.loadedExport(),
                        context: ModelContext, feedback: ActionFeedback) {
        let day = EasternDate.dayLabel(date) ?? date
        WeeklyDayOffEditing.reblock(date, on: rule, export: export, in: context)
        guard context.saveOrWarn(org: day, feedback: feedback) else { return }
        feedback.acknowledge(ActionAck.dayOffBlocked(range: day))
    }
}
