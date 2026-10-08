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

    // #4534: the same teardown for a harness hosted through `AnyView` when the caller holds only its
    // WINDOW, which is all `Phase0cViewRig.host` hands back. Every `NSHostingView<AnyView>` that IS the
    // window's content view or sits directly in it is emptied before the window closes. A window holding none cannot be
    // unmounted from here, and that is RECORDED rather than closed quietly, because a quiet close is the
    // leftover this exists to prevent. Optional, because several suites keep the window in a variable a
    // failed build leaves nil, and a nil window has nothing in any graph.
    static func unmountAndClose(_ window: NSWindow?, sourceLocation: SourceLocation = #_sourceLocation) {
        guard let window else { return }
        // #4571: the content view ITSELF as well as its subviews, because some harnesses install the hosting
        // view as the window's content view (`HandedRowsStayLiveTests`) rather than adding it beneath one.
        let views = [window.contentView].compactMap { $0 } + (window.contentView?.subviews ?? [])
        let hostings = views.compactMap { $0 as? NSHostingView<AnyView> }
        if hostings.isEmpty {
            Issue.record(Comment(rawValue: "this window holds no AnyView hosting view, so its view could not "
                + "be unmounted and stays in the SwiftUI graph after the close; hand the hosting view to "
                + "unmountAndClose(_:replacingWith:in:) instead (#4534)"), sourceLocation: sourceLocation)
        }
        for hosting in hostings {
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
        }
        window.close()
    }

    // #4601: ENDING A HOSTED VIEW BEFORE ITS STORE GOES, for a test that takes one hosted view down and
    // then builds and saves into ANOTHER store before it returns (`ViewportSizeTests` measures two window
    // sizes, each on a fresh store).
    //
    // Unmounting removes the view from the graph, but not everything it made is freed on the spot: a
    // `TextField` (the Archive's search field is one) leaves AppKit objects in the CURRENT autorelease pool,
    // and through them the SwiftUI environment, which holds the store's main context. A main context holds
    // its store WEAKLY. So when the test then drops the store, that context lives on without one, still
    // registered by `_SwiftData_SwiftUI` for every context's save notification, and the next save anywhere
    // in the process reads `ModelContext.container` on it and traps: `EXC_BREAKPOINT`, with the save on the
    // stack. Measured 2026-10-07 in hosted runs, each arm unmounting and then dropping its store:
    //
    //   ArchiveView, or RowsFromStore around it         main context ALIVE, store freed (the next save traps)
    //   the Archive's five @Query declarations alone    released
    //   five queries plus a DoneButton, the banner,
    //   or the send alerts                              released
    //   five queries plus ShowSearchField or a TextField ALIVE
    //   a lone TextField under .modelContainer          ALIVE
    //   any of them inside this pool                    released, and the next save is safe
    //   any of them after one await (300 ms)            released
    //
    // The trapping frame was read off the crash report, not guessed: SwiftData offset 0x8b5d8 is the
    // `brk` in the function ModelContext's vtable slot for `container` points at, which returns a strongly
    // held store or loads the weak one and traps when it is gone.
    //
    // Between tests the pool is drained anyway, which is why a teardown in a `defer` at the end of a test
    // never showed this and why `ExternalRebuildProbeTests`, hosting the same Archive, did not crash. The
    // app cannot reach it either: Overture builds ONE store, in `OvertureApp.init`, and holds it for the
    // life of the process, so no context there ever outlives its store
    // (`HostedWindowsAreReleasedTests.savingRightAfterAnArchiveClosesIsSafeWhileItsStoreLives`).
    static func releasingWhatItHosts<Result>(_ body: () throws -> Result) rethrows -> Result {
        try autoreleasepool { try body() }
    }

    // #4534: a hosted root that can be taken out of the graph WITHOUT erasing its type, for the suites
    // that host the real type on purpose (`ABannerDerivesNothingOnAnySheetTests`, #4247's reason). The
    // `if` is a static conditional, so while it is mounted SwiftUI still diffs the content structurally,
    // which is the whole of what those suites protect. `RemovingOneSourceCostsOnePassTests` already hosts
    // this shape by hand.
    struct Mounted<Content: View>: View {
        let content: Content
        var mounted = true

        var body: some View {
            if mounted { content }
        }
    }

    static func unmountAndClose<Content: View>(_ hosting: NSHostingView<Mounted<Content>>, in window: NSWindow) {
        var empty = hosting.rootView
        empty.mounted = false
        unmountAndClose(hosting, replacingWith: empty, in: window)
    }

    // #4534: the ONE way a counting suite closes a window and leaves its view in the graph, for the two
    // cases where that is the point or the only safe option: a positive control proving a closed window is
    // still evaluated, and a RootView host whose teardown crashed the shared host
    // (`ScoutLandingHostedProbeTests` records it, the #3874 shape). `CountingSuitesUnmountBeforeClosingTests`
    // refuses a bare `close()` in a counting suite, so this name and its reason are what a reviewer reads.
    // The reason must begin with a word (L675): an empty string or a bare issue number explains nothing.
    static func closeLeavingMounted(_ window: NSWindow, because reason: String,
                                    sourceLocation: SourceLocation = #_sourceLocation) {
        if reason.first?.isLetter != true {
            Issue.record(Comment(rawValue: "a window was closed with its view left in the graph and the reason "
                + "given was \"\(reason)\", which does not begin with a word (#4534, L675)"),
                         sourceLocation: sourceLocation)
        }
        window.close()
    }

    // A CLOCK THAT NEVER MOVES, pinned at the moment the view is built, for a surface whose memo window
    // must not be what a count measures (`QueueView.clock`, `SourcesView.clock`, `ArchiveView.clock`).
    // Pinned to the real present rather than a chosen date, so every rule the pass judges by the instant
    // (lead time, a stage, a run marker's age) answers as it would have a moment ago in the app. Built ONCE
    // per hosted view and held, never inside a body or a `RowsFromStore` closure, where every evaluation
    // would pin a fresh instant and the clock would move after all.
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
