import Testing
import Foundation
import AppKit
import SwiftUI
@testable import Overture

// #3480: a way to drive a REAL scroll, so the claim #3431 and #3437 both rest on can be measured.
//
// That claim is: SwiftUI WRITES the `.scrollPosition(id:)` binding as rows cross the top, and each write
// invalidates the body that owns the state. #1774 fixed it for the queue by moving the position onto
// `QueueScrollHolder`, which owns the binding and runs the content as a closure; ArchiveView and
// FollowUpsView still bind it to their own `@State` inside a body whose first expression derives the
// whole store.
//
// NOTHING COULD MEASURE IT. Measured 2026-09-02 taking Phase 0's Measurement A: driving the archive's
// scroll bar through its accessibility value produced ZERO derivation samples on both surfaces. That is
// UNMEASURED rather than a finding, because setting a scroll bar's AX value may never write the SwiftUI
// binding, which is the exact thing under test, and `cliclick` on this Mac has move, click and wait only,
// with no scroll wheel. A negative reading there looks EXACTLY like the fix already working, so Phase 4
// would be built on an unverified premise or dropped on a false one (L159).
//
// WHAT THIS DRIVES. A real `CGEvent` scroll wheel, turned into an `NSEvent` and delivered to the
// `NSScrollView` SwiftUI built, so the event travels the same path a wheel turn under Dan's fingers does.
// Not `contentView.scroll(to:)`, which moves the clip view directly and proves nothing about whether the
// gesture path writes the binding.
//
// WHY A HARNESS RATHER THAN ArchiveView ITSELF. The question is about a SwiftUI mechanism, not about
// Archive: does binding `.scrollPosition(id:)` to a view's own `@State` re-run that view's body on
// scroll. Two harnesses answer it in one fixture, the defect shape and the fixed shape, and the pair is
// what makes either reading trustworthy: a test that only asserted the fixed shape stays quiet is
// satisfied by a scroll that never happened (L159, L98). So the scroll is PROVED to have moved the
// content before any conclusion is drawn from it.
@MainActor
@Suite("A real scroll writes the position binding and invalidates its owner (#3480)")
struct RealScrollInvalidationTests {

    // How many times a body ran. A class so the SwiftUI value type can report into it.
    private final class BodyCounter {
        private(set) var evaluations = 0
        func record() { evaluations += 1 }
    }

    // The DEFECT shape, which is what ArchiveView.swift:180 and FollowUpsView.swift:168 do today: the
    // position is this view's own @State, bound inside this view's own body.
    private struct OwnStateHarness: View {
        let counter: BodyCounter
        @State private var topId: Int?

        var body: some View {
            counter.record()
            return ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<400, id: \.self) { n in
                        Text("Row \(n)").frame(height: 40).id(n)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $topId, anchor: .top)
        }
    }

    // The FIXED shape, #1774's: a holder owns the position and runs the content as a CLOSURE, so a scroll
    // writes the holder's state and re-runs only that closure, never the enclosing body.
    private struct HolderHarness: View {
        let counter: BodyCounter

        var body: some View {
            counter.record()
            return PositionHolder {
                LazyVStack(spacing: 0) {
                    ForEach(0..<400, id: \.self) { n in
                        Text("Row \(n)").frame(height: 40).id(n)
                    }
                }
                .scrollTargetLayout()
            }
        }
    }

    // QueueScrollHolder's shape, reduced to the part under test. Deliberately a local copy rather than the
    // real one: QueueScrollHolder takes a QueueJumpRequest and this fixture is about the scroll mechanism,
    // not about the queue. What it shares with the real one is the only thing that matters here, that the
    // position is ITS state and the content arrives as a closure.
    private struct PositionHolder<Content: View>: View {
        @State private var topId: Int?
        @ViewBuilder let content: () -> Content

        var body: some View {
            ScrollView { content() }
                .scrollPosition(id: $topId, anchor: .top)
        }
    }

    // --- the rig -------------------------------------------------------------------------------------

    private func host(_ view: some View) -> (window: NSWindow, hosting: NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // AppKit's default is TRUE, which means `close()` RELEASES the window while this test still holds
        // a reference to it, and the next touch is a use after free. Alone that is survivable; run beside
        // the other hosted suites it crashed the shared app host, which restarts the test process and
        // truncates the WHOLE hosted target (measured 2026-09-03: 304 tests passing without this suite,
        // 111 and a restart with it). The crash names no test, so it reads as an unrelated flake.
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        // Deliberately NOT ordered front. This is a MenuBarExtra app (LSUIElement), and the host process
        // is shared with every other hosted suite; a borderless window brought forward mid-run disturbs
        // that process, and the app-host crash it produces takes the WHOLE hosted target with it, which
        // is #1967's original failure wearing a new cause. Layout does not need the window on screen.
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    // A REAL wheel event, not a programmatic scroll. `.pixel` units with a large negative delta, which is
    // what a trackpad flick produces, repeated so the position crosses several rows rather than nudging
    // inside the first one: the binding is written when a row crosses the top, so a scroll shorter than
    // one row can legitimately write nothing and would read as the mechanism being absent.
    private func scrollDown(_ scrollView: NSScrollView, turns: Int = 12) {
        for _ in 0..<turns {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                   wheelCount: 1, wheel1: -60, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { continue }
            scrollView.scrollWheel(with: event)
        }
    }

    // --- the measurements ----------------------------------------------------------------------------

    // The rig itself, proved before anything is concluded from it. A scroll that did not move the content
    // makes every quiet reading below meaningless, and quiet is exactly what the fixed shape is supposed
    // to look like (L98, L159).
    @Test func theDriverReallyScrolls() async throws {
        // #3842: a LOCKED session never lays this window out, so the wheel turn below has nothing to
        // scroll and this test can measure nothing. Reported as UNMEASURED rather than left to fail: a red
        // here is indistinguishable from a real regression in the mechanism #3431 and #3437 rest on, and
        // it blocked every merge in the repository while naming four scroll tests rather than the lock.
        guard !ScreenSession.isLocked else {
            ScreenSession.reportUnmeasured("RealScrollInvalidationTests.theDriverReallyScrolls")
            return
        }
        let counter = BodyCounter()
        let (window, hosting) = host(OwnStateHarness(counter: counter))
        defer { window.close() }

        let scroll = try #require(firstScrollView(in: hosting),
                                  "SwiftUI's ScrollView did not produce an NSScrollView to drive")
        let before = scroll.contentView.bounds.origin.y
        scrollDown(scroll)
        let moved = await waitUntil("the content to move under a real wheel event") {
            scroll.contentView.bounds.origin.y != before
        }
        #expect(moved,
                Comment(rawValue: "a real CGEvent wheel turn did not move the content at all "
                        + "(origin stayed at \(before)), so nothing below this measured a scroll"))
    }

    // The claim #3431 and #3437 rest on, measured rather than read off the code.
    @Test func aScrollInvalidatesABodyThatOwnsThePosition() async throws {
        // #3842: a LOCKED session never lays this window out, so the wheel turn below has nothing to
        // scroll and this test can measure nothing. Reported as UNMEASURED rather than left to fail: a red
        // here is indistinguishable from a real regression in the mechanism #3431 and #3437 rest on, and
        // it blocked every merge in the repository while naming four scroll tests rather than the lock.
        guard !ScreenSession.isLocked else {
            ScreenSession.reportUnmeasured("RealScrollInvalidationTests.aScrollInvalidatesABodyThatOwnsThePosition")
            return
        }
        let counter = BodyCounter()
        let (window, hosting) = host(OwnStateHarness(counter: counter))
        defer { window.close() }

        let scroll = try #require(firstScrollView(in: hosting))
        _ = await waitUntil("the first layout to settle") { counter.evaluations >= 1 }
        let settled = counter.evaluations

        scrollDown(scroll)
        let invalidated = await waitUntil("the scroll to re-run the owning body") {
            counter.evaluations > settled
        }

        #expect(invalidated,
                Comment(rawValue: "a real scroll did not re-run the body that owns the position "
                        + "(\(counter.evaluations) evaluations, was \(settled)). If this is quiet, "
                        + "#3431 and #3437 are aimed at a mechanism that does not exist."))
    }

    // The other half, and the reason the pair is worth having: #1774's holder shape suppresses exactly
    // the invalidation above, over the same rows driven by the same wheel event.
    @Test func aScrollThroughAHolderLeavesTheEnclosingBodyAlone() async throws {
        // #3842: a LOCKED session never lays this window out, so the wheel turn below has nothing to
        // scroll and this test can measure nothing. Reported as UNMEASURED rather than left to fail: a red
        // here is indistinguishable from a real regression in the mechanism #3431 and #3437 rest on, and
        // it blocked every merge in the repository while naming four scroll tests rather than the lock.
        guard !ScreenSession.isLocked else {
            ScreenSession.reportUnmeasured("RealScrollInvalidationTests.aScrollThroughAHolderLeavesTheEnclosingBodyAlone")
            return
        }
        let counter = BodyCounter()
        let (window, hosting) = host(HolderHarness(counter: counter))
        defer { window.close() }

        let scroll = try #require(firstScrollView(in: hosting))
        _ = await waitUntil("the first layout to settle") { counter.evaluations >= 1 }
        let settled = counter.evaluations

        let before = scroll.contentView.bounds.origin.y
        scrollDown(scroll)
        // The same proof this file's first test makes, repeated HERE, because a quiet counter below is
        // only evidence if this scroll actually happened in THIS window.
        let moved = await waitUntil("the content to move") {
            scroll.contentView.bounds.origin.y != before
        }
        #expect(moved, "the holder harness never scrolled, so its quiet body proves nothing")

        #expect(counter.evaluations == settled,
                Comment(rawValue: "the holder let a scroll re-run the enclosing body "
                        + "(\(counter.evaluations) evaluations, was \(settled)), which is the thing "
                        + "#1774 exists to prevent"))
    }

    // --- #3650: is the lazy stack actually viewport bounded? --------------------------------------
    //
    // THIS IS MILESTONE #80's GATE, and it is the one thing the whole plan rests on that nobody had
    // measured. Phase 4 builds a full card only for the rows that RENDER, which is worth about 478 cards
    // down to about 20 on Scout at the live shape. That saving is entirely a claim about SwiftUI: if a
    // `LazyVStack` realizes only what is visible, it holds; if restoring a pinned position deep in the
    // list realizes every row ABOVE it as well, the saving evaporates on exactly the surface it was
    // designed for, because the queue restores a pin on every rebuild (#976).
    //
    // Dan's own words, 2026-09-07: "my major concern is that as I'm scrolling it'll be building cards if
    // we do follow the screen which would probably slow it down". The arithmetic says a card is 0.368 ms
    // against a 16.7 ms frame, so a handful per frame is nothing. The arithmetic is not the risk. THIS is.
    //
    // Measured by COUNTING WHICH ROWS EVALUATED A BODY, because that is what a realized row costs, and a
    // `LazyVStack` evaluates a row's body only when it realizes it. The pair below is what makes either
    // reading trustworthy: a plain first render is the positive control, so a small number in the deep
    // case cannot be a counter that was never wired up (L171, L98).

    // Which rows evaluated a body. A class so the SwiftUI value type can report into it, exactly as
    // `BodyCounter` above does, and a SET rather than a count because the question is HOW MANY DISTINCT
    // rows were built rather than how many times any of them was.
    private final class RowRealizationCounter {
        private(set) var realized: Set<Int> = []
        func record(_ index: Int) { realized.insert(index) }
        var count: Int { realized.count }
        var highest: Int { realized.max() ?? -1 }
        var lowest: Int { realized.min() ?? -1 }
    }

    private struct CountingRow: View {
        let index: Int
        let counter: RowRealizationCounter
        var body: some View {
            counter.record(index)
            // A fixed height HERE is the fixture's own scaffolding and not a proposal: #3441 refused
            // fixed row heights in the product because they would truncate the cards Dan reads. This
            // fixture needs a known row height only so "how many rows fit the viewport" is arithmetic
            // rather than another thing to measure.
            return Text("Row \(index)").frame(height: Self.rowHeight)
        }
        static let rowHeight: CGFloat = 40
    }

    // The queue's shape: the position lives on a holder that runs the content as a closure (#1774), and
    // the rows are a lazy stack carrying `.scrollTargetLayout()`. `startAt` is what makes this the
    // question rather than a re-run of the tests above.
    private struct RealizationHarness: View {
        let counter: RowRealizationCounter
        let rows: Int
        let startAt: Int?

        var body: some View {
            PinnedAt(startAt: startAt) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<rows, id: \.self) { n in
                        CountingRow(index: n, counter: counter).id(n)
                    }
                }
                .scrollTargetLayout()
            }
        }
    }

    private struct PinnedAt<Content: View>: View {
        let startAt: Int?
        @ViewBuilder let content: () -> Content
        @State private var topId: Int?

        var body: some View {
            ScrollView { content() }
                .scrollPosition(id: $topId, anchor: .top)
                .onAppear { topId = startAt }
        }
    }

    // How many rows the 300pt viewport can show at 40pt each. Derived rather than written down, so the
    // reading below is judged against the window this fixture actually opens (L63).
    private static var rowsThatFitTheViewport: Int {
        Int((300.0 / CountingRow.rowHeight).rounded(.up))
    }

    // THE POSITIVE CONTROL. A plain first render at the top must realize a viewport's worth and not the
    // whole list. If this reads zero the counter is not wired to anything and the measurement below is
    // about nothing; if it reads 400 then this SwiftUI version is not lazy here at all, and that is the
    // finding rather than a broken fixture (L171).
    @Test func aPlainFirstRenderRealizesAboutAViewportOfRows() async throws {
        let counter = RowRealizationCounter()
        let (window, hosting) = host(RealizationHarness(counter: counter, rows: 400, startAt: nil))
        defer { window.close() }
        _ = try #require(firstScrollView(in: hosting))
        _ = await waitUntil("the first layout to realize some rows") { counter.count > 0 }

        let fits = Self.rowsThatFitTheViewport
        print("""
        row-realization: a plain first render (#3650)
          rows in the list          400
          viewport holds            \(fits) rows at \(CountingRow.rowHeight)pt
          rows that built a body    \(counter.count)   (indices \(counter.lowest) to \(counter.highest))
        """)

        #expect(counter.count > 0,
                "no row ever evaluated a body, so the counter is measuring nothing (L98)")
        #expect(counter.count < 400,
                Comment(rawValue: "a plain first render built ALL 400 rows, so this stack is not lazy "
                        + "at all and milestone #80's saving does not exist as designed."))
    }

    // THE GATE. Restore the position deep in the list, the way the queue does on every rebuild, and count
    // what got built. Two outcomes, and they send milestone #80 in opposite directions:
    //
    //   realizes about a viewport  -> Phase 4 builds cards for rendered rows, and Scout goes to about 20.
    //   realizes everything above  -> that saving is imaginary on a restored pin, and the fallback is
    //                                 per-stage card building, chosen HERE on a measurement rather than
    //                                 discovered in Phase 4.
    @Test func restoringADeepPositionDoesNotRealizeEverythingAboveIt() async throws {
        let deep = 300
        let counter = RowRealizationCounter()
        let (window, hosting) = host(RealizationHarness(counter: counter, rows: 400, startAt: deep))
        defer { window.close() }
        let scroll = try #require(firstScrollView(in: hosting))

        // Waits for the RESTORE to have happened, not merely for a first layout, or this reads the top
        // of the list and reports it as the deep case (L239).
        let restored = await waitUntil("the pinned position to be restored deep in the list") {
            scroll.contentView.bounds.origin.y > 0
        }
        _ = await waitUntil("realization to settle after the restore") { counter.highest >= deep - 1 }

        let fits = Self.rowsThatFitTheViewport
        let ceiling = fits * 4
        print("""
        row-realization: restoring a position deep in the list (#3650, milestone #80's gate)
          rows in the list          400
          restored to row           \(deep)
          viewport holds            \(fits) rows at \(CountingRow.rowHeight)pt
          rows that built a body    \(counter.count)   (indices \(counter.lowest) to \(counter.highest))
          ceiling for this to pass  \(ceiling)
          scrolled to               \(scroll.contentView.bounds.origin.y)pt

          Read this as the GATE it is. At or under the ceiling, Phase 4 builds cards for rendered rows
          and Scout falls from about 478 to about 20. Near 400, a restored pin realizes everything above
          it, that saving is imaginary, and the fallback is per-stage card building.
        """)

        #expect(restored,
                Comment(rawValue: "the position was never restored (still at "
                        + "\(scroll.contentView.bounds.origin.y)pt), so this measured the top of the "
                        + "list rather than a deep pin, and its verdict is about nothing (L98)"))
        #expect(counter.count <= ceiling,
                Comment(rawValue: "restoring a pin at row \(deep) built \(counter.count) of 400 rows, "
                        + "against a ceiling of \(ceiling) (four viewports). A restored pin realizes "
                        + "the rows above it, so building a card per RENDERED row saves far less than "
                        + "milestone #80's Phase 4 assumes, and the per-stage fallback is what to build "
                        + "(#3650, #3654)."))
    }
}
