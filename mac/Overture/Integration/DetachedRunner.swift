import Foundation

// The shared mechanism for launching a detached Claude Code workflow (the Prep run, the reply-
// classify run) and guarding against a double-run via a heartbeat marker file. The app writes the
// marker on launch; the runner script heartbeats it while working and clears it on exit, so a marker
// untouched past `staleAfter` means the run died and the guard frees itself. Extracted from
// PrepQueueService (#184) so the two services don't duplicate the launch + marker machinery.
enum DetachedRunner {
    static func isRunning(markerURL: URL, now: Date, staleAfter: TimeInterval) -> Bool {
        heartbeat(markerURL: markerURL, now: now, staleAfter: staleAfter) == .beating
    }

    // #1822: the same file, read for everything it says rather than folded to a yes/no. `isRunning`
    // above answers "may I launch, is one already going", where absent and stale are rightly the same
    // answer. A progress screen is asking a different question, and for it they are opposite: absent
    // means the runner exited cleanly, stale means it stopped without doing so. One reader, so the two
    // questions can never drift apart on what the marker means.
    static func heartbeat(markerURL: URL, now: Date, staleAfter: TimeInterval) -> RunHeartbeat {
        // #1613: drop any cached reading FIRST. Foundation caches resource values on a URL value, so a
        // URL that has been asked once keeps answering with the reading it got then, for the life of that
        // value, even after the file has been deleted. Measured 2026-08-04: delete the file and the same
        // URL still reports the old modification date, while a freshly constructed URL correctly reports
        // nothing. That turns "the marker is gone" into "the marker is still there and stale", which is a
        // dead run reporting itself over and over, and it is the same family of defect as a live run and
        // a dead one being indistinguishable from the files.
        //
        // Production mostly escaped it because the default marker URLs are computed properties, so most
        // callers happen to build a new URL each time. That is luck, not a design, and the sweep in
        // clearDeadRun reads this immediately after deleting the file, which is exactly where the luck
        // runs out. Fixed here, once, so all three run services get it (L30).
        var url = markerURL
        url.removeAllCachedResourceValues()
        let touched = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        return RunHeartbeat.of(markerTouchedAt: touched ?? nil, now: now, staleAfter: staleAfter)
    }

    // #1613/#2104: sweep a run that DIED rather than finished, and report whether there was one.
    //
    // The runner removes its own marker on the way out, so a marker STILL THERE at the moment a run stops
    // being live means it stopped somewhere it never reached that exit. Nothing more is coming from it, so
    // the app must not go on offering Cancel: Cancel writes a sentinel that only a LIVE runner ever reads,
    // which is why pressing it on a dead run could not do anything however many times it was pressed.
    //
    // Lives HERE rather than in each service because all three detached runs have exactly this shape, and
    // #1613 shipping it for Prep alone left the same defect reaching Dan through the scout read and the
    // reply run (L30, fix the class). Each service still passes its OWN marker, sentinel and staleness
    // window: the three runs take wildly different times, and judging one against another's window is the
    // mistake #1822 already had to undo once.
    //
    // Returns false for every ending that is NOT a death, which is what stops it touching a live run
    // mid-write and what makes calling it twice report once.
    @discardableResult
    static func sweepDeadRun(markerURL: URL, cancelURL: URL, now: Date,
                             staleAfter: TimeInterval) -> Bool {
        guard DetachedRunEnding.of(heartbeat: heartbeat(markerURL: markerURL, now: now,
                                                        staleAfter: staleAfter)) == .died else {
            return false
        }
        // The marker goes first only in the sense that both go: a crash between the two leaves the sweep
        // to be retried rather than a half-swept run that reads as clean (assume it runs twice).
        try? FileManager.default.removeItem(at: markerURL)
        // The sentinel nobody read must not survive to stop a LATER run before it starts. Each service's
        // start path also clears it, so this is defence in depth on the same rule.
        try? FileManager.default.removeItem(at: cancelURL)
        return true
    }

    // The runner script path, configured once via a string default (not hardcoded) so it can be
    // unset; nil then makes the caller fail gracefully with "runner unavailable".
    static func scriptURL(defaultsKey: String) -> URL? {
        guard let path = UserDefaults.standard.string(forKey: defaultsKey), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    // The inherited environment plus OVERTURE_SUPPORT_DIR, which tells the script which handoff folder
    // to read/write. Without it the script falls back to the live path and a Debug build (whose handoff
    // dir is the isolated Overture-Debug subfolder) reads the wrong folder, finds no work-list, and dies
    // silently: the Debug/Release leak class #317 warns about. Pure so the contract is unit-tested.
    static func runnerEnvironment(base: [String: String], supportDirectory: URL) -> [String: String] {
        var env = base
        env["OVERTURE_SUPPORT_DIR"] = supportDirectory.path
        return env
    }

    // Launches the script detached via /bin/sh; never waits. The run writes its results file when done.
    // `supportDirectory` is THIS build's handoff dir (StoreLocation.handoffDirectory), passed through so
    // the script keys its queue/results/marker off the same folder the app wrote them to.
    static func launch(scriptPath: String, supportDirectory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "'\(scriptPath)' >/dev/null 2>&1 &"]
        process.environment = runnerEnvironment(base: ProcessInfo.processInfo.environment,
                                                supportDirectory: supportDirectory)
        try process.run()
    }
}
