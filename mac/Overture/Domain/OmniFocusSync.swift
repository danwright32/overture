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
    func complete(naturalKey: String, recipientId: String) throws
}

enum OmniFocusSync {
    // #653: one task per (show, recipient), not per show, so a multi-contact show can have one
    // contact's follow-up due while another's isn't.
    struct DesiredTask: Equatable, Sendable {
        let naturalKey: String
        let recipientId: String
        let title: String
        let note: String
        let deferDate: Date   // 11am Eastern on the due day: when the task surfaces
        let dueDate: Date     // 6pm Eastern on the due day: the deadline
    }

    struct ExistingTask: Equatable, Sendable {
        let naturalKey: String
        let recipientId: String
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

    // Tasks that should exist now, one per RECIPIENT (#653): a confirmed (manual) active conversation
    // state to chase, or a closing note after the event, whose next-reach-out date falls within the
    // horizon. Excludes unconfirmed AI suggestions and replied-but-uncategorized contacts (those need
    // Dan IN Overture), and anything booked/lost. The due is the OmniFocus defer date so the task
    // stays hidden until due.
    static func desired(from prospects: [Prospect], now: Date, horizonDays: Int,
                        reminderConfig: ConversationReminderConfig = .init()) -> [DesiredTask] {
        let cutoff = now.addingTimeInterval(TimeInterval(horizonDays) * 86_400)
        var tasks: [DesiredTask] = []
        for p in prospects {
            guard p.status != .dismissed else { continue }   // #238: a no-go lead never nags via OmniFocus
            for r in p.recipients {
                let standing = r.standing
                let unhandledReply = r.hasUnhandledReply && r.conversationStateSource != .manual
                // A closed contact drops out, UNLESS a fresh reply still needs triage (a late reply on
                // an otherwise-closed contact still deserves a task, #424).
                guard standing.isInPlay || unhandledReply else { continue }

                // A CONFIRMED (manual, active) conversation state is the normal follow-up: chase it on
                // its next reach-out date, if that falls within the horizon. A confirmed contact never
                // triages.
                let hasConfirmedActiveState = (r.conversationState?.isActive ?? false) && r.conversationStateSource != .auto
                if hasConfirmedActiveState {
                    guard let due = ConversationReminder.nextReminderDate(
                        state: r.conversationState, setAt: r.conversationStateSetAt,
                        remindedAt: r.conversationRemindedAt, performanceDate: p.performanceDate,
                        isClosed: !standing.isInPlay, hasUnhandledReply: unhandledReply,
                        source: r.conversationStateSource, now: now, config: reminderConfig),
                        due <= cutoff
                    else { continue }
                    let dueDate = easternTime(hour: dueHour, onDayOf: due)
                    tasks.append(DesiredTask(naturalKey: p.naturalKey, recipientId: r.id, title: title(for: p, r),
                                             note: note(for: p, r, dueDate: dueDate),
                                             deferDate: easternTime(hour: deferHour, onDayOf: due),
                                             dueDate: dueDate))
                    continue
                }

                // #271 / Phase 7: a reply Dan hasn't categorized (no confirmed active state) would
                // otherwise leave NO trace in OmniFocus while he's away; only an in-app badge he can't
                // see. Emit a triage task due today, keyed by the SAME (naturalKey, recipientId) so
                // reconcile dedupes it against the follow-up once Dan confirms the state (the in-app
                // badge and this task never compete: one OmniFocus task per contact, and confirming the
                // state re-anchors it via the due-day diff).
                if unhandledReply {
                    // Anchor the triage due to a STABLE date on the recipient (when its state was last
                    // touched, else when Dan first reached out), NOT `now`; otherwise the day-token diff
                    // would complete+recreate the task on every new calendar day until Dan triages it.
                    let anchor = r.conversationStateSetAt ?? r.sentAt ?? now
                    let dueDate = easternTime(hour: dueHour, onDayOf: anchor)
                    tasks.append(DesiredTask(naturalKey: p.naturalKey, recipientId: r.id, title: triageTitle(for: p, r),
                                             note: note(for: p, r, dueDate: dueDate),
                                             deferDate: easternTime(hour: deferHour, onDayOf: anchor),
                                             dueDate: dueDate))
                }
            }
        }
        return tasks
    }

    // The Eastern day token written into the task note, read back verbatim by the client (avoids
    // reading date components out of AppleScript, which is unreliable).
    static let dueNotePrefix = "Due: "

    // Read what OmniFocus holds, diff against what should exist, then create/complete via the client.
    // Each step is independent so a single failed Apple event doesn't abort the rest of the sync.
    static func run(prospects: [Prospect], now: Date, client: OmniFocusClient, horizonDays: Int = 14,
                    reminderConfig: ConversationReminderConfig = .init()) throws {
        try apply(desired: desired(from: prospects, now: now, horizonDays: horizonDays,
                                   reminderConfig: reminderConfig), client: client)
    }

    // #885: the receipt Dan sees after a sync HE asked for, out of RootView's body. Four counts that
    // must add up to what actually happened, which is exactly the kind of claim worth a test.
    static func receipt(due: Int, existing: Int, created: Int, completed: Int) -> String {
        "OmniFocus: \(due) due · existing \(existing) · created \(created) · completed \(completed)"
    }

    // The OmniFocus I/O half, over value types only, so it can run off the main actor while the
    // prospect read (desired) stays on it. Each step is independent: a failed Apple event on one
    // task doesn't abort the rest.
    @discardableResult
    static func apply(desired: [DesiredTask], client: OmniFocusClient) throws -> (existing: Int, created: Int, completed: Int) {
        let existing = try client.existingOvertureTasks()
        let plan = reconcile(desired: desired, existing: existing)
        for task in plan.toCreate { try client.create(task) }
        for task in plan.toComplete { try client.complete(naturalKey: task.naturalKey, recipientId: task.recipientId) }
        return (existing.count, plan.toCreate.count, plan.toComplete.count)
    }

    // Diff the desired set against what OmniFocus currently holds (by naturalKey + recipientId, #653:
    // two contacts on one show are distinct tasks). Complete any existing task whose contact is no
    // longer desired (resolved) OR whose due no longer matches the contact's current due (Model A: the
    // nudge re-anchored it, so that task is stale). Create any desired task with no matching existing
    // task at the right due.
    private struct TaskKey: Hashable { let naturalKey: String; let recipientId: String }
    static func reconcile(desired: [DesiredTask], existing: [ExistingTask]) -> Plan {
        func key(_ naturalKey: String, _ recipientId: String) -> TaskKey { TaskKey(naturalKey: naturalKey, recipientId: recipientId) }
        let desiredByKey = Dictionary(desired.map { (key($0.naturalKey, $0.recipientId), $0) }, uniquingKeysWith: { a, _ in a })
        let toComplete = existing.filter { e in
            guard let d = desiredByKey[key(e.naturalKey, e.recipientId)] else { return true }   // resolved / no longer desired
            return d.dueDate != e.dueDate                                                       // stale due (re-anchored)
        }
        let liveByKey = Dictionary(
            existing.filter { e in desiredByKey[key(e.naturalKey, e.recipientId)]?.dueDate == e.dueDate }
                .map { (key($0.naturalKey, $0.recipientId), $0) },
            uniquingKeysWith: { a, _ in a })
        let toCreate = desired.filter { liveByKey[key($0.naturalKey, $0.recipientId)] == nil }
        return Plan(toCreate: toCreate, toComplete: toComplete)
    }

    private static func displayName(_ r: Recipient) -> String {
        if let name = r.name, !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return r.email ?? "the contact"
    }

    // #653 (Dan's requirement): every task title carries both the show and the specific contact.
    private static func title(for p: Prospect, _ r: Recipient) -> String {
        "\(p.groupName), follow up with \(displayName(r))"
    }

    // #271: an uncategorized reply needs Dan to read it and set the conversation state in Overture.
    private static func triageTitle(for p: Prospect, _ r: Recipient) -> String {
        "\(p.groupName), reply to \(displayName(r))"
    }

    // Note layout is load-bearing: paragraph 1 is the lead key, paragraph 2 is the recipient id
    // (#653), paragraph 3 is the due day. The client reads those lines back verbatim, so their order
    // must not change.
    static let notePrefix = "Overture lead: "
    static let contactNotePrefix = "Overture contact: "
    private static func note(for p: Prospect, _ r: Recipient, dueDate: Date) -> String {
        var parts = ["\(notePrefix)\(p.naturalKey)", "\(contactNotePrefix)\(r.id)",
                     "\(dueNotePrefix)\(EasternDate.dayString(from: dueDate))"]
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
