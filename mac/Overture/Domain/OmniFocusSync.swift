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
    // #2899: and the COMPLETED ones. A task Dan ticked off and a task that was never created are the same
    // state to a sync that reads only what is open, and it resolved that ambiguity by creating, every
    // pass, for ever. The one act he performs in the tool the reminders live in was the one act Overture
    // could not learn from (L162).
    func completedOvertureTasks() throws -> [OmniFocusSync.ExistingTask]
    func create(_ task: OmniFocusSync.DesiredTask) throws
    // #2885: takes the whole ExistingTask, so the instruction is addressed by the same three things
    // reconcile decided over (naturalKey, recipientId, dueDate). Taking the first two named every
    // open task for that show and contact, which is a family where the decision named one member.
    // Not a defaulted due date, deliberately: a caller that forgot one would silently go back to
    // completing the family, and the compiler is the only thing that can refuse that (L168).
    func complete(_ task: OmniFocusSync.ExistingTask) throws
}

enum OmniFocusSync {
    // #653: one task per (show, recipient), not per show, so a multi-contact show can have one
    // contact's follow-up due while another's isn't.
    struct DesiredTask: Equatable, Sendable {
        // #2899: WHY this task exists, because completing it means a different thing for each and the
        // instruction Dan gave by ticking it off can only be honoured against the right one. Not
        // defaulted: a caller that has not decided which kind it is emitting cannot compile, and a
        // wrong default here would silently stamp a reply as answered off the back of a close-out
        // reminder (L168).
        enum Kind: String, Equatable, Sendable {
            case postEventPrompt   // record how this show ended. Only Dan holds that fact.
            case replyTriage       // somebody wrote and nobody has answered them.
        }
        let kind: Kind
        let naturalKey: String
        let recipientId: String
        let title: String
        let note: String
        let deferDate: Date   // 11am Eastern on the due day: when the task surfaces
        let dueDate: Date     // 6pm Eastern on the due day: the deadline
    }

    struct ExistingTask: Equatable, Hashable, Sendable {
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
        // #2899: the desired tasks Dan has already ticked off in OmniFocus. Not an OmniFocus instruction
        // (there is nothing left to do there), but a signal to carry back into the model, which is what
        // `recordCompletions` does. Named separately from `toCreate` rather than merely subtracted from
        // it, because a signal read and then dropped is worse than one never read: the task stops coming
        // back and nothing in Overture has moved (L46, L90).
        var handled: [DesiredTask] = []
    }

    // Tasks that should exist now, one per RECIPIENT (#653). #2397: two things earn one, and the
    // conversation-state chase is no longer either of them, because the states it chased are retired.
    //
    //   - A post-event prompt (PostEventPrompt): a closing note to send, or a show to close out.
    //   - A reply Dan has not answered, which would otherwise leave no trace in OmniFocus while he is
    //     away from his desk (#271): only an in-app badge he cannot see.
    //
    // The due is the OmniFocus defer date, so the task stays hidden until due.
    static func desired(from prospects: [Prospect], now: Date, horizonDays: Int) -> [DesiredTask] {
        let cutoff = now.addingTimeInterval(TimeInterval(horizonDays) * 86_400)
        var tasks: [DesiredTask] = []
        for p in prospects {
            guard p.status != .dismissed else { continue }   // #238: a no-go lead never nags via OmniFocus
            // #2033: one task per EMAIL. These land in an app Dan reads away from his desk, so a
            // duplicate is a chore he has to tidy up somewhere he cannot see why there are two.
            //
            // #2126: earned FIRST, collapsed after. Filtering by lowest id up front meant a contact who had
            // declined kept the group's only slot forever, so a colleague on the same email who genuinely
            // owed a task never got one, away from his desk where he would never notice the absence.
            var earned: [(recipient: Recipient, task: DesiredTask)] = []
            for r in p.recipients {
                let standing = r.standing
                let unhandledReply = r.hasUnhandledReply
                // A closed contact drops out, UNLESS a fresh reply still needs triage (a late reply on
                // an otherwise-closed contact still deserves a task, #424).
                guard standing.isInPlay || unhandledReply else { continue }

                // The post-event prompt, on its own date, if that falls within the horizon.
                //
                // #2646: `nextPromptDate` now names a date that has not arrived yet instead of staying
                // silent until it does, so this site asks the DUE question explicitly rather than reading
                // nil as "not yet". Behaviour here is deliberately unchanged, and that reveals something
                // worth naming: the branch only ever fired on an already-due prompt, so `due <= cutoff`
                // has never once excluded anything (a past date is always inside a future cutoff), and
                // the horizon this comment describes has never applied. Left in place rather than quietly
                // dropped, because making it real is a change with a consequence: a prompt coming due next
                // week would take this contact's single task slot away from a reply needing triage today,
                // via the `continue` below. That is its own issue (#2663), not a side effect of this one.
                if let due = PostEventPrompt.nextPromptDate(for: r, of: p),
                   PostEventPrompt.prompt(for: r, of: p, now: now) != nil, due <= cutoff {
                    let dueDate = easternTime(hour: dueHour, onDayOf: due)
                    earned.append((r, DesiredTask(kind: .postEventPrompt, naturalKey: p.naturalKey, recipientId: r.id, title: title(for: p, r),
                                                  note: note(for: p, r, dueDate: dueDate),
                                                  deferDate: easternTime(hour: deferHour, onDayOf: due),
                                                  dueDate: dueDate)))
                    continue
                }

                // #271: a reply Dan has not answered. Emit a triage task, keyed by the SAME
                // (naturalKey, recipientId) so reconcile dedupes it against the prompt above.
                if unhandledReply {
                    // Anchored to a STABLE date on the recipient (when the reply arrived, else when Dan
                    // first reached out), NOT `now`; otherwise the day-token diff would complete and
                    // recreate the task on every new calendar day until he answers.
                    let anchor = r.replyArrivedAt ?? r.sentAt ?? now
                    let dueDate = easternTime(hour: dueHour, onDayOf: anchor)
                    earned.append((r, DesiredTask(kind: .replyTriage, naturalKey: p.naturalKey, recipientId: r.id, title: triageTitle(for: p, r),
                                                  note: note(for: p, r, dueDate: dueDate),
                                                  deferDate: easternTime(hour: deferHour, onDayOf: anchor),
                                                  dueDate: dueDate)))
                }
            }
            tasks.append(contentsOf: SendGroup.oneRowPerGroup(earned) { $0.recipient }.map(\.task))
        }
        return tasks
    }

    // The Eastern day token written into the task note, read back verbatim by the client (avoids
    // reading date components out of AppleScript, which is unreliable).
    static let dueNotePrefix = "Due: "

    // Read what OmniFocus holds, diff against what should exist, then create/complete via the client.
    // Each step is independent so a single failed Apple event doesn't abort the rest of the sync.
    static func run(prospects: [Prospect], now: Date, client: OmniFocusClient, horizonDays: Int = 14) throws {
        try apply(desired: desired(from: prospects, now: now, horizonDays: horizonDays), client: client)
    }

    // #2882: what OmniFocus refused, per task. One show that OmniFocus will not act on used to abort the
    // whole pass, so every show AFTER it silently got no reminder at all and nothing said which ones.
    // Independent per-show work sharing one failure boundary makes every show's reliability depend on
    // every other show's worst case (L73), and an item left with no trace is indistinguishable from one
    // never attempted (L47), which is why the failure names the show rather than only counting.
    struct TaskFailure: Equatable, Sendable {
        enum Action: String, Equatable, Sendable { case create, complete }
        let action: Action
        let naturalKey: String
        let recipientId: String
        let reason: String
    }

    // The OmniFocus I/O half, over value types only, so it can run off the main actor while the
    // prospect read (desired) stays on it. Each task gets its OWN failure boundary: every create and
    // complete is attempted, and the failures are collected and reported together at the end.
    //
    // The two READS still throw, and that difference is deliberate. Not knowing what OmniFocus holds
    // makes every later decision guesswork, so a plan built on a failed read would complete and create
    // against a picture of nothing: that is a failure of the whole run and says so.
    @discardableResult
    static func apply(desired: [DesiredTask], client: OmniFocusClient) throws
        -> (existing: Int, created: Int, completed: Int, handled: [DesiredTask], failures: [TaskFailure]) {
        let existing = try client.existingOvertureTasks()
        let completed = try client.completedOvertureTasks()
        let plan = reconcile(desired: desired, existing: existing, completed: completed)
        var failures: [TaskFailure] = []
        var created = 0
        var completedCount = 0
        for task in plan.toCreate {
            do {
                try client.create(task)
                created += 1
            } catch {
                failures.append(TaskFailure(action: .create, naturalKey: task.naturalKey,
                                            recipientId: task.recipientId, reason: "\(error)"))
            }
        }
        for task in plan.toComplete {
            do {
                try client.complete(task)
                completedCount += 1
            } catch {
                failures.append(TaskFailure(action: .complete, naturalKey: task.naturalKey,
                                            recipientId: task.recipientId, reason: "\(error)"))
            }
        }
        return (existing.count, created, completedCount, plan.handled, failures)
    }

    // Diff the desired set against what OmniFocus currently holds (by naturalKey + recipientId, #653:
    // two contacts on one show are distinct tasks). Complete any existing task whose contact is no
    // longer desired (resolved) OR whose due no longer matches the contact's current due (Model A: the
    // nudge re-anchored it, so that task is stale). Create any desired task with no matching existing
    // task at the right due.
    private struct TaskKey: Hashable { let naturalKey: String; let recipientId: String }
    static func reconcile(desired: [DesiredTask], existing: [ExistingTask],
                          completed: [ExistingTask] = []) -> Plan {
        func key(_ naturalKey: String, _ recipientId: String) -> TaskKey { TaskKey(naturalKey: naturalKey, recipientId: recipientId) }
        let desiredByKey = Dictionary(desired.map { (key($0.naturalKey, $0.recipientId), $0) }, uniquingKeysWith: { a, _ in a })
        let toComplete = existing.filter { e in
            guard let d = desiredByKey[key(e.naturalKey, e.recipientId)] else { return true }   // resolved / no longer desired
            return d.dueDate != e.dueDate                                                       // stale due (re-anchored)
        }
        // #2899: what Dan ticked off. A completed task counts only when it matches a task that is desired
        // RIGHT NOW, at the same due, which is what makes this idempotent and what keeps stale evidence
        // out. Once the completion is applied the state moves, the task stops being desired, and no later
        // pass can match it again; and when the state re-opens (a second reply re-anchors the due) the
        // old completed task no longer matches, so the new task is created rather than swallowed.
        //
        // Matched on all THREE, through a set rather than a dictionary keyed on two: a contact can hold
        // several completed tasks at different dues, and picking one of them to stand for the rest would
        // decide by whichever the dictionary happened to keep (L131).
        let completedTasks = Set(completed)
        let handled = desired.filter {
            completedTasks.contains(ExistingTask(naturalKey: $0.naturalKey, recipientId: $0.recipientId,
                                                 dueDate: $0.dueDate))
        }
        let handledKeys = Set(handled.map { key($0.naturalKey, $0.recipientId) })
        let liveByKey = Dictionary(
            existing.filter { e in desiredByKey[key(e.naturalKey, e.recipientId)]?.dueDate == e.dueDate }
                .map { (key($0.naturalKey, $0.recipientId), $0) },
            uniquingKeysWith: { a, _ in a })
        let toCreate = desired.filter {
            liveByKey[key($0.naturalKey, $0.recipientId)] == nil
                && !handledKeys.contains(key($0.naturalKey, $0.recipientId))
        }
        return Plan(toCreate: toCreate, toComplete: toComplete, handled: handled)
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

// #2899: carrying back what Dan ticked off in OmniFocus.
//
// One implementation, called by both sync sites, because a caller that forgets it leaves the signal read
// and dropped: the task stops coming back and nothing in Overture moves, which is worse than never having
// read it (L46, L90). `OmniFocusCompletionsAreCarriedBackTests` asserts both sites call it.
extension OmniFocusSync {
    // Returns how many contacts were stamped, so a manual sync can say so.
    @discardableResult
    static func recordCompletions(_ handled: [DesiredTask], in prospects: [Prospect], now: Date) -> Int {
        guard !handled.isEmpty else { return 0 }
        let byKey = Dictionary(prospects.map { ($0.naturalKey, $0) }, uniquingKeysWith: { a, _ in a })
        var stamped = 0
        for task in handled {
            // Only the reply triage kind is honoured, and each kind is named rather than defaulted, so an
            // added kind breaks the build here instead of silently taking somebody else's meaning (L113).
            switch task.kind {
            case .replyTriage:
                guard let p = byKey[task.naturalKey],
                      let r = p.recipients.first(where: { $0.id == task.recipientId }) else { continue }
                AnsweredReply.recordHandled(on: r, in: p, now: now)
                stamped += 1
            case .postEventPrompt:
                // Dan's call, 2026-08-17: ticking this one off means "I know, I will do it in Overture",
                // never an ending. Overture cannot invent WHICH ending, and the ending is the fact the
                // whole funnel is reported on, so guessing one would file a number nobody can tell is
                // wrong (L163). Nothing is written. What the completion buys is that OmniFocus stops
                // asking: `reconcile` will not recreate a task Dan has completed at the same due, and the
                // show goes on asking in the app, through the post-event prompt that is already on screen,
                // until he records the ending there.
                continue
            }
        }
        return stamped
    }
}

// #885 (guard sweep): a failed sync carries the real reason rather than a generic apology, because the
// reason (a revoked Automation permission, a moved app) is the only part Dan can act on.
extension OmniFocusSync {
    static func failureMessage(reason: String) -> String { "OmniFocus sync failed: \(reason)" }

    // #2882: the run got through, and some reminders did not. A different sentence from the one above,
    // because it is a different fact and Dan acts on it differently: the failure above means nothing
    // synced at all, this one means most of it did and names what did not. Saying only "sync failed"
    // over a run that updated eleven of twelve reminders would send him looking for a fault that is not
    // there, and saying nothing would leave a missing reminder invisible, which is the state this whole
    // sync exists to prevent (L11).
    //
    // It NAMES the shows rather than counting them, because the only useful act is to go and look at
    // one, and a count tells him a reminder is missing without telling him whose (L80). Two names then
    // "and N more", so the sentence stays readable in the masthead when a whole run is refused.
    // nil when nothing failed, so there is no sentence for a state that cannot happen: a fallback
    // naming no show at all would be a line Dan could never be shown, and dead copy in the inventory
    // reads exactly like live copy (L29, L132).
    static func partialFailureMessage(failures: [TaskFailure], attempted: Int) -> String? {
        let names = failures.map { showName(fromNaturalKey: $0.naturalKey) }.reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }   // one show, not one per contact on it
        }
        guard let first = names.first else { return nil }
        let updated = max(0, attempted - failures.count)
        let named: String
        switch names.count {
        case 1: named = first
        case 2: named = "\(first) and \(names[1])"
        default: named = "\(first), \(names[1]) and \(names.count - 2) more"
        }
        return "OmniFocus updated \(updated) of \(attempted) reminders. It could not update \(named)."
    }

    // The show's own name, read off the first field of its natural key (`group|date|venue`), which is
    // the only name a task failure carries: a task being COMPLETED is an ExistingTask and has no title,
    // so there is nothing else to call it. Falls back to the whole key rather than to a placeholder, so
    // a key shaped differently reads as odd rather than as a nameless show (L67).
    static func showName(fromNaturalKey key: String) -> String {
        let first = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? key
        return first.isEmpty ? key : first
    }
}
