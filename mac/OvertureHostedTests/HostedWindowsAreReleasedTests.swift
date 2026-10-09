import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #3874: a hosted test must leave nothing of its view tree alive.
//
// WHY. Every hosted suite builds an `NSWindow`, puts an `NSHostingView` in it, and ends with
// `defer { window.close() }`. None of them removes the hosting view or clears the content view, and
// `isReleasedWhenClosed = false` is required by `TestWindowsAreNotReleasedOnCloseGuardTests` (it is the
// fix for #3480's crash), so `close()` releases nothing. The SwiftUI graph, its `@Query` machinery and
// the SwiftData autosave timer registered with it therefore outlive the test that made them.
//
// WHAT THAT COSTS. Measured 2026-09-13 by the Ovation session: running the hosted target with
// `-test-iterations 10` killed the test host 8 times, every crash an identical `EXC_BREAKPOINT` inside
// SwiftData reached from a `_SwiftData_SwiftUI` notification observer, on a timer, while XCTest was
// BETWEEN tests. No Overture test code appears anywhere on the stack. A leftover observer being called
// there is what proves something outlived its test (L86).
//
// WHAT THIS FOUND, which is the OPPOSITE of what #3874 was filed claiming. Nothing leaks: with
// `window.close()` and nothing else, no `removeFromSuperview` and no content-view reset, the hosting
// view, the model context and the model container are all released. The teardown that issue proposed
// would therefore have fixed nothing, and this suite exists partly to stop anybody implementing it.
//
// Behavioural rather than a source scan on purpose: a scan can say every suite CALLS a teardown, and
// only a weak reference can say the tree was actually released. The autorelease pool is drained before
// the reading, because a view still in the pool is not yet deallocated and would read as a leak on a
// correct implementation.
@MainActor
@Suite("A hosted test releases its view tree (#3874)")
struct HostedWindowsAreReleasedTests {

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory([Prospect.self, Recipient.self, Inquiry.self, OrgReachabilityAnswer.self, WatchedSource.self, RefusedContactAddress.self, PromotedProducer.self, DemotedHouse.self])
    }

    // Turn the run loop and drain the pool, so a view awaiting release is actually released before the
    // reading. Without this a correct teardown still reads as a leak, which is the false RED that would
    // send the next person to fix code that is already right.
    private func settle() {
        for _ in 0..<10 {
            autoreleasepool {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
        }
    }

    // WHICH PART survives, because the view is not it and #3874 assumed it was.
    //
    // Measured first: the hosting view alone IS released by `window.close()`, with no `removeFromSuperview`
    // and no content-view reset, so the teardown that issue proposed would have fixed nothing. The crash it
    // describes is a SwiftData observer on a timer, so the question is which SwiftData object outlives the
    // test, and a weak reference to each is the only thing that answers it rather than a scan for teardown
    // calls (L3: built is not wired).
    @Test func whichPartOfAHostedTestSurvivesIt() throws {
        weak var weakContainer: ModelContainer?
        weak var weakContext: ModelContext?
        weak var weakHosting: NSHostingView<AnyView>?

        try autoreleasepool {
            let c = try container()
            let ctx = ModelContext(c)
            weakContainer = c
            weakContext = ctx

            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let view = AnyView(RowsFromStore { (rows: [Prospect]) in ArchiveView(rows: QueueEngineRows(everyShow: rows, everyInquiry: [], everySource: [])) }
                .modelContainer(c)
                .environment(ActionFeedback())
                .environment(DayOffOfferRequest()))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = window.contentLayoutRect
            window.contentView?.addSubview(hosting)
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            weakHosting = hosting

            // MIRROR WHAT THE CRASHING NEIGHBOURS ACTUALLY DO, which the first version of this arm did
            // not. The crash lands, every time and on both machines that have seen it, in the moment
            // right after `FeltWaitCostTests.anyWriteAtAllCostsExactlyOnePass` passes. That suite does
            // not merely host: it SEEDS, WRITES and SAVES through the hosted container, and pumps the
            // run loop while SwiftUI rebuilds. A fixture that only builds and tears down exercises none
            // of the machinery a save arms, so its clean result said nothing about the crash (L159).
            for n in 0..<20 {
                ctx.insert(Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n)",
                                    discipline: "music", venue: "Weill Recital Hall",
                                    performanceDate: "2027-01-0\(1 + n % 9)",
                                    sourceListingURL: nil, priorRelationship: "none",
                                    production: "self", profile: "strong",
                                    coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                                    fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                                    possibleMatchName: nil, status: .new))
            }
            try? ctx.save()
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline && (QueueRenderPass.WorkTally.current?.queueRows ?? 0) == 0 {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            let rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? []
            rows.first?.fitScore = 9
            try? ctx.save()
            let settleBy = Date().addingTimeInterval(2)
            while Date() < settleBy {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }

            HostedPassCounting.closeLeavingMounted(window, because: "this suite measures what a bare close releases, so unmounting first would answer a different question (#3874)")
        }
        settle()

        // REPORTED, not asserted, because this arm exists to say WHICH object survives and an assertion
        // would stop the run at the first one rather than printing the set (L11).
        print("""
        hosted-test-survivors (#3874)
          hosting view   \(weakHosting == nil ? "released" : "STILL ALIVE")
          model context  \(weakContext == nil ? "released" : "STILL ALIVE")
          model container\(weakContainer == nil ? " released" : " STILL ALIVE")
        """)
    }

    private func prospect(_ key: String) -> Prospect {
        Prospect(naturalKey: key, groupName: "Ensemble \(key)", discipline: "music", venue: "Weill Recital Hall",
                 performanceDate: "2027-01-01", sourceListingURL: nil, priorRelationship: "none",
                 production: "self", profile: "strong", coverage: "likely_uncovered", fitScore: 5, tier: "mid",
                 fitReason: "r", matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                 status: .new)
    }

    // Hosts `view`, lays it out, turns the run loop briefly, then takes it down the way every counting
    // suite does. What the unmount leaves behind is the question, so nothing here drains a pool.
    private func hostThenUnmount(_ view: some View) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 720),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = window.contentLayoutRect
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        let until = Date().addingTimeInterval(0.3)
        while Date() < until { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        HostedPassCounting.unmountAndClose(window)
    }

    // #4601: WHAT AN UNMOUNT LEAVES IN THE AUTORELEASE POOL, the positive control for the guard in
    // `ViewportSizeTests` (L159): that guard can only refuse a leftover if a leftover can exist.
    //
    // A text field leaves AppKit objects in the current pool, and through them the SwiftUI environment it
    // was built in. Everything that environment holds outlives the unmount until the pool drains, the
    // store's main context included, which is the half of #4601's crash this measures. The STORE is held
    // by this test throughout, so the context can never be left without it here and nothing below can
    // trap: the environment object beside the context is what is weighed instead.
    //
    //   this reads released     the leftover is gone, and `releasingWhatItHosts` guards nothing any more
    //   the pooled arm is alive the pool no longer ends what a hosted view made, and #4601 is back
    @Test func aTextFieldKeepsAnUnmountedViewsEnvironmentUntilThePoolDrains() throws {
        let c = try container()
        // Read INSIDE an outer pool, so the leftover this arm makes on purpose is gone again, with the store
        // still held, before the test returns.
        var unpooledSurvived = false
        autoreleasepool {
            weak var unpooled: ActionFeedback?
            do {
                let feedback = ActionFeedback()
                unpooled = feedback
                hostThenUnmount(TextField("unpooled", text: .constant("")).modelContainer(c).environment(feedback))
            }
            unpooledSurvived = unpooled != nil
        }
        weak var pooled: ActionFeedback?
        HostedPassCounting.releasingWhatItHosts {
            let feedback = ActionFeedback()
            pooled = feedback
            hostThenUnmount(TextField("pooled", text: .constant("")).modelContainer(c).environment(feedback))
        }
        #expect(unpooledSurvived, Comment(rawValue: "an unmounted text field's environment was released "
            + "before the pool drained, so the leftover #4601 crashed on no longer forms and "
            + "ViewportSizeTests' guard is refusing a state that cannot occur"))
        #expect(pooled == nil, Comment(rawValue: "a text field unmounted inside "
            + "HostedPassCounting.releasingWhatItHosts still holds its environment, so the pool no longer "
            + "ends what a hosted view made and a store dropped after it can leave a live context behind "
            + "(#4601)"))
        withExtendedLifetime(c) {}
    }

    // #4601: THE APP'S OWN SHAPE, which is what decides whether the crash could ever be Dan's. In the app a
    // window holding a live query and a text field closes (the Archive sheet), and a save follows in the
    // same turn, before any pool drains. The difference from the crashing test is only that the store is
    // still alive, because Overture builds one in `OvertureApp.init` and holds it for the life of the
    // process. Saved through a second context, as a background write does, and through the main context,
    // as an action does. A trap here kills the host, which is this test failing loudly.
    @Test func savingRightAfterAnArchiveClosesIsSafeWhileItsStoreLives() throws {
        let c = try container()
        let seeding = ModelContext(c)
        seeding.insert(prospect("seeded"))
        try seeding.save()
        // The close and both saves share one pool, so they happen while the leftover is alive, as in the
        // app; it is drained before the test returns, with the store still held.
        var leftoverAliveAtTheSaves = false
        try autoreleasepool {
            weak var leftover: ActionFeedback?
            do {
                let feedback = ActionFeedback()
                leftover = feedback
                hostThenUnmount(RowsFromStore { (rows: [Prospect]) in ArchiveView(rows: QueueEngineRows(everyShow: rows, everyInquiry: [], everySource: [])) }
                    .modelContainer(c)
                    .environment(feedback)
                    .environment(DayOffOfferRequest()))
            }

            let background = ModelContext(c)
            background.insert(prospect("after-close-background"))
            try background.save()
            c.mainContext.insert(prospect("after-close-main"))
            try c.mainContext.save()
            leftoverAliveAtTheSaves = leftover != nil
        }

        // Without the leftover these saves prove nothing about the crash's shape (L159).
        #expect(leftoverAliveAtTheSaves, Comment(rawValue: "the closed Archive's environment was already "
            + "released when the saves ran, so this did not save beside a leftover the way the app can"))
        #expect(try ModelContext(c).fetchCount(FetchDescriptor<Prospect>()) == 3, Comment(rawValue:
            "both saves after the Archive closed should have landed beside the seeded row"))
    }

    @Test func theHostingViewIsDeallocatedAfterTheTestThatBuiltIt() throws {
        let c = try container()
        weak var escaped: NSHostingView<AnyView>?

        autoreleasepool {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            // Required by `TestWindowsAreNotReleasedOnCloseGuardTests` and not negotiable here: AppKit's
            // default releases a window this scope still holds, which is #3480's crash.
            window.isReleasedWhenClosed = false
            let view = AnyView(RowsFromStore { (rows: [Prospect]) in ArchiveView(rows: QueueEngineRows(everyShow: rows, everyInquiry: [], everySource: [])) }
                .modelContainer(c)
                .environment(ActionFeedback())
                .environment(DayOffOfferRequest()))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = window.contentLayoutRect
            window.contentView?.addSubview(hosting)
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            escaped = hosting

            HostedPassCounting.closeLeavingMounted(window, because: "this suite measures what a bare close releases, so unmounting first would answer a different question (#3874)")
        }
        settle()

        #expect(escaped == nil, Comment(rawValue:
                "the hosting view is still alive after the test that built it finished, so its SwiftUI "
                + "graph, its @Query machinery and the SwiftData autosave timer registered with it are "
                + "still running. That is what kills the test host between tests under repeated runs "
                + "(#3874). Tearing the window down must release the tree, not merely close the window."))
    }
}
