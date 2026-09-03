import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #3437/#3431: a scroll must not rebuild the store.
//
// This is the end to end proof the phase asks for, and it is only assertable because two other pieces
// landed first. #3480 gave the suite a way to drive a REAL scroll wheel, so the mechanism can be
// triggered at all. #2048 gave it per-card work counters, so what a scroll COSTS is a number rather than
// an argument. Neither existed when this phase was planned.
//
// The claim: `ArchiveView.swift:180` binds `.scrollPosition(id: $topKey)` to the view's OWN `@State`,
// inside a body whose first expression derives the whole store. SwiftUI WRITES that binding as rows
// cross the top, and each write invalidates the body, so scrolling rebuilds all 1,139 cards. Measured on
// the running app 2026-09-02: `ArchiveView.items` was 65% of the main thread while typing, with
// `QueueItem.init` at 33%.
//
// What this asserts is the thing Dan would feel: turn the wheel, and no card is built.
@MainActor
@Suite("Scrolling the Archive builds no cards (#3437)")
struct ArchiveScrollDoesNotRebuildTests {

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        OrgReachabilityAnswer.self, WatchedSource.self,
                                        RefusedContactAddress.self, PromotedProducer.self,
                                        DemotedHouse.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Enough rows that the list scrolls at all: a scroll shorter than the content moves nothing, and a
    // list that fits on screen has no top for a row to cross.
    private func seed(_ ctx: ModelContext, rows: Int = 120) {
        for n in 0..<rows {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Weill Recital Hall",
                             performanceDate: String(format: "2027-%02d-%02d", 1 + (n % 12), 1 + (n % 27)),
                             sourceListingURL: nil, priorRelationship: "none", production: "self",
                             profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
            ctx.insert(p)
        }
        try? ctx.save()
    }

    // #3480's rig. AppKit really lays the view out, which is the only way a real wheel event has
    // anything to land on.
    private func host(_ view: some View) -> (window: NSWindow, hosting: NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // #3480: AppKit's default releases the window while this scope still holds it, which crashed the
        // shared app host and truncated the whole hosted target.
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
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

    private func scrollDown(_ scrollView: NSScrollView, turns: Int = 12) {
        for _ in 0..<turns {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                   wheelCount: 1, wheel1: -60, wheel2: 0, wheel3: 0),
                  let event = NSEvent(cgEvent: cg) else { continue }
            scrollView.scrollWheel(with: event)
        }
    }

    @Test func aScrollBuildsNoCards() async throws {
        let c = try container()
        seed(ContextHolder.make(c))

        let view = ArchiveView()
            .modelContainer(c)
            .environment(ActionFeedback())
            .environment(DayOffOfferRequest())
        let (window, hosting) = host(view)
        defer { window.close() }

        let scroll = try #require(firstScrollView(in: hosting),
                                  "the Archive laid out no scrolling list, so nothing was scrolled")
        let before = scroll.contentView.bounds.origin.y

        // Counted around the scroll AND the work it provokes. The tally must stay bound while SwiftUI
        // actually rebuilds, because a scroll only ASKS for the rebuild: the body runs on a later turn of
        // the run loop, and a tally closed at the end of the synchronous scroll reports zero whether the
        // surface rebuilds or not. That was this test's first form, and it PASSED on the unfixed code,
        // which is exactly the false negative #3480 exists to prevent (L159, L98).
        //
        // The pump stops the moment a card is built, so the failing case is fast, and runs out its
        // deadline only when nothing is built, which is the case with nothing to wait for (L290).
        let work = QueueRenderPass.WorkTally.measure {
            scrollDown(scroll)
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline && (QueueRenderPass.WorkTally.current?.queueItems ?? 0) == 0 {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
        }

        // The scroll really happened, asserted BEFORE any conclusion is drawn from a quiet counter: a
        // scroll that moved nothing produces the same zero as a surface that does not rebuild, and the
        // second is the thing under test (L159, L98).
        let moved = await waitUntil("the Archive's content to move under a real wheel event") {
            scroll.contentView.bounds.origin.y != before
        }
        #expect(moved, "the Archive never scrolled, so a zero card count below proves nothing")

        #expect(work.queueItems == 0,
                Comment(rawValue: "scrolling the Archive built \(work.queueItems) cards. The position is "
                        + "bound to the view's own @State inside a body that derives the whole store, so "
                        + "every write SwiftUI makes as a row crosses the top rebuilds all of them "
                        + "(#3437). #1774 fixed this for the Queue by moving the position onto a holder."))
    }
}

// A ModelContext for a container, in one place, because `ModelContext(container)` reads as a constructor
// call at every site and this suite needs it named to say what it is doing.
private enum ContextHolder {
    @MainActor static func make(_ c: ModelContainer) -> ModelContext { ModelContext(c) }
}
