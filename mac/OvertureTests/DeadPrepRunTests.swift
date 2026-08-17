import Testing
import Foundation
import SwiftData

// #1613: a run that DIED is not a run that is stuck, and it must not be offered the control that only
// makes sense for a live one.
//
// Observed live on 2026-07-27: prep-run.sh died at parse time, so it never reached the heartbeat loop
// that reads the cancel sentinel. The app showed "Checking reachability looks stuck (3:38)" and offered
// Cancel; Cancel writes `prep-cancel`, nothing was alive to read it, and pressing it could never do
// anything however many times it was pressed.
//
// Some of that issue has since been fixed elsewhere and this suite deliberately does not re-test it:
// #1809 settles an orphaned check marker at launch and before every Prep run, and the marker frees
// itself after RunTimeouts.prep so the app can no longer sit "running" forever. What is left, and what
// this pins, is telling the two endings apart and acting on the difference.
//
// The discriminator already exists and is not a new guess: DetachedRunner.heartbeat distinguishes ABSENT
// (the runner removed its own marker on the way out, so it exited cleanly) from STALE (the marker is
// still there and has stopped being touched, so the runner stopped without exiting). Reusing it means
// there is no second opinion about liveness to drift from the first (L70).
@MainActor
@Suite("A prep run that died rather than finished (#1613)")
struct DeadPrepRunTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func scratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dead-run-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // MARK: telling the two endings apart

    // The runner removes its own marker on exit, so an absent marker is a clean ending: whatever it
    // produced is on disk and the normal settle reports it.
    @Test func anAbsentMarkerIsACleanEnding() {
        #expect(DetachedRunEnding.of(heartbeat: .absent) == .finished)
    }

    // A marker still sitting there, untouched past the window, is the signature of a runner that stopped
    // without exiting: it never reached the code that would have cleaned up after itself.
    @Test func aStaleMarkerIsADeath() {
        #expect(DetachedRunEnding.of(heartbeat: .stale) == .died)
    }

    // A run still beating has not ended at all, and must never be swept as dead mid-batch.
    @Test func aBeatingMarkerHasNotEnded() {
        #expect(DetachedRunEnding.of(heartbeat: .beating) == nil)
    }

    // MARK: clearing it

    // The sweep removes what the dead runner left behind, so nothing has to be deleted by hand in
    // Application Support (which is what actually unstuck this on 2026-07-27, and which Dan has no way to
    // do from inside the app).
    @Test func clearingADeadRunRemovesWhatTheRunnerLeftBehind() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("prep-running")
        let cancel = dir.appendingPathComponent("prep-cancel")
        let probe = dir.appendingPathComponent("reachability-probe-run.json")

        // A marker last touched well past the window: the app wrote it on launch and the runner died
        // before it ever heartbeated.
        try Data().write(to: marker)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-PrepQueueService.markerStaleAfter - 60)],
            ofItemAtPath: marker.path)
        // Dan pressed Cancel, which nothing was alive to read.
        try Data().write(to: cancel)

        let ctx = ModelContext(try container())
        let outcome = PrepQueueService.clearDeadRun(slot: .prep, markerURL: marker, cancelURL: cancel,
                                                    probeRunURL: probe, into: ctx, now: now)

        #expect(outcome != nil, "a stale marker is a dead run and must be swept")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: cancel.path),
                "the sentinel nothing read must not survive to affect a later run")
    }

    // A live run is never swept. This is the one that matters most: sweeping a beating marker would kill
    // a real multi-prospect batch mid-write.
    @Test func aLiveRunIsNeverSwept() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("prep-running")
        try Data().write(to: marker)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-5)],
                                              ofItemAtPath: marker.path)

        let ctx = ModelContext(try container())
        #expect(PrepQueueService.clearDeadRun(slot: .prep, markerURL: marker,
                                              cancelURL: dir.appendingPathComponent("prep-cancel"),
                                              probeRunURL: dir.appendingPathComponent("probe.json"),
                                              into: ctx, now: now) == nil)
        #expect(FileManager.default.fileExists(atPath: marker.path), "a beating marker must survive")
    }

    // A run that ended CLEANLY is not a death either, so the clean path keeps reporting what it produced
    // rather than being relabelled as a failure.
    @Test func aCleanlyFinishedRunIsNotSwept() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctx = ModelContext(try container())
        // No marker at all: the runner removed its own on the way out.
        #expect(PrepQueueService.clearDeadRun(slot: .prep, markerURL: dir.appendingPathComponent("prep-running"),
                                              cancelURL: dir.appendingPathComponent("prep-cancel"),
                                              probeRunURL: dir.appendingPathComponent("probe.json"),
                                              into: ctx, now: now) == nil)
    }

    // The paid half. A check that died still leaves a probe marker naming the shows Dan paid to research,
    // and sweeping the run must settle it rather than delete it blind, or those answers are thrown away.
    // It reuses #1809's own settle rather than a second implementation of it.
    @Test func clearingADeadCheckSettlesTheProbeRatherThanDroppingIt() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("prep-running")
        let probe = dir.appendingPathComponent("reachability-probe-run.json")
        try Data().write(to: marker)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-PrepQueueService.markerStaleAfter - 60)],
            ofItemAtPath: marker.path)
        try ReachabilityProbeMarker.write(
            ReachabilityProbeMarker(keys: ["a-key", "b-key"], startedAt: "2026-07-27T10:00:00Z"),
            to: probe)

        let ctx = ModelContext(try container())
        let outcome = try #require(PrepQueueService.clearDeadRun(slot: .prep, 
            markerURL: marker, cancelURL: dir.appendingPathComponent("prep-cancel"),
            probeRunURL: probe, into: ctx, now: now))

        // It reports the check it settled, so the death is not silent about the money already spent.
        let report = try #require(outcome.probeReport)
        #expect(report.requested == 2)
        #expect(!FileManager.default.fileExists(atPath: probe.path),
                "the marker must not survive to relabel the next Prep run as a check (#1809)")
    }

    // Sweeping twice is a no-op rather than a second report, because the marker it keyed off is gone.
    // A dead run gets reported once, however many times the watcher looks.
    //
    // This also pins the URL-cache fix. Foundation caches resource values on a URL VALUE, so a URL that
    // has been read once keeps answering with the reading it got then even after the file is deleted
    // (measured 2026-08-04). Reusing the same `marker` URL for both calls here is deliberate: without
    // DetachedRunner dropping the cached reading, the second sweep sees a marker that is not there,
    // calls it stale, and reports the same death again, forever.
    @Test func sweepingTwiceReportsOnceEvenThroughTheSameURLValue() throws {
        let dir = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("prep-running")
        let cancel = dir.appendingPathComponent("prep-cancel")
        let probe = dir.appendingPathComponent("probe.json")
        try Data().write(to: marker)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-PrepQueueService.markerStaleAfter - 60)],
            ofItemAtPath: marker.path)

        let ctx = ModelContext(try container())
        #expect(PrepQueueService.clearDeadRun(slot: .prep, markerURL: marker, cancelURL: cancel, probeRunURL: probe,
                                              into: ctx, now: now) != nil)
        #expect(PrepQueueService.clearDeadRun(slot: .prep, markerURL: marker, cancelURL: cancel, probeRunURL: probe,
                                              into: ctx, now: now) == nil)
    }

    // What Dan reads. It says the run stopped, not that it is stuck, because "stuck" invites waiting and
    // there is nothing left to wait for (L11: a message may claim only what its check measured).
    @Test func theSentenceSaysTheRunStoppedRatherThanThatItIsStuck() {
        let line = RunProgressCopy.diedLine(phase: .prepping)
        #expect(!line.localizedCaseInsensitiveContains("stuck"))
        #expect(line.localizedCaseInsensitiveContains("stopped"))
        // It names which run died, so a dead check and a dead Prep are not one undifferentiated sentence.
        #expect(RunProgressCopy.diedLine(phase: .probing) != line)
    }

    // The sweep is wired into BOTH moments a dead run can be discovered, and that is a separate claim from
    // the sweep being correct (L3, built is not wired). Guarded at the source because both live inside
    // RootView, which needs a store and an environment to render, so neither is reachable from a test.
    @Test func theSweepRunsWhenARunEndsAndAgainAtLaunch() {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        // When a watched run stops being live.
        let settle = SourceGuardHelper.bodyOfFunction(named: "settleFinishedRun", in: root)
        #expect(settle?.contains("sweptADeadRun(slot: slot)") == true,
                "a run that ends must be checked for having died rather than finished")
        // And at launch, for a run that died while Overture was closed and so was never watched at all.
        #expect(root.contains("} else if sweptADeadRun(slot: slot) {"),
                "launch must sweep a run that died while the app was shut")
    }

    // The sweep must run BEFORE the launch path's orphan settle, or a dead check is settled twice and
    // reported twice: the sweep performs that settle itself.
    @Test func theLaunchSweepComesBeforeTheOrphanSettle() throws {
        let root = SourceGuardHelper.source("Overture/App/RootView.swift")
        let sweep = try #require(root.range(of: "} else if sweptADeadRun(slot: slot) {"))
        let orphan = try #require(root.range(of: "PrepQueueService.settleOrphanedProbe(slot: slot, into: context"))
        #expect(sweep.lowerBound < orphan.lowerBound)
    }
}
