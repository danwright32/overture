import Testing

// #802, Dan's 4th decision (2026-07-12): the daily automatic run watches for free, and only a scout Dan
// STARTED may spend tokens reading a page that changed.
//
// The rule lives in ScoutService and is tested there. What this guards is the one line that decides
// which of the two Dan actually gets, and it is worth guarding on its own because the failure is
// invisible: if `autoScoutIfDue` ever loses its `.watchOnly`, everything still compiles, every other
// test still passes, and the only symptom is that Overture quietly starts launching Claude runs on a
// timer while Dan is not at the machine, competing with Prep for the same Max-plan capacity.
//
// Source guards are this project's convention for a wiring fact with no separate behavioral surface
// (MastheadGuardTests, ToolbarConsolidationGuardTests, ProspectRowGuardTests).
@MainActor
@Suite("The automatic scout never spends tokens (#802)")
struct AutoScoutSpendGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func theScheduledRunAsksForTheFreeDepth() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("runScout(auto: true, depth: .watchOnly)"))
    }

    // And the run Dan starts is the one allowed to read. The default is `.readChanged`, so the manual
    // button needs no argument, but the DEFAULT itself has to stay the reading one, or pressing Scout
    // would quietly stop reading anything and Dan would never see a new show from an html source again.
    @Test func theRunDanStartsIsTheOneThatReads() {
        // Matches the DEFAULT, not the whole signature: #970 added an `only:` parameter and the old
        // exact-signature match broke without anything it guarded being untrue. A guard that fails on
        // an unrelated edit gets "fixed" by whoever is in a hurry, and the thing it protects is what
        // gets lost. This asserts the invariant itself: the run Dan starts defaults to reading.
        #expect(rootView.contains("private func runScout(auto: Bool = false, depth: ScoutDepth = .readChanged"))
    }

    // The free daily run must not be able to reach the AI path at all. Stated as a property of the
    // depth, so no future caller can pass `.watchOnly` and still spend.
    @Test func onlyTheReadingDepthMaySpend() {
        #expect(SourceSchedule.plan(sources: [], depth: .watchOnly, now: .distantPast)
                    .maySpendTokens == false)
        #expect(SourceSchedule.plan(sources: [], depth: .readChanged, now: .distantPast)
                    .maySpendTokens == true)
    }
}
