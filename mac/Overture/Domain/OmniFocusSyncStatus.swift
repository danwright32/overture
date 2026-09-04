import Foundation

// Records the result of the last OmniFocus sync (#239). The automatic sync (on launch / Downbeat
// change) is best-effort and swallows errors, so without this a revoked Automation permission or a
// moved/uninstalled OmniFocus would silently stop creating follow-up tasks with no signal to Dan.
// A failure is stored (timestamp + message) and stays until the next successful sync clears it; the
// masthead reads `failedAtKey` reactively via @AppStorage to show a warning.
enum OmniFocusSyncStatus {
    static let failedAtKey = "omniFocusLastSyncFailedAt"
    static let errorKey = "omniFocusLastSyncError"
    // #268: a denied/not-yet-granted Automation permission is a distinct kind of failure; it is fixed
    // by re-granting the grant, not by retrying, so the notification path can say exactly that, and
    // the flag drives the once-per-episode notify edge.
    static let permissionNeededKey = "omniFocusPermissionNeeded"
    // #355: when the sync last actually succeeded, from either the manual button or the automatic
    // background scheduler (both call recordSuccess), so the toolbar can show real freshness instead
    // of just "enabled or not".
    static let lastSuccessAtKey = "omniFocusLastSuccessAt"

    static func recordSuccess(at date: Date, into defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: failedAtKey)
        defaults.removeObject(forKey: errorKey)
        defaults.removeObject(forKey: permissionNeededKey)
        defaults.set(date.timeIntervalSince1970, forKey: lastSuccessAtKey)
    }

    static func lastSuccessAt(from defaults: UserDefaults = .standard) -> Date? {
        let t = defaults.double(forKey: lastSuccessAtKey)
        guard t > 0 else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    // #885: the toolbar's freshness line, out of RootView's body. Reuses the same coarse relative-time
    // formatter PrepStatus and ScoutStatus already use in the masthead, rather than a second one.
    //
    // "Not yet synced" is deliberately a sentence and not an empty string: a blank where a time should
    // be reads as a bug, and a sync that has genuinely never run is a normal state on a new install.
    static func line(lastSuccessAt: Date?, now: Date) -> String {
        guard let lastSuccessAt else { return "Not yet synced" }
        return "Synced \(PrepStatus.relative(from: lastSuccessAt, to: now))"
    }

    // #268: record that OmniFocus Automation is not granted. Also lights the masthead failure key so
    // the warning shows when the window is open; the dedicated flag distinguishes it from a generic
    // failure for the notification path.
    static func recordPermissionNeeded(at date: Date, into defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: failedAtKey)
        defaults.set("OmniFocus needs Automation permission", forKey: errorKey)
        defaults.set(true, forKey: permissionNeededKey)
    }

    static func isPermissionNeeded(from defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: permissionNeededKey)
    }

    // #3420: what the last completed-task read walked. Written ONLY by a read that actually happened,
    // never by a failed one: zero tasks in no time is a real measurement of a small OmniFocus, and a
    // read that threw would otherwise record itself as the fastest one ever taken (L98).
    static let completedReadTasksKey = "omniFocusLastCompletedReadTasks"
    static let completedReadSecondsKey = "omniFocusLastCompletedReadSeconds"
    // A separate flag rather than inferring "never measured" from a zero count, because zero is a
    // legitimate reading: a fresh install has ticked nothing off yet (L67).
    static let completedReadTakenKey = "omniFocusLastCompletedReadTaken"

    static func recordCompletedRead(_ shape: OmniFocusSync.ReadShape, into defaults: UserDefaults = .standard) {
        defaults.set(shape.tasks, forKey: completedReadTasksKey)
        defaults.set(shape.seconds, forKey: completedReadSecondsKey)
        defaults.set(true, forKey: completedReadTakenKey)
    }

    // #3420: the sentence that makes the measurement readable by a person rather than a number the code
    // holds and nobody sees (L357). "Not measured yet" is its own sentence, not a blank or a zero: a
    // read nobody has taken and a read that found nothing are different facts, and zero completed
    // reminders is a perfectly ordinary reading on a fresh install (L11, L67).
    //
    // Takes the three stored values rather than a UserDefaults, which is the shape every other line on
    // that sheet already has: the view holds them in @AppStorage so it redraws when a sync lands, and
    // this decides what they say. A second reader that went to the defaults itself would be one nothing
    // on screen could ever call (#3154).
    static func completedReadLine(taken: Bool, tasks: Int, seconds: Double) -> String {
        guard taken else { return "No sync has read your completed reminders yet." }
        let formatted = String(format: "%.1f", seconds)
        let noun = tasks == 1 ? "completed reminder" : "completed reminders"
        return "Last sync read \(tasks) \(noun) from OmniFocus in \(formatted)s."
    }

    static func recordFailure(_ message: String, at date: Date, into defaults: UserDefaults = .standard) {
        defaults.set(date.timeIntervalSince1970, forKey: failedAtKey)
        defaults.set(message, forKey: errorKey)
    }

    static func lastFailure(from defaults: UserDefaults = .standard) -> (message: String, at: Date)? {
        let t = defaults.double(forKey: failedAtKey)
        guard t > 0 else { return nil }
        return (defaults.string(forKey: errorKey) ?? "OmniFocus sync failed", Date(timeIntervalSince1970: t))
    }
}
