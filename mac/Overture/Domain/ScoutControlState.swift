import Foundation

// #1033: whether "Run scout now" should be disabled. A scout runs in two phases: the in-process native
// sweep (isScanning), then a detached read of the pages that changed (isReading, tracked by
// readingStartedAt in the view). The menu item used to be disabled by isScanning alone, so it went
// clickable again the moment the native half finished while the read ran on for minutes. A second click
// then re-ran the whole native sweep for nothing and threw its one finding away on the read's
// already-running guard: wasteful and confusing, not unsafe.
//
// Pulled out of the view (the #863 shape: a rule computed inside a SwiftUI view that no test can see)
// so it stays in lockstep with the guard runScout applies before starting a run (!isScanning and no
// read in flight), which is the same condition the toolbar label already uses to show "Reading
// calendars".
enum ScoutControlState {
    static func isRunScoutDisabled(isScanning: Bool, isReading: Bool) -> Bool {
        isScanning || isReading
    }
}
