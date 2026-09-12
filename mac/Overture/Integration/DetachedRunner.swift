import Foundation

// The shared mechanism for launching a detached Claude Code workflow (the Prep run, the reply-
// classify run) and guarding against a double-run via a heartbeat marker file. The app writes the
// marker on launch; the runner script heartbeats it while working and clears it on exit, so a marker
// untouched past `staleAfter` means the run died and the guard frees itself. Extracted from
// PrepQueueService (#184) so the two services don't duplicate the launch + marker machinery.
enum DetachedRunner {
    // #3646: how many marker files a stretch of work reads off disk.
    //
    // Every marker read in the app goes through `heartbeat` below, and every one of them really is a
    // `stat` on the real filesystem: the marker URLs are computed properties precisely so a fresh `URL`
    // is built each time (#1613, the comment inside `heartbeat`), which means Foundation's resource
    // cache can never answer one of them and no caller can accidentally get a free reading.
    //
    // Counted HERE rather than at the call sites, for the reason `QueueRenderPass`'s own tallies record:
    // a counter a new call site has to opt into only ever measures the costs somebody already knew
    // about, and the defect this exists for was a marker read added per rendered card and per date
    // heading by a change that was not thinking about disk at all. Neither cost counter beside it could
    // see that one: `Corpus` counts sweeps over rows the pass was handed and `WorkTally` counts card
    // construction, and a `stat` is neither (#3646's own write-up).
    //
    // Read through a task local, so a measurement can only ever report on work the measurer itself ran.
    final class MarkerReadTally: @unchecked Sendable {
        @TaskLocal static var current: MarkerReadTally?

        private let lock = NSLock()
        private var count = 0

        /// How many marker files were read off disk while this tally was bound.
        var reads: Int { lock.withLock { count } }

        /// Recorded through the TYPE, so a call site does not need to know whether anybody is listening.
        static func recordRead() {
            guard let t = current else { return }
            t.lock.withLock { t.count += 1 }
        }

        /// Run `body` with a fresh tally bound, and hand back what it read. The ONLY way to read the
        /// counter, so a test cannot report on work it did not run.
        static func measure(_ body: () -> Void) -> MarkerReadTally {
            let tally = MarkerReadTally()
            MarkerReadTally.$current.withValue(tally) { body() }
            return tally
        }
    }

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
        // #2105: the fix #1613 made here is now the shared `FileTimestamp.modifiedAt`, so the other five
        // readers get it too rather than each needing to know.
        // #3646: the one place every marker read passes through, so this is where the reads are counted.
        // Above the read rather than after it, so a throw or an early return could never leave a read
        // uncounted and make a costly stretch of work report as a cheap one.
        MarkerReadTally.recordRead()
        let touched = FileTimestamp.modifiedAt(markerURL)
        return RunHeartbeat.of(markerTouchedAt: touched, now: now, staleAfter: staleAfter)
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

    // #2838: where a runner script actually is, asked once for all three runs.
    //
    // The impure half of RunnerScripts, which owns the rule and is pure. Everything this reads is a real
    // resource, and all three of them are injected so a test drives the whole decision without touching
    // UserDefaults, the file system or Dan's Application Support folder (L2):
    //
    //   * the per-script default, which is what a person configured,
    //   * `installed-build.json`'s `repoPath`, which `mac/build-install.sh` writes at every install and is
    //     the only thing in this app that knows where the checkout is,
    //   * whether a path names something runnable, which is what tells a live setting from a stale one.
    //
    // A DEBUG build reads its own handoff directory, which holds no installed record, so it derives
    // nothing and falls back to its own domain's default. That is correct rather than a gap: a Debug run
    // must not launch the Release checkout's scripts, and `mac/scripts/run-debug.sh` writes the Debug
    // domain's keys for the same reason the installer writes the Release ones.
    static func resolveRunner(_ runner: RunnerScripts.Runner,
                              configuredPath: String? = nil,
                              installedRepoPath: String? = nil,
                              isRunnable: ((String) -> Bool)? = nil) -> RunnerScripts.Resolution {
        RunnerScripts.resolve(
            runner,
            configuredPath: configuredPath ?? UserDefaults.standard.string(forKey: runner.defaultsKey),
            installedRepoPath: installedRepoPath
                ?? BuildFreshness.installedRecord(in: StoreLocation.handoffDirectory)?.repoPath,
            isRunnable: isRunnable ?? { FileManager.default.isExecutableFile(atPath: $0) })
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
    // #2763: `extra` is how a run says WHICH set of files it owns (`OVERTURE_RUN_SLOT`). It goes in the
    // environment rather than in the argument list because there is no argument list: the run is
    // backgrounded through `sh -c`, and every existing caller passes none. Defaulted to empty, so the two
    // runners that have no slot (scout-extract, reply-classify) are unchanged.
    static func launch(scriptPath: String, supportDirectory: URL,
                       extra: [String: String] = [:]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "'\(scriptPath)' >/dev/null 2>&1 &"]
        var env = runnerEnvironment(base: ProcessInfo.processInfo.environment,
                                    supportDirectory: supportDirectory)
        for (key, value) in extra { env[key] = value }
        process.environment = env
        try process.run()
    }
}
