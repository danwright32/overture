import Testing
@testable import Overture

// #802 slice 3: the scout's reading half is DETACHED, so its results land minutes after runScout has
// already returned and reported Carnegie's numbers.
//
// The failure this guards is invisible and total: if the app does not follow that run to completion, the
// pages it read sit in a results file nobody opens, and Dan's watched calendars look permanently empty.
// Everything still compiles, every other test still passes, and the entire feature silently does
// nothing. Prep hit exactly this shape of bug (#435), which is why watchPrepRun exists and why this
// mirrors it rather than inventing a second pattern.
@MainActor
@Suite("The scout follows its reading run to completion (#802)")
struct ScoutExtractWatchGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func aScoutThatQueuedPagesWaitsForThemToBeRead() {
        #expect(!rootView.isEmpty)
        // Only when something was actually queued: a run with nothing to read must not sit waiting on a
        // run that was never launched.
        #expect(rootView.contains("$0.state == .queuedForReading"))
        #expect(rootView.contains("await watchScoutExtractRun()"))
    }

    @Test func whatTheRunReadIsActuallyIngested() {
        #expect(rootView.contains("ScoutExtractIngest.ingest("))
    }

    // A run that finishes without producing anything is the one shape of failure that would otherwise be
    // indistinguishable from every watched calendar happening to be quiet. It must say so, and it must
    // say that those pages have NOT been read, or Dan would believe they had.
    @Test func aReadingRunThatProducedNothingSaysSoRatherThanLookingQuiet() {
        #expect(rootView.contains("case .finishedEmpty:"))
        #expect(rootView.contains("RunLog.scoutExtractURL"))
    }
}
