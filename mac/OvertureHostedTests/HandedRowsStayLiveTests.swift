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
@MainActor
@Suite("Rows handed down stay live (#3846)")
struct HandedRowsStayLiveTests {

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self, WatchedSource.self, RefusedContactAddress.self, PromotedProducer.self, DemotedHouse.self])
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

    // The stand-in for RootView, spelled once in `mac/TestSupport/RowsFromStore.swift` and used
    // here exactly as every converted harness uses it.
    private struct Harness: View {
        let container: ModelContainer
        @State private var feedback = ActionFeedback()
        @State private var dayOffOffer = DayOffOfferRequest()

        var body: some View {
            RowsFromStore { (rows: [Prospect]) in
                QueueView(deepLinkedKey: .constant(nil), deepLinkedKeys: .constant(nil),
                          allProspects: rows)
            }
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
        window.makeKeyAndOrderFront(nil)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    @Test func aStoreChangeStillReachesAQueueThatNoLongerQueriesTheStore() throws {
        let c = try container()
        let ctx = ModelContext(c)
        let dates = LiveDateClustering.dates(forRows: 2)
        insert(ctx, key: "first", date: dates[0])

        var window: NSWindow?
        // The positive control, and it is taken FIRST: a queue that never drew at all would satisfy the
        // claim below by never doing anything, which is the shape of false negative this suite refuses
        // (L159, L98).
        let firstDraw = QueueRenderPass.WorkTally.measure {
            window = host(Harness(container: c)).window
            pumpUntilRowsDerived()
        }
        defer { window?.close() }
        #expect(firstDraw.queueRows > 0,
                "the queue never derived anything, so nothing below measures the hand-down")

        // THE claim. Nothing here touches the view: a row lands in the store, and the queue has to notice
        // through RootView's stand-in re-evaluating and handing it a new array.
        let afterSave = QueueRenderPass.WorkTally.measure {
            insert(ctx, key: "second", date: dates[1])
            pumpUntilRowsDerived()
        }
        #expect(afterSave.queueRows > 0, Comment(rawValue:
            "a prospect was saved and the queue derived \(afterSave.queueRows) rows, so taking its own "
            + "@Query away has left it drawing a list that no longer follows the store. That is the "
            + "silent half of #3846: every cost reading would keep improving while the screen went stale"))
    }

    // The body runs on a LATER turn of the run loop, so a tally closed at the end of the synchronous save
    // reports the same zero whether the surface rebuilds or not. That was `ArchiveScrollDoesNotRebuild`'s
    // first form and it passed on the unfixed code (#3480). It stops the moment a row is derived, so the
    // passing case is fast and only the failing one runs out the deadline (L290).
    private func pumpUntilRowsDerived(timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && (QueueRenderPass.WorkTally.current?.queueRows ?? 0) == 0 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}
