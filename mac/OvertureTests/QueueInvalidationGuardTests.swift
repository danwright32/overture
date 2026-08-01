import Testing
import Foundation
@testable import Overture

// #1774: what a scroll is allowed to cost.
//
// `.scrollPosition(id:)` is a READ-WRITE binding, so SwiftUI writes it every time a date heading crosses
// the top of the queue. While it was bound to @State on QueueView, each of those writes invalidated the
// whole body, whose first line derives the entire store: QueueModel.items over 724 prospects,
// AgentInputs.from, StageNavigation.queueKeys and focusedKeys, ReachedOutQueue.activeWithDates,
// PossibleMatchFanOut.findings and groupByDate. Scrolling past ten dates paid all of it ten times.
//
// The fix is structural: the scroll position lives on QueueScrollHolder, and @State belongs to the view
// that declares it, so writing it cannot invalidate a parent. QueueView builds its RenderData snapshot
// and hands the content down as a closure, which the holder runs; a scroll therefore re-runs the
// rendering and never the derivation.
//
// None of that produces an observable output a running test can assert on, and QueueView.body cannot be
// evaluated in a unit test at all (nine @Query properties need a live container). What CAN rot, silently
// and with every other test still green, is the shape. So this guards the shape, the way
// QueueRenderDataGuardTests and MastheadGuardTests guard other view-only invariants.
//
// Deliberately FILE-scoped rather than function-scoped. An earlier draft of this suite named three
// functions on the body path; QueueView has about a dozen, so a reintroduced read in prospectRow or
// focusedSection would have sailed past it. Asserting over the whole file cannot rot as functions are
// added, which is L30 applied to the guard itself.
@Suite("A scroll cannot reach the queue's derivation (#1774)")
struct QueueInvalidationGuardTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    // The scroll position is not QueueView's own state. This is the whole fix in one assertion: as
    // QueueView state every scroll write re-derived the store, and no other test in the suite can see it.
    @Test func theScrollPositionIsNotStateOnTheQueueItself() {
        #expect(!queueView.isEmpty)
        guard let queue = SourceGuardHelper.propertyBody("struct QueueView: View {", in: queueView) else {
            Issue.record("expected to find QueueView")
            return
        }
        #expect(!queue.contains("@State private var topGroup"))
    }

    // The holder exists, declares the scroll position itself, and is the only thing wearing the modifier.
    @Test func theHolderOwnsTheScrollPositionAndTheModifier() {
        guard let holder = SourceGuardHelper.propertyBody("struct QueueScrollHolder<Content: View>: View {",
                                                          in: queueView) else {
            Issue.record("expected to find QueueScrollHolder")
            return
        }
        #expect(holder.contains("@State private var topGroup: String?"))
        #expect(holder.contains(".scrollPosition(id: $topGroup, anchor: .top)"))
    }

    // The content arrives as a closure, NOT as a built view. A built view would be constructed in
    // QueueView.body, which is exactly the cost this removes: the masthead and the whole date list would
    // be assembled on every scroll frame again, just one level further down.
    @Test func theContentIsHandedDownAsAClosureNotABuiltView() {
        guard let holder = SourceGuardHelper.propertyBody("struct QueueScrollHolder<Content: View>: View {",
                                                          in: queueView) else {
            Issue.record("expected to find QueueScrollHolder")
            return
        }
        #expect(holder.contains("@ViewBuilder let content: () -> Content"))
    }

    // The ticked reachability dates are not QueueView's state either (#1774 phase 2), and nothing in this
    // file reads one. A single read anywhere on the body path puts the dependency straight back and one
    // checkbox re-derives all 724 rows again, which is why this is asserted over the file rather than
    // over the handful of functions that happen to be involved today.
    @Test func theQueueNeverReadsATickedDate() {
        #expect(!queueView.contains("@State private var selectedProbeDates"))
        #expect(!queueView.contains("probeSelection.contains("))
        #expect(!queueView.contains("probeSelection.dates"))
    }

    // The expensive whole-store derivations happen in makeRenderData, above the closure, so the closure
    // the holder re-runs has nothing left to derive. The fan-out scan is the one that hid: it sweeps every
    // prospect and was passed as an ARGUMENT to the masthead from inside the scroll content, and an
    // argument evaluates at its call site, so it ran on every scroll frame while looking like it belonged
    // to the masthead (#1916's lesson, one level up).
    @Test func theWholeStoreSweepsHappenAboveTheScrollContent() {
        guard let body = SourceGuardHelper.propertyBody("private func makeRenderData() -> RenderData {",
                                                        in: queueView) else {
            Issue.record("expected to find makeRenderData's body")
            return
        }
        // The sweeps are paid once, here, into the snapshot.
        #expect(body.contains("fanOutLine: fanOutWarning"))
        #expect(body.contains("dateGroups: QueueModel.groupByDate("))
        #expect(body.contains("StageNavigation.focusedKeys(stage: focusedStage"))
        #expect(queueView.contains("let fanOutLine: String?"))
        #expect(queueView.contains("let dateGroups: [QueueModel.DateGroup]"))

        // And the scroll content only READS them. `fanOutLine: fanOutWarning` at the masthead call is the
        // exact shape that made a whole-store sweep run per scroll frame while looking like the masthead's
        // business, so the masthead must be handed the finished value instead.
        guard let scroll = SourceGuardHelper.propertyBody(
            "private func queueScroll(_ data: RenderData) -> some View {", in: queueView) else {
            Issue.record("expected to find queueScroll's body")
            return
        }
        #expect(scroll.contains("fanOutLine: data.fanOutLine"))
        #expect(!scroll.contains("fanOutLine: fanOutWarning"))
        // Likewise the grouping: re-derived in the list it would run on every scroll frame.
        guard let section = SourceGuardHelper.propertyBody(
            "@ViewBuilder private func focusedSection(data: RenderData) -> some View {", in: queueView) else {
            Issue.record("expected to find focusedSection's body")
            return
        }
        #expect(section.contains("ForEach(data.dateGroups)"))
        #expect(!section.contains("QueueModel.groupByDate("))
    }

    // The jumps (#236 deep link, #308 away alert, #1573) drive the scroll through one parameter that IS
    // @State on QueueView, so an intentional jump always invalidates and always reaches the holder. Pinned
    // because the alternative, relying on each jump happening to write some OTHER piece of state, is an
    // unenforced rule of exactly the kind that broke the stage-pill invariant twice.
    @Test func bothJumpsDriveTheScrollThroughTheDeclaredParameter() {
        #expect(queueView.contains("@State private var jumpTarget: String?"))
        for fn in ["private func focusOnLeads(", "private func navigateToLead("] {
            guard let body = SourceGuardHelper.propertyBody(fn, in: queueView) else {
                Issue.record("expected to find \(fn)")
                continue
            }
            #expect(body.contains("jumpTarget = "))
        }
    }
}
