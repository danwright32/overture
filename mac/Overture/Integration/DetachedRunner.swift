import Foundation

// The shared mechanism for launching a detached Claude Code workflow (the Prep run, the reply-
// classify run) and guarding against a double-run via a heartbeat marker file. The app writes the
// marker on launch; the runner script heartbeats it while working and clears it on exit, so a marker
// untouched past `staleAfter` means the run died and the guard frees itself. Extracted from
// PrepQueueService (#184) so the two services don't duplicate the launch + marker machinery.
enum DetachedRunner {
    static func isRunning(markerURL: URL, now: Date, staleAfter: TimeInterval) -> Bool {
        guard let mod = try? markerURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        else { return false }
        return now.timeIntervalSince(mod) < staleAfter
    }

    // The runner script path, configured once via a string default (not hardcoded) so it can be
    // unset; nil then makes the caller fail gracefully with "runner unavailable".
    static func scriptURL(defaultsKey: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: defaultsKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    // Launches the script detached via /bin/sh; never waits. The run writes its results file when done.
    static func launch(scriptPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "'\(scriptPath)' >/dev/null 2>&1 &"]
        try process.run()
    }
}
