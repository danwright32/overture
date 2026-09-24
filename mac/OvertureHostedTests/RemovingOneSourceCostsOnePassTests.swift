import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #4112: how many times does the Sources sheet rebuild when ONE row is removed?
//
// WHAT WAS MEASURED, on the live app on 2026-09-21. Dan pressed "Stop watching" on FRIGID New York and
// felt a freeze. The log recorded a 2.44s stall with `surface=sourcesSheet` and `passes=8`, then 0.36s
// (2 passes), 0.56s (3) and 0.35s (3) on the same sheet, then 0.60s on the queue as it caught up. Load
// was 4.4, so the Mac was not the cause. Removing ONE row from a 74 row list cost eight rebuilds.
//
// WHAT THE STACK SAMPLE COULD NOT SAY, and why this test is a COUNT rather than a duration. In
// `KEPT-chunk-1790019023.txt` the main thread is idle 71.7% of the ten second window, Overture's own
// frames account for under 3%, and outside the idle wait no single leaf carries even 1%: the cost is
// spread thinly through AppKit and SwiftUI teardown and layout. So the redraw COUNT is the measurement
// here and the per-pass cost is not attributed. A count is also the only half that can sit in a suite:
// it is a statement about this code, where a duration is a statement about the machine (L63, and #3918
// measured what happens when that is forgotten).
//
// THE INSTRUMENT CAME FIRST (L309). Until this change nothing on this surface recorded WHY it
// rebuilt: `QueueRenderCounter` kept a reason trace for the queue and the root only, so `passes=8` was
// the whole of what anybody could know. This suite reads the reasons, so a burst can be attributed
// rather than guessed at, which is what #4112 asks for in as many words.
@MainActor
@Suite("Removing one watched source costs one pass (#4112)")
struct RemovingOneSourceCostsOnePassTests {

    private func container() throws -> ModelContainer {
        try TestModelContainer.inMemory(AppSchema.models)
    }

    // THE REAL COUNT, not a two row fixture. Dan's list held 74 rows when this was measured, and a
    // rebuild burst is exactly the thing a small fixture hides: the work per pass scales with the list,
    // so a two row sheet can rebuild eight times and nobody feels it (L606, L354).
    private static let rows = 74

    private func seed(_ ctx: ModelContext) -> [WatchedSource] {
        var made: [WatchedSource] = []
        for n in 0..<Self.rows {
            let s = WatchedSource(sourceId: "src-\(n)", orgName: "Organisation \(n)",
                                  listingsURL: "https://org\(n).example/events", kind: .html)
            ctx.insert(s)
            made.append(s)
        }
        try? ctx.save()
        return made
    }

    // The feedback object is HELD BY THE TEST and handed in, not created inside the harness.
    //
    // The first version made its own with `@State` and then called the mutation with a throwaway
    // `ActionFeedback()`, so the banner the real button raises was written to an object nothing on
    // screen observed. That is a rig measuring a path the product never takes: every mutation here goes
    // through the environment's feedback, and the undo banner it raises is one of the things that can
    // rebuild this sheet (L472).
    private struct Harness: View {
        let container: ModelContainer
        let prospects: [Prospect]
        let feedback: ActionFeedback

        var body: some View {
            SourcesView(prospects: prospects)
                .modelContainer(container)
                .environment(feedback)
        }
    }

    private func host(_ view: some View) -> (window: NSWindow, hosting: NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // AppKit's default releases the window while this scope still holds it, which crashed the shared
        // app host and truncated the whole hosted target once already (#3480).
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    // Waits until the sheet has GONE QUIET rather than for a fixed time, on
    // `BringingTheQueueUpTests.waitUntilDerivationsGoQuiet`'s precedent and for its reason: the thing
    // being established is an absence, and a fixed settle asserts about how fast the machine is, which
    // is slowest exactly when it is being judged (L290).
    //
    // The layout and display are driven on every poll because this window is never ordered front, so
    // AppKit runs no display cycle of its own for it (#3480).
    @discardableResult
    private func waitUntilQuiet(in hosting: NSView, quietPolls: Int = 25,
                                timeout: Duration = .seconds(20)) async -> Bool {
        var last = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface)
        var quiet = 0
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let now = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface)
            quiet = (now == last) ? quiet + 1 : 0
            last = now
            if quiet >= quietPolls { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    // WHAT THIS RUN IS ALLOWED TO COST. One row leaving the list is one change, so the sheet derives once.
    //
    // DERIVATIONS, not body evaluations, and the difference is the whole finding. SwiftUI re-evaluates
    // a body for reasons a view does not control, and that is cheap; re-running the whole-store
    // derivation is what costs seconds. Holding the count of EVALUATIONS to one would be asking SwiftUI
    // for a guarantee it does not give, and it would fail for reasons that are not defects (L63).
    //
    // TWO, not the one #4112 asks for, and this is that "say why" rather than a number nudged until the
    // suite went green.
    //
    // Measured here after the memo landed: a removal derives twice. The first is the change itself and
    // is not waste. The second is the memo being invalidated by its own subject: `ScopeMemo` builds
    // inside `withObservationTracking`, so the derivation that ran WHILE the delete was propagating read
    // objects the delete then mutated, and that marks the answer stale. One re-derivation after a write
    // that changed what the last one read is correct behaviour, not a defect.
    //
    // WHAT IS NOT KNOWN, said rather than implied. Dan's live measurement was EIGHT passes of this sheet
    // for one removal, and this harness showed TWO before the memo and two after. So this suite cannot
    // say the live case is fixed: it hosts `SourcesView` alone, without `RootView` above it, without the
    // Downbeat roster, and without the coverage and calendar work that only runs when there are clients.
    // The six passes the harness never reproduced are still unaccounted for. What the memo IS proved to
    // remove is the banner case, which `aBannerWithNoDataChangeDerivesNothing` holds at zero and which
    // the reason trace named as the first of the removal's own two.
    //
    // So this is pinned at what it measures, and lowering it is a real improvement somebody can go and
    // make, not an assertion to delete.
    private static let allowedDerivationsForOneRemoval = 2

    @Test func removingOneSourceRebuildsTheSheetOnce() async throws {
        let c = try container()
        let ctx = ModelContext(c)
        let sources = seed(ctx)

        let feedback = ActionFeedback()
        let (window, hosting) = host(Harness(container: c, prospects: [], feedback: feedback))
        defer { window.close() }

        // Let the sheet appear and settle first. What is being measured is the cost of a CHANGE, not the
        // cost of appearing, and folding the two would make a cheap removal on a slow first draw read
        // the same as an expensive one (L63).
        _ = await waitUntilQuiet(in: hosting)
        let before = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface)
        let rendersBefore = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface)
        #expect(rendersBefore > 0, Comment(rawValue:
            "the sheet never rendered at all, so this fixture measures nothing and the count below "
            + "would be zero for the wrong reason (L98)"))
        #expect(before > 0, Comment(rawValue:
            "the sheet never DERIVED at all, so the memo answered a question nobody had asked and the "
            + "count below would be zero because nothing ever ran (L98)"))
        let reasonsBefore = QueueRenderCounter.reasons(for: QueueRenderCounter.sourcesSurface).count

        // ONE row removed, through the same path the button takes.
        WatchlistMutations.stopWatching(sources[0], context: ctx, feedback: feedback)

        _ = await waitUntilQuiet(in: hosting)
        let derivations = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface) - before
        let evaluations = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface) - rendersBefore
        let why = Array(QueueRenderCounter.reasons(for: QueueRenderCounter.sourcesSurface)
            .dropFirst(reasonsBefore))

        // THE POSITIVE CONTROL FIRST. A test asserting a count stays AT OR BELOW one is satisfied by a
        // sheet that never reacted to the removal at all, which is the fixture where the thing could not
        // happen (L159). The removal must produce a derivation before the ceiling means anything.
        #expect(derivations >= 1, Comment(rawValue:
            "removing a row derived the sheet \(derivations) times, so the sheet did not react to the "
            + "removal at all and the ceiling below would pass over a sheet that had stopped working"))
        #expect(derivations <= Self.allowedDerivationsForOneRemoval, Comment(rawValue:
            "removing ONE of \(Self.rows) rows derived the Sources sheet \(derivations) times against "
            + "an allowance of \(Self.allowedDerivationsForOneRemoval), over \(evaluations) body "
            + "evaluation(s). Each derivation is a whole-store pass. What moved before each "
            + "evaluation: \(why.joined(separator: " | ")) (#4112)"))
    }

    // THE CASE THE MEMO EXISTS FOR, asked separately because the removal case cannot answer it.
    //
    // A banner with NO data change is the shape the reason trace named: `feedbackRevision` moved and
    // nothing else did. If the sheet still derives there, then every message Overture shows Dan while
    // this sheet is open costs a whole-store pass, and the removal burst is only the most visible case
    // of it.
    //
    // ZERO derivations, not one. Nothing about the data moved, so there is nothing to re-derive, and
    // "it rebuilt but quickly" is a statement about the machine (L63).
    @Test func aBannerWithNoDataChangeDerivesNothing() async throws {
        let c = try container()
        let ctx = ModelContext(c)
        _ = seed(ctx)

        let feedback = ActionFeedback()
        let (window, hosting) = host(Harness(container: c, prospects: [], feedback: feedback))
        defer { window.close() }

        _ = await waitUntilQuiet(in: hosting)
        let derivationsBefore = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface)
        let rendersBefore = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface)
        #expect(derivationsBefore > 0, Comment(rawValue:
            "the sheet never derived while appearing, so this fixture cannot tell a memo that works "
            + "from one that was never asked (L98)"))

        // A message, and nothing else. No store write, no query change.
        feedback.acknowledge("Stopped watching Organisation 0.")

        _ = await waitUntilQuiet(in: hosting)
        let derivations = QueueRenderCounter.derivationCount(for: QueueRenderCounter.sourcesSurface)
            - derivationsBefore
        let evaluations = QueueRenderCounter.renderCount(for: QueueRenderCounter.sourcesSurface)
            - rendersBefore

        // THE POSITIVE CONTROL. The banner must really have reached the sheet, or a zero below means
        // the message never arrived rather than that the derivation was skipped (L159).
        #expect(evaluations >= 1, Comment(rawValue:
            "raising a banner did not re-evaluate the sheet at all (\(evaluations) evaluations), so "
            + "this fixture never exercised the case and the assertion below proves nothing"))
        #expect(derivations == 0, Comment(rawValue:
            "raising a banner with no data change derived the whole Sources sheet \(derivations) "
            + "time(s) over \(evaluations) body evaluation(s). Every message shown while this sheet "
            + "is open costs a whole-store pass (#4112)"))
    }
}
