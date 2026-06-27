import Foundation

// Records the result of the last OmniFocus sync (#239). The automatic sync (on launch / Downbeat
// change) is best-effort and swallows errors, so without this a revoked Automation permission or a
// moved/uninstalled OmniFocus would silently stop creating follow-up tasks with no signal to Dan.
// A failure is stored (timestamp + message) and stays until the next successful sync clears it; the
// masthead reads `failedAtKey` reactively via @AppStorage to show a warning.
enum OmniFocusSyncStatus {
    static let failedAtKey = "omniFocusLastSyncFailedAt"
    static let errorKey = "omniFocusLastSyncError"
    // #268: a denied/not-yet-granted Automation permission is a distinct kind of failure — it is fixed
    // by re-granting the grant, not by retrying — so the notification path can say exactly that, and
    // the flag drives the once-per-episode notify edge.
    static let permissionNeededKey = "omniFocusPermissionNeeded"

    static func recordSuccess(into defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: failedAtKey)
        defaults.removeObject(forKey: errorKey)
        defaults.removeObject(forKey: permissionNeededKey)
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
