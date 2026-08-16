import Testing
import Foundation

// #2104: the dead-run sweep for the OTHER two detached runs.
//
// #1613 fixed this for Prep only: a run whose marker is still present at the moment it stops being live
// died somewhere it never reached the exit that would have removed it, so nothing more is coming and the
// app must not go on offering Cancel, which writes a sentinel only a LIVE runner ever reads. The scout
// read and the reply-classify run sit on the same DetachedRunner machinery, each with its own cancel
// sentinel and its own staleness window, and neither was swept. The same situation therefore still
// reached Dan in two other places, presenting identically: a run that looks alive with a dead control.
//
// The sweep itself moves to DetachedRunner so there is ONE implementation for all three rather than three
// that can drift (L30), and PrepQueueService's version becomes that plus its reachability-probe settle,
// which is the only genuinely Prep-specific part.
@MainActor
@Suite("Sweeping a dead scout or reply run (#2104)")
struct DeadRunSweepTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let window: TimeInterval = 180

    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dead-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func marker(in dir: URL, ageSeconds: TimeInterval) throws -> URL {
        let url = dir.appendingPathComponent("running")
        try Data().write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-ageSeconds)],
                                              ofItemAtPath: url.path)
        return url
    }

    // MARK: the shared sweep

    // A marker untouched past the window is a death: the runner stopped somewhere it never reached the
    // exit that removes its own marker.
    @Test func aStaleMarkerIsSweptAndItsSentinelGoesWithIt() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markerURL = try marker(in: dir, ageSeconds: window + 60)
        let cancel = dir.appendingPathComponent("cancel")
        try Data().write(to: cancel)

        #expect(DetachedRunner.sweepDeadRun(markerURL: markerURL, cancelURL: cancel,
                                            now: now, staleAfter: window))
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        #expect(!FileManager.default.fileExists(atPath: cancel.path),
                "the sentinel nothing read must not survive to stop a LATER run before it starts")
    }

    // The one that matters most: a run still beating is never swept, or a real batch dies mid-write.
    @Test func aBeatingRunIsNeverSwept() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markerURL = try marker(in: dir, ageSeconds: 5)

        #expect(!DetachedRunner.sweepDeadRun(markerURL: markerURL,
                                             cancelURL: dir.appendingPathComponent("cancel"),
                                             now: now, staleAfter: window))
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    // A run that exited cleanly removed its own marker, so there is nothing to sweep and nothing to
    // report: it finished, and what it produced is reported by the normal path.
    @Test func aCleanlyFinishedRunIsNotSwept() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!DetachedRunner.sweepDeadRun(markerURL: dir.appendingPathComponent("running"),
                                             cancelURL: dir.appendingPathComponent("cancel"),
                                             now: now, staleAfter: window))
    }

    // Sweeping twice reports once, THROUGH THE SAME URL VALUE. Foundation caches resource values on a URL
    // value, so without DetachedRunner dropping that cache the second sweep sees a marker that is not
    // there, calls it stale, and reports the same death again forever (#1613).
    @Test func sweepingTwiceReportsOnceEvenThroughTheSameURLValue() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markerURL = try marker(in: dir, ageSeconds: window + 60)
        let cancel = dir.appendingPathComponent("cancel")

        #expect(DetachedRunner.sweepDeadRun(markerURL: markerURL, cancelURL: cancel,
                                            now: now, staleAfter: window))
        #expect(!DetachedRunner.sweepDeadRun(markerURL: markerURL, cancelURL: cancel,
                                             now: now, staleAfter: window))
    }

    // MARK: each service judges against ITS OWN window

    // The three runs take wildly different times (a reply draft is not a multi-source calendar read), so
    // each sweeps against its own staleness window rather than a shared number. Judging a scout read
    // against Prep's window is exactly the mistake #1822 already had to undo once for the stall label.
    @Test func eachServiceSweepsAgainstItsOwnWindow() {
        #expect(ScoutExtractService.markerStaleAfter == RunTimeouts.scoutExtract)
        #expect(ReplyClassifyService.markerStaleAfter == RunTimeouts.replyClassify)
        #expect(PrepQueueService.markerStaleAfter == RunTimeouts.prep)
        // Not a distinction without a difference: Prep's window really is a different length from the
        // other two today, so a sweep wired to the wrong constant would visibly misjudge a run. (The
        // scout and reply windows happen to be equal right now, which is exactly why the wiring is
        // asserted per service above rather than by comparing the numbers to each other: equal values
        // would make such a comparison pass while the wiring was wrong.)
        #expect(RunTimeouts.prep != RunTimeouts.scoutExtract)
    }

    // The scout's sweep uses the scout's own marker and sentinel, not another run's. A sweep pointed at
    // the wrong pair would clear a DIFFERENT run, which is worse than not sweeping at all.
    @Test func theScoutSweepClearsTheScoutsOwnFiles() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markerURL = try marker(in: dir, ageSeconds: RunTimeouts.scoutExtract + 60)
        let cancel = dir.appendingPathComponent("scout-cancel")
        try Data().write(to: cancel)

        #expect(ScoutExtractService.clearDeadRun(markerURL: markerURL, cancelURL: cancel, now: now))
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        #expect(!FileManager.default.fileExists(atPath: cancel.path))
    }

    @Test func theReplySweepClearsTheReplyRunsOwnFiles() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markerURL = try marker(in: dir, ageSeconds: RunTimeouts.replyClassify + 60)
        let cancel = dir.appendingPathComponent("reply-cancel")
        try Data().write(to: cancel)

        #expect(ReplyClassifyService.clearDeadRun(markerURL: markerURL, cancelURL: cancel, now: now))
        #expect(!FileManager.default.fileExists(atPath: markerURL.path))
        #expect(!FileManager.default.fileExists(atPath: cancel.path))
    }

    // A scout read still going is never swept by its own service either.
    @Test func aLiveScoutReadIsNeverSwept() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let markerURL = try marker(in: dir, ageSeconds: 30)
        #expect(!ScoutExtractService.clearDeadRun(markerURL: markerURL,
                                                  cancelURL: dir.appendingPathComponent("c"), now: now))
        #expect(FileManager.default.fileExists(atPath: markerURL.path))
    }

    // MARK: what Dan reads

    // Each dead run names itself, so a dead scout read and a dead reply run are not one sentence twice.
    @Test func eachRunSaysWhichOneStopped() {
        let scout = RunProgressCopy.diedLine(phase: .reading)
        let replies = RunProgressCopy.diedLineForReplies
        #expect(scout != replies)
        for line in [scout, replies] {
            #expect(line.localizedCaseInsensitiveContains("stopped"))
            #expect(!line.localizedCaseInsensitiveContains("stuck"))
        }
    }

    // MARK: wiring

    // Built is not wired (L3). Both new sweeps have to be reachable from the moment their run ends, and
    // guarded at the source because both live inside RootView, which needs a store and an environment to
    // render and so cannot be built in a test (the #863 lesson).
    @Test func bothNewSweepsAreWiredWhereTheirRunEnds() {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        #expect(root.contains("ScoutExtractService.clearDeadRun"),
                "a scout read that ends must be checked for having died")
        #expect(root.contains("ReplyClassifyService.clearDeadRun"),
                "a reply run that ends must be checked for having died")
    }

    // And Prep's own sweep still goes through the shared one rather than keeping a second copy, or the
    // three drift and this issue comes back for whichever was missed.
    @Test func prepsSweepUsesTheSharedImplementation() {
        let service = SourceGuardHelper.source("Overture/Integration/PrepQueueService.swift")
        let body = SourceGuardHelper.propertyBody("defaults: UserDefaults = .standard) -> DeadRunOutcome? {",
                                                  in: service)
        #expect(body?.contains("DetachedRunner.sweepDeadRun") == true,
                "Prep must sweep through the shared implementation, not its own copy")
    }
}
