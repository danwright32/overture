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
            let view = AnyView(RowsFromStore { (rows: [Prospect]) in ArchiveView(prospects: rows) }
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

            window.close()
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

    @Test func theHostingViewIsDeallocatedAfterTheTestThatBuiltIt() throws {
        let c = try container()
        weak var escaped: NSHostingView<AnyView>?

        autoreleasepool {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            // Required by `TestWindowsAreNotReleasedOnCloseGuardTests` and not negotiable here: AppKit's
            // default releases a window this scope still holds, which is #3480's crash.
            window.isReleasedWhenClosed = false
            let view = AnyView(RowsFromStore { (rows: [Prospect]) in ArchiveView(prospects: rows) }
                .modelContainer(c)
                .environment(ActionFeedback())
                .environment(DayOffOfferRequest()))
            let hosting = NSHostingView(rootView: view)
            hosting.frame = window.contentLayoutRect
            window.contentView?.addSubview(hosting)
            window.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            escaped = hosting

            window.close()
        }
        settle()

        #expect(escaped == nil, Comment(rawValue:
                "the hosting view is still alive after the test that built it finished, so its SwiftUI "
                + "graph, its @Query machinery and the SwiftData autosave timer registered with it are "
                + "still running. That is what kills the test host between tests under repeated runs "
                + "(#3874). Tearing the window down must release the tree, not merely close the window."))
    }
}
