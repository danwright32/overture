import Testing
@testable import Overture

// #1033: "Run scout now" stayed clickable through the detached reading half of a scout, because it was
// disabled only by isScanning (the in-process native sweep) and not by the reading phase that follows.
// This is the pure decision behind that disabled state, pulled out of the view so it can be tested
// against one rule instead of drifting silently (the #863 shape: a rule computed in a SwiftUI view that
// no test can see). It must stay in lockstep with the guard runScout applies before starting a run.
@Suite("Scout control state")
struct ScoutControlStateTests {
    @Test func enabledWhenNeitherScanningNorReading() {
        #expect(ScoutControlState.isRunScoutDisabled(isScanning: false, isReading: false) == false)
    }

    @Test func disabledWhileScanning() {
        #expect(ScoutControlState.isRunScoutDisabled(isScanning: true, isReading: false) == true)
    }

    @Test func disabledWhileReading() {
        // The detached read: isScanning has already flipped back to false, but the run is still going.
        #expect(ScoutControlState.isRunScoutDisabled(isScanning: false, isReading: true) == true)
    }

    @Test func enabledAgainAfterBothPhasesFinish() {
        #expect(ScoutControlState.isRunScoutDisabled(isScanning: false, isReading: false) == false)
    }
}
