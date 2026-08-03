import Testing
import Foundation

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
    // #1913: the derivation moved here, so the guards on its shape moved with it.
    private var renderPass: String { SourceGuardHelper.source("Overture/UI/QueueRenderPass.swift") }

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
        guard let body = SourceGuardHelper.propertyBody("static func make(_ i: Inputs) -> QueueView.RenderData {",
                                                        in: renderPass) else {
            Issue.record("expected to find the render pass")
            return
        }
        // The sweeps are paid once, there, into the snapshot.
        #expect(body.contains("fanOutLine: fanOutWarning("))
        #expect(body.contains("dateGroups: QueueModel.groupByDate("))
        #expect(body.contains("StageNavigation.focusedKeys(stage: i.focusedStage"))
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
        // #1922: the groups are handed to QueueDateGroups, which splices the just-sent cards back in. The
        // property that matters is unchanged: the grouping itself is not redone here.
        #expect(section.contains("QueueDateGroups(groups: data.dateGroups"))
        #expect(!section.contains("QueueModel.groupByDate("))
    }

    // #1922: nor does a send. The four values a send moves through (the outbound timestamp, the reply
    // timestamp, the departing snapshot, the highlighted key) are on SendProgressState, and QueueView
    // reads none of them. File-scoped for the same reason as the ticked date above: a single read
    // anywhere on the body path puts all 724 rows back on every "Sending…".
    @Test func theQueueNeverReadsWhatASendIsDoing() {
        #expect(!queueView.contains("@State private var outboundSending"))
        #expect(!queueView.contains("@State private var replySending"))
        #expect(!queueView.contains("@State private var departing"))
        #expect(!queueView.contains("@State private var highlightedKey"))
        for read in ["sendState.departing", "sendState.highlighted", "sendState.sendingSince(",
                     "sendState.replySendingSince(", "sendState.isDeparting("] {
            #expect(!queueView.contains(read), "QueueView must hand \(read) down, never read it")
        }
    }

    // And the two views that DO read it hand finished values into a closure they run themselves, rather
    // than taking a built view. A view built at the call site is assembled inside QueueView's body, which
    // is the cost this removes arriving one level down (#1774's lesson, again).
    @Test func theSendAwareViewsOwnTheReadAndTakeAClosure() {
        let views = SourceGuardHelper.source("Overture/UI/QueueSendAwareViews.swift")
        #expect(!views.isEmpty)
        guard let groups = SourceGuardHelper.propertyBody(
                "struct QueueDateGroups<Header: View, Content: View>: View {", in: views),
              let row = SourceGuardHelper.propertyBody("struct QueueSendAwareRow<Content: View>: View {",
                                                       in: views) else {
            Issue.record("expected to find both send-aware views")
            return
        }
        #expect(groups.contains("let departing = sendState.departing"))
        #expect(groups.contains("QueueModel.groups(groups, withDeparting: departing)"))
        #expect(groups.contains("@ViewBuilder let content:"))
        // The stack lives HERE, so the ForEach stays a lazy stack's direct child. Nested one view deeper
        // it would be a single child, and every card in the queue would be realized at once.
        #expect(groups.contains("LazyVStack(alignment: .leading, spacing: OVSpacing.xl)"))
        #expect(groups.contains(".scrollTargetLayout()"))
        #expect(row.contains("sendState.sendingSince(key)"))
        #expect(row.contains("@ViewBuilder let content:"))
    }

    // The derivation no longer folds the just-sent rows in. That fold is what made a send re-derive the
    // whole store twice, once to start the leaving delight and once to end it.
    @Test func theDerivationNoLongerFoldsInTheJustSentRows() {
        guard let body = SourceGuardHelper.propertyBody("private func makeRenderData() -> RenderData {",
                                                        in: queueView) else {
            Issue.record("expected to find makeRenderData's body")
            return
        }
        #expect(!body.contains("QueueModel.withDeparting("))
    }

    // #1923: nor does a reply-classify run starting or ending. The line that shows it is its own view, so
    // the observation lands there; read anywhere on this file's body path, `isRunning` would put the whole
    // 724-prospect derivation behind every run, twice, which is the cost the two issues above removed.
    // The activity is CONSTRUCTED here (the line has to be given it) and that is all: naming the type in
    // an argument is not a read, so this asserts against the reads specifically.
    @Test func theQueueNeverReadsWhetherAReplyRunIsLive() {
        #expect(queueView.contains("ReplyRunLine(activity: .replyClassify)"))
        for read in ["DetachedRunActivity.replyClassify.isRunning", "activity.isRunning",
                     ".followUntilFinished(", ".runStarts("] {
            #expect(!queueView.contains(read), "QueueView must hand the activity down, never read \(read)")
        }
    }

    // The jumps (#236 deep link, #308 away alert, #1573) drive the scroll through one parameter that IS
    // @State on QueueView, so an intentional jump always invalidates and always reaches the holder. Pinned
    // because the alternative, relying on each jump happening to write some OTHER piece of state, is an
    // unenforced rule of exactly the kind that broke the stage-pill invariant twice.
    @Test func bothJumpsDriveTheScrollThroughTheDeclaredParameter() {
        #expect(queueView.contains("@State private var jumpTarget: QueueJumpRequest?"))
        for fn in ["private func focusOnLeads(", "private func navigateToLead("] {
            guard let body = SourceGuardHelper.propertyBody(fn, in: queueView) else {
                Issue.record("expected to find \(fn)")
                continue
            }
            #expect(body.contains("jumpTarget = "))
        }
    }
}
