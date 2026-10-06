import AppKit
import SwiftUI
import Testing
@testable import Overture

// #4516: what a hosted test that COUNTS a surface's passes needs, so the count is about its own view and
// about the code rather than the runner's speed.
//
// Both halves exist because `QueueRenderCounter` and a render memo were each answering a question the
// test did not ask, and only on a loaded machine. `RemovingOneSourceCostsOnePassTests` failed on 10 of
// 40 failed CI runs on 2026-10-04 and `OneChangeDerivesTheQueueOnceTests` on others, every time with a
// derivation nobody's change caused.
@MainActor
enum HostedPassCounting {

    // TAKING A HOSTED VIEW DOWN, so a later test cannot count it.
    //
    // `window.close()` alone leaves the hosted view in the SwiftUI graph. The window is not released
    // (every harness sets `isReleasedWhenClosed = false`, #3480), the hosting view is still its content,
    // and the view beneath it keeps its `@State`, its queries and its render memo. On CI run 37231800659
    // the roster reload test's reasons alternated between two Sources sheets, the live one and one with
    // no prospects and no roster: the bare sheet an earlier test in the same suite had closed and left.
    // `QueueRenderCounter` counts per SURFACE for the whole process, so that sheet's passes were charged
    // to the test that was running.
    //
    // So the view is UNMOUNTED first: the root is replaced with one that holds nothing, and the hosting
    // view is laid out once so SwiftUI removes the subtree and its state with it. Only then is the window
    // closed. What woke the leftover sheet was never established, and this makes that moot: a view that
    // is in no graph cannot be evaluated by anything. `aSheetTornDownIsNeverEvaluatedAgain` is the proof.
    //
    // GENERIC OVER THE ROOT rather than taking `AnyView`, because some harnesses host the real type and
    // must not wrap it (`RemovingOneSourceCostsOnePassTests` records why, #4247). The caller hands in the
    // empty value of its own root type.
    static func unmountAndClose<Root: View>(_ hosting: NSHostingView<Root>, replacingWith empty: Root,
                                            in window: NSWindow) {
        hosting.rootView = empty
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        window.close()
    }

    // A CLOCK THAT NEVER MOVES, pinned at the moment the view is built, for a surface whose memo window
    // must not be what a count measures (`QueueView.clock`, `SourcesView.clock`). Pinned to the real
    // present rather than a chosen date, so every rule the pass judges by the instant (lead time, a stage,
    // a run marker's age) answers as it would have a moment ago in the app.
    static func frozenClock() -> () -> Date {
        let pinned = Date()
        return { pinned }
    }

    // HOLDING A TEST PAST THE RENDER MEMO'S CLOCK WINDOW, in real time, so every run is the slow run.
    //
    // `ScopeMemo` refuses to serve an answer older than `staleAfterSeconds` (2 s) by the clock its caller
    // hands it, whatever the key says. In the app that clock is the wall clock, so on a runner slow enough
    // that the next body evaluation lands more than two seconds after the last build, that evaluation
    // derives the whole store again. That is correct in the app and was the whole of #4516's failure: the
    // passing CI runs of the roster test took 2.27 to 2.76 s, the failing one 6.90 s. A test that passes
    // only while the machine is fast has measured the machine (L290).
    //
    // So a test that asserts a count holds still hands the view a FROZEN clock, and then waits here until
    // the window has passed in real time, so a view that ignored the frozen clock would derive on every
    // run rather than on a loaded one. Judged by the memo's OWN expiry rule rather than a copy of it
    // (L144), from an instant the caller takes after its last build has happened, so the build can only
    // be older than that instant.
    static func waitPastTheRenderMemoWindow(since settled: Date,
                                            sourceLocation: SourceLocation = #_sourceLocation) async {
        let window = ScopeMemo<Int>.staleAfterSeconds
        await waitUntil("real time past the render memo's \(window) second window",
                        timeout: .seconds(window * 10),
                        sleep: { try? await Task.sleep(for: .milliseconds(50)) },
                        sourceLocation: sourceLocation) {
            ScopeMemo<Int>.Staleness.seconds(window).hasExpired(builtAt: settled, now: Date())
        }
    }
}
