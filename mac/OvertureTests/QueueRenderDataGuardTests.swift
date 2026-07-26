import Testing
import Foundation

// #1121: the stage-pill freeze was a per-render multiplier, not a wrong answer. Tapping a pill flipped a
// @State var and invalidated QueueView's body; the body then rebuilt QueueModel.items(from:) (a full map
// that faults every prospect's `recipients` on the main thread) once for EACH of six-plus computed
// properties that read it, and counted the pills in ~10 separate passes over the store.
//
// The fix builds the heavy collections ONCE per render into a RenderData snapshot threaded down, and
// counts the pills in a single pass (StageNavigation.counts). None of that changes what the queue shows,
// so there is no runtime output to assert on: the QueueModel/StageNavigation functions it calls are the
// same ones already unit-tested, and the single-pass count agrees with per-focus navigation by
// construction (StageNavigationCountsTests). What has no other test, and is exactly what silently rots,
// is the SHAPE: if someone reintroduces a standalone `var visible`/`var filtered` computed property, or
// makes AgentInputs.from count per focus again, the freeze comes back with every test still green. This
// guards that shape, the same way MastheadGuardTests / LocationFilterInQueueOnlyGuardTests guard other
// view-only invariants a running test can't reach.
@Suite("The queue builds its derived state once per render (#1121)")
struct QueueRenderDataGuardTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }
    private var agentRoster: String { SourceGuardHelper.source("Overture/Domain/AgentRoster.swift") }

    // The snapshot exists and the body builds it exactly once, at the top, before threading it down.
    @Test func bodyBuildsOneRenderDataSnapshot() {
        #expect(queueView.contains("struct RenderData {"))
        #expect(queueView.contains("private func makeRenderData() -> RenderData {"))
        #expect(queueView.contains("let data = makeRenderData()"))
    }

    // The multiplier is gone: the collections that each used to re-run QueueModel.items(from:) per render
    // no longer exist as standalone computed properties. They live inside makeRenderData now, computed
    // once. Reintroducing any of them as a `private var` is what brings the freeze back, so their absence
    // is the thing worth pinning.
    @Test func theReEvaluatedComputedCollectionsAreGone() {
        #expect(!queueView.contains("private var visible: [QueueItem]"))
        #expect(!queueView.contains("private var filtered: [QueueItem]"))
        #expect(!queueView.contains("private var reachedOutRecipients:"))
        #expect(!queueView.contains("private var reachedOutKeys:"))
        #expect(!queueView.contains("private var disciplines: [String]"))
    }

    // makeRenderData reads the expensive `items` map a single time and derives the rest from that one
    // array, rather than re-reading `self.items` for each field.
    @Test func makeRenderDataReadsItemsOnce() {
        guard let body = SourceGuardHelper.propertyBody(
            "private func makeRenderData() -> RenderData {", in: queueView) else {
            Issue.record("expected to find makeRenderData's body")
            return
        }
        // One binding of the items array, then everything downstream uses that local.
        let occurrences = body.components(separatedBy: "let items = self.items").count - 1
        #expect(occurrences == 1)
    }

    // AgentInputs.from counts every focus through the single pass, not one naturalKeys traversal per
    // focus. Paired with StageNavigationCountsTests, which proves that single pass agrees with the
    // per-focus navigation it replaced.
    @Test func agentInputsCountsInOnePass() {
        // #1570 added a `geo:` argument, so the anchor is the last line of the signature, not the
        // whole of it.
        guard let body = SourceGuardHelper.propertyBody(
            "geo: GeoRefusals = .none) -> AgentInputs {",
            in: agentRoster) else {
            Issue.record("expected to find AgentInputs.from's body")
            return
        }
        #expect(body.contains("StageNavigation.counts("))
        // The old shape counted each focus with its own full navigation pass; that must not come back.
        #expect(!body.contains("StageNavigation.naturalKeys("))
    }
}
