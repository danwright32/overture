import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #3846: the rows are HANDED DOWN now, and this is the proof that handing them down did not quietly stop
// the screen updating.
//
// `QueueView` and `ArchiveView` each held a bare `@Query` over `Prospect`, and so does `RootView`, which
// presents both. Two identical bare descriptors held by two live views share NOTHING: measured 2026-09-12
// on the live store, the second cost 99.6% of the first, 158.8 ms against 159.5 ms over 1,238 rows. So
// both views now take the rows from RootView instead.
//
// WHAT THAT PUTS AT RISK, and why a cost change needs a correctness test rather than a faster number. The
// `@Query` is what made those views redraw when the store moved. Take it away and the redraw depends on
// the PARENT re-evaluating and handing down a new array, which is a different mechanism with a different
// failure: it fails SILENTLY, by showing a list that is simply out of date, and every cost test in this
// repository would go on getting faster while it did (#1547's class, L3).
//
// So this drives the real path: a real window, a real container, a real save, and it waits for the queue
// to derive the store again rather than asserting anything about how fast it was.
//
// #4358 slice E4d: the queue engine is where the rows come from now, and the question is unchanged: a save must
// still reach a queue that holds no query of its own.
@MainActor
@Suite("Rows handed down stay live (#3846)")
struct HandedRowsStayLiveTests {

    private func container() throws -> ModelContainer {
        // #4358 slice E4d: the whole schema, because the queue engine the queue now draws reads every table it holds.
        try TestModelContainer.inMemory(AppSchema.models)
    }

    private func insert(_ ctx: ModelContext, key: String, date: String) {
        let p = Prospect(naturalKey: key, groupName: "Ensemble \(key)", discipline: "music",
                         venue: "Weill Recital Hall", performanceDate: date,
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 7, tier: "mid", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil, status: .new)
        p.presenter = "Ensemble \(key) Presents"
        p.location = "New York, NY"
        ctx.insert(p)
        try? ctx.save()
    }

    // The stand-in for RootView: the queue drawing the engine RootView builds (#4358 slice E4d).
    private struct Harness: View {
        let container: ModelContainer
        // #4358 slice E4d: the queue engine RootView builds, over the same store.
        let engine: QueueEngineHost.Engine
        @State private var feedback = ActionFeedback()
        @State private var dayOffOffer = DayOffOfferRequest()

        var body: some View {
            QueueView(engine: engine, deepLinkedKey: .constant(nil), deepLinkedKeys: .constant(nil))
            .modelContainer(container)
            .environment(feedback)
            .environment(dayOffOffer)
        }
    }

    private func host(_ view: some View) -> (window: NSWindow, hosting: NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // AppKit's default releases the window while this scope still holds it, which crashed the shared
        // app host and truncated the whole hosted target (#3480).
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = window.contentLayoutRect
        window.contentView = hosting
        // #4444: OFF screen, like every other hosted suite. This line used to order the window front, and
        // an on-screen window's teardown runs on later turns of the run loop, in whichever test turns it
        // next: 18 of the 24 CI host deaths found on 2026-10-04 came straight after this test.
        // `HostedWindowsStayOffScreenGuardTests` keeps it that way.
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    @Test func aStoreChangeStillReachesAQueueThatNoLongerQueriesTheStore() async throws {
        let c = try container()
        // #4358 slice E4d: the main context, which the engine RootView builds reads and every control writes through.
        let ctx = c.mainContext
        let dates = LiveDateClustering.dates(forRows: 2)
        let engine = HostedQueueEngine.make(context: ctx)
        insert(ctx, key: "first", date: dates[0])

        var window: NSWindow?
        // The positive control, and it is taken FIRST: a queue that never drew at all would satisfy the
        // claim below by never doing anything, which is the shape of false negative this suite refuses
        // (L159, L98).
        // #4358 slice E4d: the pass runs in the engine's own turn, a main actor task, which a nested run of the run
        // loop never reaches; so the tally is bound across an AWAITED wait, and the engine's turns, started inside it,
        // carry it with them.
        let firstDraw = QueueRenderPass.WorkTally()
        await QueueRenderPass.WorkTally.$current.withValue(firstDraw) {
            engine.start()
            window = host(Harness(container: c, engine: engine)).window
            await waitUntilRowsDerived()
        }
        // #4444: closed, and its pending work run, while `c` is still alive. This test returns the moment
        // its rows are derived, so the queue screen still has work scheduled; left alone, that work ran in
        // the NEXT test's run loop turns, after this container was gone.
        defer { Self.closeWhileAlive(window, holding: c) }
        #expect(firstDraw.queueRows > 0,
                "the queue never derived anything, so nothing below measures the hand-down")

        // THE claim. Nothing here touches the view: a row lands in the store, and the queue has to notice.
        // #4358 slice E4d: through the engine, so the claim is read where it lands, in two halves: the saved show is
        // in the pass the engine published, and the queue's body ran again to draw it. Not by the tally, because
        // the engine's turn that takes the save in can be one a SwiftUI callback scheduled before it (the view
        // handing the engine its inputs), which carries no task-local, so a tally reads zero while the queue is live.
        let bodies = QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface)
        insert(ctx, key: "second", date: dates[1])
        let published = await waitUntil("the saved show is in the engine's published pass", timeout: .seconds(10)) {
            engine.output?.value.data.rows.contains { $0.id == "second" } == true
        }
        let redrawn = await waitUntil("the queue draws the published pass", timeout: .seconds(10)) {
            QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface) > bodies
        }
        #expect(published && redrawn, Comment(rawValue:
            "a prospect was saved and " + (published ? "the engine published it, but the queue never drew again"
                                                 : "the engine never published it")
            + ", so taking the queue's own @Query away has left it drawing a list that no longer follows the "
            + "store. That is the silent half of #3846: every cost reading would keep improving while the screen "
            + "went stale"))
    }

    // Close the window and turn the run loop a fixed number of times while `container` is held, so the
    // work its close and the queue screen scheduled runs here rather than inside the next test. A count of
    // turns rather than a wait on a condition, because there is no observable "nothing left pending" to
    // wait on; each turn returns as soon as it has nothing to do.
    private static func closeWhileAlive(_ window: NSWindow?, holding container: ModelContainer) {
        HostedPassCounting.unmountAndClose(window)
        for _ in 0..<20 {
            autoreleasepool { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        }
        withExtendedLifetime(container) {}
    }

    // The body runs on a LATER turn of the run loop, so a tally closed at the end of the synchronous save
    // reports the same zero whether the surface rebuilds or not. That was `ArchiveScrollDoesNotRebuild`'s
    // first form and it passed on the unfixed code (#3480). It stops the moment a row is derived, so the
    // passing case is fast and only the failing one runs out the deadline (L290).
    private func waitUntilRowsDerived() async {
        _ = await waitUntil("a pass to derive rows", timeout: .seconds(10)) {
            (QueueRenderPass.WorkTally.current?.queueRows ?? 0) > 0
        }
    }
}
