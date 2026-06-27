import Foundation
import AppKit

// Canonical home for the resident login agent's stdout/stderr (#279). Lives under the user's own
// Library/Logs (owner-only 0700) instead of world-readable /tmp, so the captured diagnostics stay
// private and survive reboots (/tmp is cleared on restart). build-install.sh substitutes this same
// path into the LaunchAgent plist at install time — launchd opens these files at spawn, before any
// app code runs, so the directory must already exist; the app also (re)creates it at startup as a
// safety net. Keep the directory name and file names in sync with launchd/com.danwright.overture.plist.
enum AgentLogLocation {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Overture", isDirectory: true)
    }

    static var standardOutURL: URL { directory.appendingPathComponent("overture-agent.out.log") }
    static var standardErrorURL: URL { directory.appendingPathComponent("overture-agent.err.log") }

    // Create the log directory owner-only (0700) if missing, and tighten it if an earlier run left it
    // more permissive. Idempotent; best-effort (a failure just means launchd's redirect is lost, the
    // app still runs). Returns the directory.
    @discardableResult
    static func prepareDirectory(at directory: URL = AgentLogLocation.directory) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        // createDirectory only applies posixPermissions to directories it actually creates, so enforce
        // the mode on an already-existing directory too.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory
    }

    // #296: reveal the agent's log directory in Finder so the now-private, out-of-the-way diagnostics
    // are actually discoverable when the unattended agent misbehaves. Ensures the directory exists
    // first (so the click never opens Finder to nothing). The opener is injected so the prep + path
    // logic is unit-testable without launching Finder. Returns the directory it opened.
    @discardableResult
    static func revealInFinder(directory: URL = AgentLogLocation.directory,
                              open: (URL) -> Void = { NSWorkspace.shared.open($0) }) -> URL {
        let dir = prepareDirectory(at: directory)
        open(dir)
        return dir
    }
}
