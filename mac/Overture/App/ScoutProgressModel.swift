import Foundation
import Observation

// #3885: where the scout's progress heartbeat lives, so it does not invalidate the window.
//
// WHAT IT COST. `scoutNativeSnapshot` was `@State` on `RootView`, written from the scout's
// `onNativeProgress` and `onNativeStep` callbacks several times a second while a run is on. Writing to
// `@State` invalidates the view WHETHER OR NOT the body reads it, so every heartbeat re-evaluated
// `RootView`, which re-evaluates `queueSurface`, which is the `QueueView` under whatever sheet is open.
// In a 25 second stack sample on 2026-09-13, with the Follow-ups sheet open and a scout running, the
// COVERED queue took 5,724 main thread samples against the sheet's own 2,274: more of the main thread
// went on the screen Dan could not see than on the one he was looking at. Over the same window the
// freeze log holds 20 stalls, and they stop when the scout stops, from 53 a minute to 1.3 (#3885).
//
// WHY AN `@Observable` CLASS FIXES IT. An observable object invalidates only the views that READ one of
// its properties during their own body evaluation. In Release, `RootView.body` never reads the
// snapshot: the only consumer is the closure it hands to `RunProgressView`, which that view calls from
// its own `TimelineView` tick. So the heartbeat reaches the progress panel and reaches nothing else.
//
// IN DEBUG IT STILL INVALIDATES `RootView`, and that is correct rather than a gap: `rootRenderInputs`
// reads the snapshot to fingerprint what this window derives from, and that trace exists precisely to
// show which input provoked a render (#1930). A diagnostic that stopped seeing the value it is
// diagnosing would be worse than the cost it saves, and the population that matters for the cost is
// Dan's installed Release build (L535).
@Observable
@MainActor
final class ScoutProgressModel {
    /// The latest native-phase heartbeat, or nil when no run is in its native phase.
    var nativeSnapshot: RunProgressView.Snapshot?

    init() {}
}
