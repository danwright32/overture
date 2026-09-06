import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #1930: how many times does the queue derive the whole store just to appear?
//
// Measured on the running Debug app on 2026-08-01: FIVE derivations at launch, four of them reporting
// `nothing this view reads`, which means the invalidation arrived from outside the queue rather than from
// anything it looks at. That reading has stood as the issue's evidence ever since, and the only way to
// take it again was to launch the app and read a log by hand, which is why it was taken twice in a month
// and not since.
//
// This is that reading, in the suite. It counts `QueueRenderCounter.derivations`, which is the app's own
// counter and the same one the Debug masthead shows, around bringing a real `QueueView` up in a real
// window. Not a reimplementation: it is the number the app reports about itself (L107).
//
// WHAT IT IS AND IS NOT. This brings up the QUEUE, not the whole app: `RootView`'s own launch work, the
// reattach passes, the client roster load and the scout check are not here. So it is a FLOOR on the
// launch burst rather than the whole of it, and the issue's own finding was that the extra derivations
// arrive from ABOVE the queue, which this cannot see. What it can do is hold the queue's own half to a
// number on every push, which nothing did before.
@MainActor
@Suite("What bringing the queue up costs (#1930)")
struct BringingTheQueueUpTests {

    // The queue derives the whole store ONCE to appear. Anything above one is a re-derivation of data
    // that has not changed, which is the whole of what #1930 is about.
    private static let allowedDerivationsToAppear = 1

    // The same question of the whole screen. Deliberately its own number rather than the one above: the
    // queue's half and the app's half are different quantities, and folding them would hide which one
    // moved (L63).
    //
    // WHAT THE ATTRIBUTION EXPERIMENTS SAID, recorded because two of the three were misleading and the
    // next person will run the same ones. Removing `reportAnyBoundaryViolation()` from the launch task
    // drops the count to one. So does removing `freezeWatch.start(...)`. Neither is the cause: making
    // `FreezeWatch.isWatching` non-observable, which is the only way either of those could invalidate a
    // view, leaves the count at TWO. Removing any line from that task shifts when its writes land
    // relative to the first render, and two renders coalesce into one. A cause inferred from two things
    // co-occurring is not established until you find the case where the suspected cause is present and
    // the effect is absent (L203), and that is what the third experiment is.
    //
    // TWO, and the second is #1930's remaining instance. The queue's own half is ONE, so the extra
    // derivation is provoked from above it, which is exactly what the issue's original reading said:
    // four of its five reported that nothing the queue reads had moved. It is measured here rather than
    // argued about, and pinned so it cannot become three.
    private static let allowedDerivationsForTheWholeApp = 2

    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self,
                                        OrgReachabilityAnswer.self, WatchedSource.self,
                                        RefusedContactAddress.self, PromotedProducer.self,
                                        DemotedHouse.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func seed(_ ctx: ModelContext, rows: Int) {
        let dates = LiveDateClustering.dates(forRows: rows)
        for n in 0..<rows {
            let p = Prospect(naturalKey: "row-\(n)", groupName: "Ensemble \(n % 90)", discipline: "music",
                             venue: "Venue \(n % 169) Hall", performanceDate: dates[n],
                             sourceListingURL: nil, priorRelationship: "none",
                             production: n % 3 == 0 ? "self" : "presenter", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5), tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: n % 3 == 0 ? .drafted : .new)
            p.presenter = "Ensemble \(n % 90) Presents"
            p.location = "New York, NY"
            ctx.insert(p)
        }
        try? ctx.save()
    }

    private struct Harness: View {
        let container: ModelContainer
        @State private var deepLinkedKey: LeadDeepLink?
        @State private var deepLinkedKeys: LeadsDeepLink?
        @State private var feedback = ActionFeedback()
        @State private var dayOffOffer = DayOffOfferRequest()

        var body: some View {
            QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys)
                .modelContainer(container)
                .environment(feedback)
                .environment(dayOffOffer)
        }
    }

    private func host(_ view: some View) -> (window: NSWindow, hosting: NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // AppKit's default releases the window while this scope still holds it, which crashed the shared
        // app host and truncated the whole hosted target (#3480).
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    // The half above the queue, which is where #1930's own finding says the extra derivations came from:
    // four of its five reported `nothing this view reads`, meaning nothing the queue looks at had moved,
    // so the invalidation arrived from the screen above it.
    //
    // Hosting `RootView` is how that becomes measurable at all. It is the view the app launches into, and
    // its own launch work (the reattach passes, the roster load, the notices) runs here as it does there.
    private struct RootHarness: View {
        let container: ModelContainer
        @State private var addLead: AddLeadPresenter
        @State private var undoStack = QueueUndoStack()
        @State private var undoRequest = QueueUndoRequest()

        init(container: ModelContainer) {
            self.container = container
            // Built the way `OvertureApp` builds it, from the container, rather than from a default that
            // would put this harness in the degraded no-store state the real app is never in here.
            _addLead = State(initialValue: AddLeadPresenter(store: container))
        }

        var body: some View {
            RootView()
                .modelContainer(container)
                .environment(addLead)
                .environment(undoStack)
                .environment(undoRequest)
        }
    }


    // Wait until the derivation count has GONE QUIET, rather than for a fixed time.
    //
    // The thing being established is an ABSENCE: that no further derivation arrives once the first has.
    // A fixed settle asserts about how fast the machine is, and it is slowest exactly when the machine is
    // loaded, which is when it is judged (L290). This exits as soon as the count has been unchanged for
    // `quietPolls` consecutive reads, so the ordinary case is fast and only a count that keeps climbing
    // runs out the deadline.
    //
    // The layout and display are driven on every poll because this window is never ordered front, so
    // AppKit runs no display cycle of its own for it (#3480).
    @discardableResult
    private func waitUntilDerivationsGoQuiet(in hosting: NSView, quietPolls: Int = 25,
                                             timeout: Duration = .seconds(20)) async -> Bool {
        var last = QueueRenderCounter.derivations
        var quiet = 0
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let now = QueueRenderCounter.derivations
            quiet = (now == last) ? quiet + 1 : 0
            last = now
            if quiet >= quietPolls { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func bringingTheWholeAppUpDerivesTheStoreOnce() async throws {
        let c = try container()
        let ctx = ModelContext(c)
        seed(ctx, rows: 60)

        let before = QueueRenderCounter.derivations
        let (window, hosting) = host(RootHarness(container: c))
        defer { window.close() }

        // EVERY reason, not just the last. #1930 has never had this: its evidence is a log read by hand
        // after the fact, and the whole of its diagnosis turns on WHICH inputs had moved before each
        // derivation. A reason sampled only at the end names one of them and hides the rest.
        var reasons: [String] = []
        var seen = before
        func sample() {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            while QueueRenderCounter.derivations > seen {
                seen += 1
                reasons.append(QueueRenderCounter.lastReason)
            }
        }
        _ = await waitUntil("the app to derive at least once", timeout: .seconds(30)) {
            sample()
            return QueueRenderCounter.derivations > before
        }
        let settled = await waitUntilDerivationsGoQuiet(in: hosting)

        let derivations = QueueRenderCounter.derivations - before
        print("""
        bringing-the-queue-up: what the WHOLE app costs to appear (#1930)
          whole-store derivations   \(derivations)
          reasons, in order         \(reasons)

          READ THE COUNT, NOT THE REASONS. `QueueRenderCounter` is process-global and compares each
          derivation against the PREVIOUS one in the process, so in a suite where other tests have
          already rendered, the first reason here is relative to some other test's last derivation
          rather than to nothing. The count is a delta and is sound; the reasons are only trustworthy on
          a real launch, where the app's own first derivation is genuinely first.
        """)

        #expect(settled, "the count never went quiet, so this is a reading taken mid-flight")
        #expect(derivations > 0,
                Comment(rawValue: "the app never derived at all, so this counted a screen that never "
                        + "appeared rather than the cost of it appearing"))
        #expect(derivations <= Self.allowedDerivationsForTheWholeApp,
                Comment(rawValue: "bringing the app up derived the whole store \(derivations) times, "
                        + "against \(Self.allowedDerivationsForTheWholeApp) allowed. #1930 measured five "
                        + "on the running app, four of them reporting that nothing the queue reads had "
                        + "moved."))
    }

    @Test func theQueueDerivesTheStoreOnceToAppear() async throws {
        let c = try container()
        let ctx = ModelContext(c)
        seed(ctx, rows: 60)

        let before = QueueRenderCounter.derivations
        let (window, hosting) = host(Harness(container: c))
        defer { window.close() }

        // Settle for a fixed number of the run loop's own turns rather than a wall-clock wait: what is
        // being counted is derivations, and the question is whether any MORE arrive once the first has
        // happened. Driven explicitly because this window is never ordered front, so AppKit runs no
        // display cycle of its own for it (#3480, and FeltWaitCostTests's own header).
        _ = await waitUntil("the queue to derive at least once", timeout: .seconds(20)) {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            return QueueRenderCounter.derivations > before
        }
        // And then wait for the count to GO QUIET, so a second derivation arriving late is counted rather
        // than missed. That is the half that matters: the defect #1930 describes is extra derivations
        // after the first.
        let settled = await waitUntilDerivationsGoQuiet(in: hosting)

        let derivations = QueueRenderCounter.derivations - before
        print("""
        bringing-the-queue-up: what the queue costs to appear (#1930)
          whole-store derivations   \(derivations)
          last reason               \(QueueRenderCounter.lastReason)

          Measured on the running Debug app 2026-08-01 as FIVE at launch, four of them reporting
          `nothing this view reads`. This counts the QUEUE's own half only: RootView's launch work is
          not here, so it is a floor on the burst rather than the whole of it.
        """)

        // The measurement is real before anything is concluded from it: a harness that rendered nothing
        // reports zero, which is the emptiest possible result reading as the cheapest possible one (L98).
        #expect(settled, "the count never went quiet, so this is a reading taken mid-flight")
        #expect(derivations > 0,
                Comment(rawValue: "the queue never derived at all, so this counted a view that never "
                        + "appeared rather than the cost of it appearing"))
        #expect(derivations <= Self.allowedDerivationsToAppear,
                Comment(rawValue: "bringing the queue up derived the whole store \(derivations) times, "
                        + "against \(Self.allowedDerivationsToAppear) allowed. Every one past the first "
                        + "is a re-derivation of data that has not changed, which is what #1930 is "
                        + "about, and on the live store each costs about 750 ms."))
    }
}
