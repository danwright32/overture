import Foundation
import AppKit

// Canonical home for the resident login agent's stdout/stderr (#279). Lives under the user's own
// Library/Logs (owner-only 0700) instead of world-readable /tmp, so the captured diagnostics stay
// private and survive reboots (/tmp is cleared on restart). build-install.sh substitutes this same
// path into the LaunchAgent plist at install time; launchd opens these files at spawn, before any
// app code runs, so the directory must already exist; the app also (re)creates it at startup as a
// safety net. Keep the directory name and file names in sync with launchd/com.danwright.overture.plist.
enum AgentLogLocation {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Overture", isDirectory: true)
    }

    static var standardOutURL: URL { directory.appendingPathComponent("overture-agent.out.log") }
    static var standardErrorURL: URL { directory.appendingPathComponent("overture-agent.err.log") }

    // #295: the resident agent's logs live in a permanent directory (#279), so nothing ever truncates
    // them and on an always-resident agent (#237) they would grow without bound. ~5 MB per file is
    // plenty of recent diagnostics; with the single retained backup, disk stays bounded at ~10 MB.
    static let defaultMaxLogBytes = 5 * 1_024 * 1_024

    // #302: how big overture-agent.err.log was when Dan last opened the logs. The menu-bar nudge keys
    // off growth past this, so opening the logs clears it. Read reactively in the menu via @AppStorage.
    static let viewedErrorSizeKey = "agentLogsViewedErrorSize"

    // #302: only flag the agent's stderr once it has grown by at least this much new content since Dan
    // last looked. A growth threshold (not "any new byte") keeps the odd line of macOS framework
    // chatter from constantly raising the nudge; a genuinely misbehaving agent (retry loops, stack
    // traces) blows well past it. ~8 KB comfortably exceeds the incidental noise of a login or two.
    static let unreadErrorThresholdBytes = 8 * 1_024

    // Record the current error-log size as "seen", so later growth past the threshold re-raises the
    // nudge. Missing file counts as size 0. Best-effort.
    static func recordViewed(errorLog: URL = standardErrorURL, into defaults: UserDefaults = .standard,
                             fileManager: FileManager = .default) {
        let size = (try? fileManager.attributesOfItem(atPath: errorLog.path))?[.size] as? Int ?? 0
        defaults.set(Double(size), forKey: viewedErrorSizeKey)
    }

    // #302: true when the error log has gained at least `threshold` bytes of new stderr since the
    // recorded `viewedSize` (the menu-bar nudge's signal). capLogs (#295) truncates the file, so a log
    // now SMALLER than the recorded size is wholly new: count all of it, never a negative growth.
    // Missing file → false (nothing to flag). Pure read; best-effort.
    static func hasUnreadErrors(viewedSize: Int, threshold: Int = unreadErrorThresholdBytes,
                                errorLog: URL = standardErrorURL,
                                fileManager: FileManager = .default) -> Bool {
        guard let size = (try? fileManager.attributesOfItem(atPath: errorLog.path))?[.size] as? Int
        else { return false }
        let newBytes = size >= viewedSize ? size - viewedSize : size
        return newBytes >= threshold
    }

    // Bound the agent's logs. The copytruncate mechanism itself now lives in LogRotation (#608), so
    // the store-backup log can use the same one rather than growing a second copy of it; this stays
    // as the agent-specific entry point (its own files, its own cap). Run at startup, alongside
    // prepareDirectory().
    @discardableResult
    static func capLogs(maxBytes: Int = defaultMaxLogBytes,
                        files: [URL] = [standardOutURL, standardErrorURL],
                        fileManager: FileManager = .default) -> [URL] {
        LogRotation.cap(files: files, maxBytes: maxBytes, fileManager: fileManager)
    }

    // Create the log directory owner-only (0700) if missing, and tighten it if an earlier run left it
    // more permissive. Idempotent; best-effort at the one real call site (a failure just means
    // launchd's redirect is lost, the app still runs) but the outcome is reported rather than
    // silently swallowed (#524): isOwnerOnly reflects the directory's ACTUAL permissions after the
    // attempt, so a repair that can't succeed (an already-existing directory this process can't
    // chmod) is distinguishable from one that worked, instead of both looking identical.
    @discardableResult
    static func prepareDirectory(at directory: URL = AgentLogLocation.directory) -> (url: URL, isOwnerOnly: Bool) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // createDirectory only applies posixPermissions to directories it actually creates, so enforce
        // the mode on an already-existing directory too.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let mode = (try? FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue
        return (directory, mode == 0o700)
    }

    // #296: reveal the agent's log directory in Finder so the now-private, out-of-the-way diagnostics
    // are actually discoverable when the unattended agent misbehaves. Ensures the directory exists
    // first (so the click never opens Finder to nothing). The opener is injected so the prep + path
    // logic is unit-testable without launching Finder. Returns the directory it opened.
    @discardableResult
    static func revealInFinder(directory: URL = AgentLogLocation.directory,
                              open: (URL) -> Void = { NSWorkspace.shared.open($0) }) -> URL {
        let dir = prepareDirectory(at: directory).url
        open(dir)
        return dir
    }
}
