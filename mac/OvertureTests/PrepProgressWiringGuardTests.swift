import Testing
import Foundation

// #354: the Prep button's LiveRunLabel reads real progress instead of showing a bare spinner.
// View-only wiring with no separate behavioral surface beyond PrepProgressDecoder (unit-tested
// directly), held in place with a source guard matching this project's existing convention.
//
// #1003: the wiring now hands the decoder call in as a CLOSURE, so the label re-reads it on every
// tick rather than reflecting whatever RootView captured at its last render. That the closure
// re-evaluates is covered behaviorally by LiveRunLabelViewStateTests; this guard's remaining job is
// only to pin that Prep is wired to the decoder in the closure form at all. The window is generous so
// an explanatory comment between the label and the call can't push it out of view (the #354 bug it
// nearly reintroduced).
@Suite("Prep progress wiring (#354)")
struct PrepProgressWiringGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    @Test func prepLiveRunLabelReadsTheProgressFile() {
        let rootView = source("Overture/App/RootView.swift")
        #expect(!rootView.isEmpty)
        // #1322: the prep/probe toolbar label reads the run's progress file. Anchor on that (unique to
        // this label, unlike the shared RunProgressCopy.title base), then look back at the base that feeds
        // it: now RunProgressCopy.title of the prepping-or-probing phase, so a probe reusing this run slot
        // reads "Checking reachability" instead of "Prepping".
        // #2760: the progress file is the SLOT's, so a live check counts its own N of M instead of
        // whatever the prep run last wrote.
        guard let detailRange = rootView.range(
            of: "PrepProgressDecoder.progressURL(for: slot)") else {
            Issue.record("Prep LiveRunLabel progressDetail not found")
            return
        }
        let windowStart = rootView.index(detailRange.lowerBound, offsetBy: -1400,
                                         limitedBy: rootView.startIndex) ?? rootView.startIndex
        let nearby = rootView[windowStart..<detailRange.lowerBound]
        #expect(nearby.contains("LiveRunLabel("))
        #expect(nearby.contains("RunProgressCopy.title(isProbe ? .probing : .prepping)"))
        // #2760: which run is in flight comes from `runInFlight`, which asks BOTH slots, so a check is
        // named a check whether it is in the check slot or (during the upgrade window) the prep slot.
        #expect(nearby.contains("PrepQueueService.runInFlight(now: Date())"))
        #expect(nearby.contains("PrepProgressDecoder.label(for: PrepProgressDecoder.loadCurrent("))
    }

    // #1822: the two facts this label was missing. It rendered inside a branch that only runs BECAUSE
    // isRunning returned true, yet passed no heartbeat at all, so RunProgress.liveness saw no evidence of
    // life and showed the warning triangle for the whole remainder of every run past three minutes. And a
    // reachability probe, which reuses this same run slot, was judged against Prep's window rather than
    // its own ten minutes. Neither is visible from the label's own tests: only the call site has them.
    @Test func theToolbarLabelIsGivenTheHeartbeatAndTheProbesOwnWindow() {
        let rootView = source("Overture/App/RootView.swift")
        guard let body = SourceGuardHelper.propertyBody("private var prepToolbarLabel: some View {",
                                                        in: rootView) else {
            Issue.record("RootView no longer builds the toolbar's Prep label in `prepToolbarLabel`")
            return
        }
        #expect(body.contains("heartbeat: { PrepQueueService.heartbeat(slot: slot, now: Date()) }"),
                "the toolbar label judges liveness with no heartbeat, so a healthy run reads as stuck")
        #expect(body.contains("RunTimeouts.reachabilityProbe"),
                "a probe is judged against Prep's window instead of its own")
        #expect(body.contains("RunTimeouts.prep"))
    }
}
