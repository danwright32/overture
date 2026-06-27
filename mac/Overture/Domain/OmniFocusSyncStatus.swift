import Foundation

// Records the result of the last OmniFocus sync (#239). The automatic sync (on launch / Downbeat
// change) is best-effort and swallows errors, so without this a revoked Automation permission or a
// moved/uninstalled OmniFocus would silently stop creating follow-up tasks with no signal to Dan.
// A failure is stored (timestamp + message) and stays until the next successful sync clears it; the
// masthead reads `failedAtKey` reactively via @AppStorage to show a warning.
enum OmniFocusSyncStatus {
    static let failedAtKey = "omniFocusLastSyncFailedAt"
    static let errorKey = "omniFocusLastSyncError"

    static func recordSuccess(into defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: failedAtKey)
        defaults.removeObject(forKey: errorKey)
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
