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
        guard let detailRange = rootView.range(
            of: "progressDetail: { PrepProgressDecoder.label(for: PrepProgressDecoder.loadCurrent()) }") else {
            Issue.record("Prep LiveRunLabel progressDetail not found")
            return
        }
        let windowStart = rootView.index(detailRange.lowerBound, offsetBy: -600,
                                         limitedBy: rootView.startIndex) ?? rootView.startIndex
        let nearby = rootView[windowStart..<detailRange.lowerBound]
        #expect(nearby.contains("LiveRunLabel(base: RunProgressCopy.title("))
        #expect(nearby.contains("PrepQueueService.isProbeRunning(now: Date()) ? .probing : .prepping"))
    }
}
