import Foundation

// The pure core of the OmniFocus sync (#176, Model A: one task per nudge). `desired` builds the set
// of tasks that should exist right now: only remotely-actionable reminders (a confirmed active state
// to chase, or a post-event closing note), whose next-reach-out is within a horizon, each carrying
// its due. `reconcile` diffs that against the existing Overture-tagged tasks. Keyed on naturalKey so
// the side-effecting client can find-or-create-or-complete idempotently. No OmniFocus dependency.
// Opt-in settings for the OmniFocus sync (#231). Off until Dan enables it. horizonDays sets how
// far ahead of a reminder's due day a task is created (best-effort: it only lands if Overture is
// opened in that window).
struct OmniFocusSyncConfig: Sendable {
    var enabled: Bool = false
    var horizonDays: Int = 14

    enum Keys {
        static let enabled = "omniFocusSyncEnabled"
        static let horizon = "omniFocusSyncHorizonDays"
    }
    static func loaded(from defaults: UserDefaults = .standard) -> OmniFocusSyncConfig {
        var c = OmniFocusSyncConfig()
        if defaults.object(forKey: Keys.enabled) != nil { c.enabled = defaults.bool(forKey: Keys.enabled) }
        let h = defaults.integer(forKey: Keys.horizon)
        if h > 0 { c.horizonDays = h }
        return c
    }
    func save(to defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: Keys.enabled)
        defaults.set(horizonDays, forKey: Keys.horizon)
    }
}

// The side-effecting boundary to OmniFocus, injected so the orchestrator is testable with a fake.
// The real implementation (AppleScriptOmniFocusClient) talks to OmniFocus; it is the one piece that
// can only be verified live, not unit-tested.
protocol OmniFocusClient {
    func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask]   // incomplete Overture-marked tasks
    func create(_ task: OmniFocusSync.DesiredTask) throws
    func complete(naturalKey: String) throws
}

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
            guard p.status != .dismissed else { return nil }   // #238: a no-go lead never nags via OmniFocus
            guard p.outcome != .booked, p.outcome != .lostSoft, p.outcome != .lostHard else { return nil }

            // A CONFIRMED (manual, active) conversation state is the normal follow-up: chase it on its
            // next reach-out date, if that falls within the horizon. A confirmed lead never triages.
            let hasConfirmedActiveState = (p.conversationState?.isActive ?? false) && p.conversationStateSource != .auto
            if hasConfirmedActiveState {
                guard let due = ConversationReminder.nextReminderDate(
                    state: p.conversationState, setAt: p.conversationStateSetAt,
                    remindedAt: p.conversationRemindedAt, performanceDate: p.performanceDate,
                    outcome: p.outcome, source: p.conversationStateSource, now: now, config: reminderConfig),
                    due <= cutoff
                else { return nil }
                let dueDate = easternTime(hour: dueHour, onDayOf: due)
                return DesiredTask(naturalKey: p.naturalKey, title: title(for: p),
                                   note: note(for: p, dueDate: dueDate),
                                   deferDate: easternTime(hour: deferHour, onDayOf: due),
                                   dueDate: dueDate)
            }

            // #271 / Phase 7: a reply Dan hasn't categorized (no confirmed active state) would otherwise
            // leave NO trace in OmniFocus while he's away — only an in-app badge he can't see. Emit a
            // triage task due today, keyed by the SAME naturalKey so reconcile dedupes it against the
            // follow-up once Dan confirms the state (the in-app badge and this task never compete: one
            // OmniFocus task per lead, and confirming the state re-anchors it via the due-day diff).
            if p.outcome == .replied {
                // Anchor the triage due to a STABLE date on the lead (when its state was last
                // touched, else when Dan first reached out), NOT `now` — otherwise the day-token diff
                // would complete+recreate the task on every new calendar day until Dan triages it.
                let anchor = p.conversationStateSetAt ?? p.sentAt ?? now
                let dueDate = easternTime(hour: dueHour, onDayOf: anchor)
                return DesiredTask(naturalKey: p.naturalKey, title: triageTitle(for: p),
                                   note: note(for: p, dueDate: dueDate),
                                   deferDate: easternTime(hour: deferHour, onDayOf: anchor),
                                   dueDate: dueDate)
            }
            return nil
        }
    }

    // The Eastern day token written into the task note as paragraph 2, read back verbatim by the
    // client (avoids reading date components out of AppleScript, which is unreliable).
    static let dueNotePrefix = "Due: "

    // Read what OmniFocus holds, diff against what should exist, then create/complete via the client.
    // Each step is independent so a single failed Apple event doesn't abort the rest of the sync.
    static func run(prospects: [Prospect], now: Date, client: OmniFocusClient, horizonDays: Int = 14,
                    reminderConfig: ConversationReminderConfig = .init()) throws {
        try apply(desired: desired(from: prospects, now: now, horizonDays: horizonDays,
                                   reminderConfig: reminderConfig), client: client)
    }

    // The OmniFocus I/O half, over value types only, so it can run off the main actor while the
    // prospect read (desired) stays on it. Each step is independent: a failed Apple event on one
    // task doesn't abort the rest.
    @discardableResult
    static func apply(desired: [DesiredTask], client: OmniFocusClient) throws -> (existing: Int, created: Int, completed: Int) {
        let existing = try client.existingOvertureTasks()
        let plan = reconcile(desired: desired, existing: existing)
        for task in plan.toCreate { try client.create(task) }
        for task in plan.toComplete { try client.complete(naturalKey: task.naturalKey) }
        return (existing.count, plan.toCreate.count, plan.toComplete.count)
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

    // #271: an uncategorized reply needs Dan to read it and set the conversation state in Overture.
    private static func triageTitle(for p: Prospect) -> String {
        "Triage reply from \(p.groupName)"
    }

    // Note layout is load-bearing: paragraph 1 is the lead key, paragraph 2 is the due day. The
    // client reads those two lines back verbatim, so their order must not change.
    static let notePrefix = "Overture lead: "
    private static func note(for p: Prospect, dueDate: Date) -> String {
        var parts = ["\(notePrefix)\(p.naturalKey)", "\(dueNotePrefix)\(EasternDate.dayString(from: dueDate))"]
        if let v = p.venue, !v.isEmpty { parts.append("Venue: \(v)") }
        if let d = p.performanceDate, !d.isEmpty { parts.append("Performance: \(d)") }
        // #231 / #307: a clickable link back to Overture, built by the single OvertureDeepLink builder
        // (the same one the app's URL handler parses), so the embedded link can't drift from the parser.
        if let link = OvertureDeepLink.leadURL(forKey: p.naturalKey)?.absoluteString {
            parts.append("Open in Overture: \(link)")
        }
        return parts.joined(separator: "\n")
    }
}
