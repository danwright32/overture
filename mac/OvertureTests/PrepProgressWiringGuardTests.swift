import Testing
import Foundation

// #354: the Prep button's LiveRunLabel reads real progress instead of showing a bare spinner.
// View-only wiring with no separate behavioral surface beyond PrepProgressDecoder (unit-tested
// directly), held in place with a source guard matching this project's existing convention.
@Suite("Prep progress wiring (#354)")
struct PrepProgressWiringGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    @Test func prepLiveRunLabelReadsTheProgressFile() {
        let rootView = source("Overture/App/RootView.swift")
        #expect(!rootView.isEmpty)
        guard let prepLabelRange = rootView.range(of: "LiveRunLabel(base: \"Prepping\"") else {
            Issue.record("Prep LiveRunLabel not found")
            return
        }
        let nearby = rootView[prepLabelRange.lowerBound...].prefix(300)
        #expect(nearby.contains("PrepProgressDecoder.label(for: PrepProgressDecoder.loadCurrent())"))
    }
}
