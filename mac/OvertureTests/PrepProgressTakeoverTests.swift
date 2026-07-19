import Testing
import Foundation
@testable import Overture

// #1130: the Prep run gets the scout's takeover progress screen instead of only a subtle toolbar label,
// so a detached run that takes minutes shows a visible working / still-alive / stalled state. It reuses
// the shared RunProgressView in a new `.prepping` phase, fed by the run's own progress file.
@MainActor
@Suite("Prep progress takeover (#1130)")
struct PrepProgressTakeoverTests {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-takeover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func thePreppingPhaseIsTitledPrepping() {
        #expect(RunProgressCopy.title(.prepping) == "Prepping")
    }

    // The prepping phase must judge "looks stuck" against the PREP ceiling, not the scout's. Reusing the
    // scout sweep's shorter window would declare a healthy multi-minute Prep run stalled (the #803 lesson).
    @Test func thePreppingPhaseUsesThePrepTimeout() {
        let view = RunProgressView(phase: .prepping, since: nil)
        #expect(view.timeout == RunTimeouts.prep)
    }

    @Test func livePreppingReadsTheRunsProgressCount() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("prep-progress.json")
        try JSONEncoder().encode(PrepProgress(version: 1, total: 6, completed: 2)).write(to: url)

        let snap = RunProgressView.Snapshot.livePrepping(progressURL: url)
        #expect(snap.total == 6)
        #expect(snap.completed == 2)
        // The Prep run publishes no per-prospect name, so the line degrades to just the count.
        #expect(snap.sourceName == nil)
        #expect(RunProgressCopy.sourceLine(name: snap.sourceName, completed: snap.completed, total: snap.total) == "2 of 6")
    }

    // A missing/mid-write progress file reads as an empty snapshot (no crash, no thrown error), which the
    // shared sourceLine renders as no count line at all rather than a bogus "0 of 0".
    @Test func livePreppingReadsAMissingFileAsEmpty() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("prep-progress-missing-\(UUID().uuidString).json")
        let snap = RunProgressView.Snapshot.livePrepping(progressURL: missing)
        #expect(snap.total == 0)
        #expect(snap.completed == 0)
        #expect(RunProgressCopy.sourceLine(name: snap.sourceName, completed: snap.completed, total: snap.total) == nil)
    }
}

// #1130: the takeover is view-only wiring in RootView (a sheet cannot be exercised headlessly), held in
// place with a source guard in this project's existing convention (see PrepProgressWiringGuardTests), and
// paired with the behavioral snapshot/copy/timeout tests above so it is not a source-grep guard alone.
@Suite("Prep takeover is wired into RootView (#1130)")
struct PrepTakeoverWiringGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    @Test func rootViewPresentsThePrepTakeoverInThePreppingPhase() {
        let rootView = source("Overture/App/RootView.swift")
        #expect(!rootView.isEmpty)
        // The takeover sheet is bound to the prep-running flag and renders the shared progress view in the
        // prepping phase.
        #expect(rootView.contains(".sheet(isPresented: $prepSheetShown)"))
        #expect(rootView.contains("phase: .prepping"))
        #expect(rootView.contains("Snapshot.livePrepping()"))
    }
}
