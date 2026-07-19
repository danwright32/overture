import Testing
import Foundation
@testable import Overture

// #1034/#1036: the live reading-phase snapshot, built from the files the app already owns (the queue it
// wrote, the results the run is filling, and the run's own script-derived progress count). Shared by
// RootView's takeover and AddLeadSheet's inline read, so there is ONE definition of "what is the reading
// phase showing right now", not two that drift. Driven against temp files, no run.
@Suite("Scout reading-phase snapshot (#1036)")
struct RunProgressSnapshotTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("scout-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeQueue(_ items: [ScoutExtractQueueItem], to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("queue.json")
        try ScoutExtractQueueBuilder.encode(
            ScoutExtractQueue(version: 2, generatedAt: "2026-07-17T00:00:00Z", items: items)).write(to: url)
        return url
    }

    private func writeResults(_ ids: [String], to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("results.json")
        let results = ScoutExtractResults(version: 1, generatedAt: "2026-07-17T00:00:00Z",
            results: ids.map { ScoutExtractResult(sourceId: $0, verdict: .upcomingListings, events: []) })
        try JSONEncoder().encode(results).write(to: url)
        return url
    }

    private func writeProgress(completed: Int, total: Int, to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("progress.json")
        try JSONEncoder().encode(ScoutExtractProgress(version: 1, total: total, completed: completed)).write(to: url)
        return url
    }

    private func item(_ id: String, org: String?, listings: String? = nil) -> ScoutExtractQueueItem {
        ScoutExtractQueueItem(sourceId: id, orgName: org, listingsURL: listings, pagePath: "/tmp/\(id).html")
    }

    @Test func namesTheInFlightSourceAndCarriesTheRunsCount() throws {
        let dir = try tempDir()
        let queue = try writeQueue([item("a", org: "Carnegie Hall"), item("b", org: "Kaufman Music Center"),
                                    item("c", org: "Bargemusic")], to: dir)
        let results = try writeResults(["a"], to: dir)          // a done, b in flight
        let progress = try writeProgress(completed: 1, total: 3, to: dir)

        let snap = RunProgressView.Snapshot.liveReading(queueURL: queue, resultsURL: results, progressURL: progress)
        #expect(snap.sourceName == "Kaufman Music Center")
        #expect(snap.completed == 1)
        #expect(snap.total == 3)
        #expect(RunProgressCopy.sourceLine(name: snap.sourceName, completed: snap.completed, total: snap.total)
                == "Kaufman Music Center · 1 of 3")
    }

    // #1036: a pasted lead queues exactly ONE item, so its snapshot has total 1. The shared component
    // must degrade to just the source name ("1 of 1" is noise), which is exactly what the sourceLine
    // rule does. This is the behavioral proof that AddLeadSheet reuses the component without special-casing.
    @Test func aSingleSourceLeadReadShowsJustTheSourceNoOneOfOne() throws {
        let dir = try tempDir()
        let queue = try writeQueue([item("lead-x", org: nil, listings: "https://www.example.org/events")], to: dir)
        let results = try writeResults([], to: dir)
        let progress = try writeProgress(completed: 0, total: 1, to: dir)

        let snap = RunProgressView.Snapshot.liveReading(queueURL: queue, resultsURL: results, progressURL: progress)
        #expect(snap.sourceName == "www.example.org")   // no org name, so the listing host
        #expect(snap.total == 1)
        #expect(RunProgressCopy.sourceLine(name: snap.sourceName, completed: snap.completed, total: snap.total)
                == "www.example.org")
    }

    // Missing files read as an empty snapshot, never a crash (the run may not have written anything yet).
    @Test func missingFilesGiveAnEmptySnapshot() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString)")
        let snap = RunProgressView.Snapshot.liveReading(queueURL: missing, resultsURL: missing, progressURL: missing)
        #expect(snap.sourceName == nil)
        #expect(snap.completed == 0)
        #expect(snap.total == 0)
    }
}
