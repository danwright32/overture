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

    // #1689: the ledger of things the app itself CALLED a problem, one line each (AgentLog.problem).
    // Deliberately beside the other two rather than somewhere tidier: "open agent logs" reveals this
    // folder, and a ledger Dan cannot reach from the nudge that mentions it is no use to him.
    static var problemsURL: URL { directory.appendingPathComponent("overture-agent.problems.log") }

    // #295: the resident agent's logs live in a permanent directory (#279), so nothing ever truncates
    // them and on an always-resident agent (#237) they would grow without bound. ~5 MB per file is
    // plenty of recent diagnostics; with the single retained backup, disk stays bounded at ~10 MB.
    static let defaultMaxLogBytes = 5 * 1_024 * 1_024

    // #302/#1689: how big the problem ledger was when Dan last opened the logs. The menu-bar nudge keys
    // off growth past this, so opening the logs clears it. Read reactively in the menu via @AppStorage.
    static let viewedProblemSizeKey = "agentLogsViewedProblemSize"

    // Record the current ledger size as "seen", so a later problem re-raises the nudge. Missing file
    // counts as size 0. Best-effort.
    static func recordViewed(problemsLog: URL = problemsURL, into defaults: UserDefaults = .standard,
                             fileManager: FileManager = .default) {
        let size = (try? fileManager.attributesOfItem(atPath: problemsLog.path))?[.size] as? Int ?? 0
        defaults.set(Double(size), forKey: viewedProblemSizeKey)
    }

    // #1689: true when the app has named a problem Dan has not seen. ANY new byte counts, and there is
    // deliberately no size threshold.
    //
    // The old rule measured stderr and needed an 8 KB threshold to tolerate routine chatter. Routine
    // chatter no longer reaches this file, so the only thing a threshold could still do is hide a
    // single real problem behind its own smallness: the partial-settle report that prompted this issue
    // is about 130 bytes, and would have had to happen sixty times to be mentioned once.
    //
    // capLogs (#295) truncates the file, so a ledger now SMALLER than the recorded size holds wholly
    // new content: count all of it, never a negative growth. An emptied ledger holds nothing to read
    // and is not a new problem. Missing file → false. Pure read; best-effort.
    static func hasUnreadProblems(viewedSize: Int, problemsLog: URL = problemsURL,
                                  fileManager: FileManager = .default) -> Bool {
        guard let size = (try? fileManager.attributesOfItem(atPath: problemsLog.path))?[.size] as? Int
        else { return false }
        let newBytes = size >= viewedSize ? size - viewedSize : size
        return newBytes > 0
    }

    // Bound the agent's logs. The copytruncate mechanism itself now lives in LogRotation (#608), so
    // the store-backup log can use the same one rather than growing a second copy of it; this stays
    // as the agent-specific entry point (its own files, its own cap). Run at startup, alongside
    // prepareDirectory().
    // #1689: the problem ledger is bounded with the other two. An app that keeps naming one recurring
    // problem would otherwise grow a file nothing ever trims, which is how the log this issue is about
    // reached 9 KB of the same three sentences.
    static var cappedFiles: [URL] { [standardOutURL, standardErrorURL, problemsURL] }

    @discardableResult
    static func capLogs(maxBytes: Int = defaultMaxLogBytes,
                        files: [URL] = AgentLogLocation.cappedFiles,
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
