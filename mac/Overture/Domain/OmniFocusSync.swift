import Foundation

// The pure core of the OmniFocus sync (#176, Model A: one task per nudge). `desired` builds the set
// of tasks that should exist right now: only remotely-actionable reminders (a confirmed active state
// to chase, or a post-event closing note), whose next-reach-out is within a horizon, each carrying
// its due. `reconcile` diffs that against the existing Overture-tagged tasks. Keyed on naturalKey so
// the side-effecting client can find-or-create-or-complete idempotently. No OmniFocus dependency.
enum OmniFocusSync {
    struct DesiredTask: Equatable, Sendable {
        let naturalKey: String
        let title: String
        let note: String
        let deferDate: Date   // 11am Eastern on the due day: when the task surfaces
        let dueDate: Date     // 6pm Eastern on the due day: the deadline
    }

    struct ExistingTask: Equatable, Sendable {
        let naturalKey: String
        let dueDate: Date
    }

    // Defer/due clock times on the reminder's due day, in Eastern (Overture's canonical timezone).
    static let deferHour = 11
    static let dueHour = 18

    // A specific clock hour on the Eastern calendar day of `date`.
    private static func easternTime(hour: Int, onDayOf date: Date) -> Date {
        let cal = EasternDate.calendar
        var comps = cal.dateComponents([.year, .month, .day], from: date)
        comps.hour = hour
        comps.minute = 0
        comps.second = 0
        return cal.date(from: comps) ?? date
    }

    struct Plan: Equatable, Sendable {
        var toCreate: [DesiredTask]
        var toComplete: [ExistingTask]
    }

    // Tasks that should exist now: a confirmed (manual) active conversation state to chase, or a
    // closing note after the event, whose next-reach-out date falls within the horizon. Excludes
    // unconfirmed AI suggestions and replied-but-uncategorized leads (those need Dan IN Overture),
    // and anything booked/lost. The due is the OmniFocus defer date so the task stays hidden until due.
    static func desired(from prospects: [Prospect], now: Date, horizonDays: Int,
                        reminderConfig: ConversationReminderConfig = .init()) -> [DesiredTask] {
        let cutoff = now.addingTimeInterval(TimeInterval(horizonDays) * 86_400)
        return prospects.compactMap { p in
            guard p.outcome != .booked, p.outcome != .lostSoft, p.outcome != .lostHard else { return nil }
            guard let state = p.conversationState, state.isActive else { return nil }   // no state -> needsState, in-app only
            guard p.conversationStateSource != .auto else { return nil }                // unconfirmed AI guess, in-app only
            guard let due = ConversationReminder.nextReminderDate(
                state: p.conversationState, setAt: p.conversationStateSetAt,
                remindedAt: p.conversationRemindedAt, performanceDate: p.performanceDate,
                outcome: p.outcome, source: p.conversationStateSource, now: now, config: reminderConfig)
            else { return nil }
            guard due <= cutoff else { return nil }
            return DesiredTask(naturalKey: p.naturalKey, title: title(for: p), note: note(for: p),
                               deferDate: easternTime(hour: deferHour, onDayOf: due),
                               dueDate: easternTime(hour: dueHour, onDayOf: due))
        }
    }

    // Diff the desired set against what OmniFocus currently holds (by naturalKey). Complete any
    // existing task whose lead is no longer desired (resolved) OR whose due no longer matches the
    // lead's current due (Model A: the nudge re-anchored it, so that task is stale). Create any
    // desired task with no matching existing task at the right due.
    static func reconcile(desired: [DesiredTask], existing: [ExistingTask]) -> Plan {
        let desiredByKey = Dictionary(desired.map { ($0.naturalKey, $0) }, uniquingKeysWith: { a, _ in a })
        let toComplete = existing.filter { e in
            guard let d = desiredByKey[e.naturalKey] else { return true }   // lead resolved / no longer desired
            return d.dueDate != e.dueDate                                  // stale due (re-anchored)
        }
        let liveByKey = Dictionary(
            existing.filter { e in desiredByKey[e.naturalKey]?.dueDate == e.dueDate }.map { ($0.naturalKey, $0) },
            uniquingKeysWith: { a, _ in a })
        let toCreate = desired.filter { liveByKey[$0.naturalKey] == nil }
        return Plan(toCreate: toCreate, toComplete: toComplete)
    }

    private static func title(for p: Prospect) -> String {
        "Follow up with \(p.groupName)"
    }

    private static func note(for p: Prospect) -> String {
        var parts = ["Overture lead: \(p.naturalKey)"]
        if let v = p.venue, !v.isEmpty { parts.append("Venue: \(v)") }
        if let d = p.performanceDate, !d.isEmpty { parts.append("Performance: \(d)") }
        return parts.joined(separator: "\n")
    }
}
