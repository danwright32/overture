import Testing
@testable import Overture

// #897: the rule that decides whether a stitched multi-month page (#858) was actually read in full. The
// WIRING of this rule into the reconcile is proved separately (StitchedSweepIngestWiringTests); this file
// proves the rule itself, including the edges that keep it dormant on a normal single-month page.
@Suite("A stitched sweep is complete only when every month was read (#897)")
struct SweepCoverageTests {
    // The whole safety valve: a single-month page is the watchlist default (monthHorizon 1), has nothing
    // to under-read, and is not even asked for coverage. It must ALWAYS read complete, whatever the run
    // reported, or the check would change live behavior the day it landed instead of waiting for
    // pagination to be turned on.
    @Test func aSingleMonthPageIsAlwaysComplete() {
        #expect(SweepCoverage.isComplete(stitchedMonths: ["2026-07"], monthsCovered: nil))
        #expect(SweepCoverage.isComplete(stitchedMonths: ["2026-07"], monthsCovered: []))
        #expect(SweepCoverage.isComplete(stitchedMonths: [], monthsCovered: nil))
    }

    @Test func aStitchedPageWhoseEveryMonthWasCoveredIsComplete() {
        #expect(SweepCoverage.isComplete(
            stitchedMonths: ["2026-07", "2026-08", "2026-09", "2026-10"],
            monthsCovered: ["2026-07", "2026-08", "2026-09", "2026-10"]))
    }

    // The bug this whole issue is about: the run read three of four stitched months and simply returned
    // fewer shows. It must read INCOMPLETE.
    @Test func aStitchedPageMissingOneCoveredMonthIsIncomplete() {
        #expect(!SweepCoverage.isComplete(
            stitchedMonths: ["2026-07", "2026-08", "2026-09", "2026-10"],
            monthsCovered: ["2026-07", "2026-08", "2026-09"]))
    }

    // Fail-safe direction: a stitched page whose run reported no coverage at all (an older workflow that
    // does not yet echo monthsCovered) is distrusted, never assumed whole.
    @Test func aStitchedPageWithNoReportedCoverageIsIncomplete() {
        #expect(!SweepCoverage.isComplete(
            stitchedMonths: ["2026-07", "2026-08"], monthsCovered: nil))
    }

    // Order does not matter, and extra reported months beyond what was stitched are harmless: only a
    // MISSING stitched month makes a sweep short.
    @Test func coverageIsASetContainmentNotAnOrderedOrExactMatch() {
        #expect(SweepCoverage.isComplete(
            stitchedMonths: ["2026-08", "2026-07"],
            monthsCovered: ["2026-07", "2026-08", "2026-09"]))
    }
}
