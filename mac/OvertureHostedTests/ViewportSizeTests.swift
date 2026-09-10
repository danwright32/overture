import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #3751: how many rows a frame actually draws, measured rather than assumed.
//
// WHAT THIS IS ABOUT. `QueueRenderPassLiveStoreCostTests.viewportRows` is 12, and everything this
// milestone claims about the shipping pass is measured through it. Its reason, written beside it, is that
// 12 is "above what a laptop window shows and below what a tall one does, so the narrowed reading is a
// conservative one". That was a guess made in good faith and nothing had ever checked it. If the real
// viewport is 25 the narrowed arm is understated and nothing would say so (L354).
//
// NO DURABLE CHANNEL IS NEEDED, which is what makes this cheap. The first plan was to record the size
// from the running app, and that needs a decision about where the number goes, at what cadence, and what
// survives the app being killed. It is not needed: the count is a property of the LAYOUT, and the layout
// can be driven here. A `LazyVStack` realizes the rows it can draw, each realized row asks the store for
// its card through `CardStore.card(for:)`, and `WorkTally` counts those. So the number of cards a first
// frame builds IS the viewport.
//
// WHAT IT CANNOT SEE, said plainly. This measures the rows AppKit realizes when it lays the view out in a
// window of a stated size, which is not necessarily the number Dan can see: a lazy stack routinely
// realizes a little beyond the visible edge, and this rig never orders its window on screen (#3480). So
// the reading is an UPPER bound on what is visible, which is the direction that matters: `viewportRows`
// has to be at least the real viewport for the cost instrument's narrowed arm to stay the conservative
// reading it claims to be.
@MainActor
@Suite("How many rows a frame really draws (#3751)")
struct ViewportSizeTests {

    // The window sizes Archive can actually be at, from its own frame: `minHeight: 520, idealHeight: 720,
    // maxHeight: 900`. The tallest is what decides the answer, because `viewportRows` must cover the
    // worst case rather than the usual one.
    private static let idealSize = NSSize(width: 780, height: 720)
    private static let tallestSize = NSSize(width: 960, height: 900)

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        OrgReachabilityAnswer.self, WatchedSource.self,
                                        RefusedContactAddress.self, PromotedProducer.self,
                                        DemotedHouse.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Far more rows than any window can show, so the count below is the viewport's and not the corpus's.
    private func seed(_ ctx: ModelContext, rows: Int = 300) {
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

    private func host(_ view: some View, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
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
        return window
    }

    /// Cards built while the view lays out once, which is one per realized row.
    private func rowsRealized(at size: NSSize) throws -> Int {
        let c = try container()
        seed(ContextHolder.make(c))
        let view = ArchiveView()
            .modelContainer(c)
            .environment(ActionFeedback())
            .environment(DayOffOfferRequest())

        var window: NSWindow?
        let work = QueueRenderPass.WorkTally.measure {
            window = host(view, size: size)
            // Layout can finish on a later turn of the run loop, so the tally must stay bound while it
            // does. Waits on the CONDITION rather than a fixed time (L290): it stops as soon as anything
            // has been drawn and only runs out its deadline when nothing is, which is the case with
            // nothing to wait for.
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline && (QueueRenderPass.WorkTally.current?.queueItems ?? 0) == 0 {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        window?.close()
        return work.queueItems
    }

    /// The height one row implies, from the two readings. Reported rather than asserted: it is evidence
    /// that the numbers are geometry, and pinning it would be pinning the card's design.
    private func impliedRowHeight(_ atIdeal: Int, _ atTallest: Int) -> String {
        let extraRows = atTallest - atIdeal
        guard extraRows > 0 else { return "not measurable, both sizes realized the same count" }
        let extraHeight = Self.tallestSize.height - Self.idealSize.height
        return String(format: "%.0f", extraHeight / Double(extraRows))
    }

    @Test("the tallest window Archive allows realizes fewer rows than the cost instrument assumes")
    func theAssumedViewportCoversTheRealOne() throws {
        let atIdeal = try rowsRealized(at: Self.idealSize)
        let atTallest = try rowsRealized(at: Self.tallestSize)

        print("""
        viewport-size: rows a frame realizes (#3751)
          at \(Int(Self.idealSize.width))x\(Int(Self.idealSize.height)), Archive's ideal    \(atIdeal)
          at \(Int(Self.tallestSize.width))x\(Int(Self.tallestSize.height)), Archive's tallest  \(atTallest)
          the cost instrument assumes                     \(QueueViewportAssumption.rows)

          implied row height, from the difference:       \(impliedRowHeight(atIdeal, atTallest)) pt
          That the count SCALES with the window is the evidence these are real geometry rather
          than a rig that under realizes because its window is never on screen: 180pt more
          window buys about one more card, and an Archive card is a tall thing.
        """)

        // The measurement is REAL before anything is concluded from it: a layout that realized nothing
        // gives zero, and zero is below any assumption, so it would satisfy the claim below while proving
        // the opposite (L98).
        #expect(atIdeal > 0, "the ideal sized window realized no row at all, so nothing was measured")
        #expect(atTallest > 0, "the tallest window realized no row at all, so nothing was measured")
        // And the tallest really is taller, or both readings are of one size.
        #expect(atTallest >= atIdeal,
                Comment(rawValue: "a 900pt window realized \(atTallest) rows and a 720pt one \(atIdeal), "
                        + "which cannot be true and means the size is not reaching the layout"))

        // THE CLAIM. `viewportRows` must be at least the worst case, or the cost instrument's narrowed
        // arm is not the conservative reading it says it is.
        #expect(QueueViewportAssumption.rows >= atTallest,
                Comment(rawValue: "the cost instrument assumes a \(QueueViewportAssumption.rows) row "
                        + "viewport and the tallest window Archive allows realizes \(atTallest). The "
                        + "narrowed arm is then measuring a SMALLER viewport than the app can have, so "
                        + "the pass cost it reports is understated and its own comment calling it "
                        + "conservative is false (#3751, L354)."))
    }
}

// A ModelContext for a container, in one place, on `ArchiveScrollDoesNotRebuildTests`'s precedent.
private enum ContextHolder {
    @MainActor static func make(_ c: ModelContainer) -> ModelContext { ModelContext(c) }
}
