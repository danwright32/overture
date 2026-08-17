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
    // #1913: the derivation moved here, so the guards on its shape moved with it.
    private var renderPass: String { SourceGuardHelper.source("Overture/UI/QueueRenderPass.swift") }
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

    // The pass builds the expensive `items` map a single time and derives the rest from that one array,
    // rather than rebuilding it for each field.
    @Test func makeRenderDataReadsItemsOnce() {
        guard let body = SourceGuardHelper.bodyOfFunction(named: "make", in: renderPass) else {
            Issue.record("expected to find the render pass")
            return
        }
        // One binding of the items array, then everything downstream uses that local.
        let occurrences = body.components(separatedBy: "let items = QueueModel.items(").count - 1
        #expect(occurrences == 1)
    }

    // #1771: the snapshot is the one place a render's derived state lives, so AgentInputs belongs IN it.
    // As a computed property it was built twice per render (once for the pill strip, once for the stage
    // heading), and each build is roughly four full traversals of every prospect and its recipients.
    @Test func theSnapshotCarriesTheAgentInputsSoTheyAreBuiltOnce() {
        #expect(queueView.contains("let agentInputs: AgentInputs"))
        // As a computed property, every reader rebuilt it. That is the shape that must not come back.
        #expect(!queueView.contains("private var agentInputs: AgentInputs {"))
    }

    // #1771: probeSummary took the snapshot and then ignored half of it, calling the expensive `items`
    // computed property fresh. One word, and a whole second rebuild of the queue behind it.
    //
    // #1774 moved the bar into its own view (ProbeSelectionBar), so the same property is now pinned where
    // the inputs are handed over. Re-anchored rather than deleted: the defect it guards against is one
    // word at a call site, and moving the call site does not make the word any harder to write.
    @Test func theProbeBarUsesTheItemsItWasHanded() {
        guard let body = SourceGuardHelper.bodyOfFunction(named: "probeSelectionBar", in: queueView) else {
            Issue.record("expected to find probeSelectionBar's body")
            return
        }
        #expect(body.contains("allItems: data.items"))
        // `allItems: items` there is `self.items`, the computed property that rebuilds the whole queue.
        #expect(!body.contains("allItems: items"))
        // #1916: the rows stay a closure, so an unticked queue never pays for the scoutRows sweep.
        #expect(body.contains("rows: { scoutRows(data) }"))
    }

    // #1772: the same defect one level lower, where it scales with the number of cards rather than
    // running a fixed number of times. Both self-booking lookups sit on paths that run per CARD and per
    // DATE HEADING, and each was rebuilding the entire queue from the store to answer one row's question.
    @Test func theSelfBookingLookupsUseTheItemsTheyWereHanded() {
        // Found by NAME, not by signature. #1922 widened both signatures with the departing keys and
        // #2417 widened them again with the reason each row is leaving, and neither change touched what
        // this guard asks. A marker pinned to the signature as written goes red for that (L103, #2543).
        for name in ["prospectRow", "dateSection"] {
            guard let body = SourceGuardHelper.bodyOfFunction(named: name, in: queueView) else {
                Issue.record("expected to find the body of \(name)")
                continue
            }
            #expect(body.contains("among: data.items"))
            // `among: items` there is `self.items`, the computed property that rebuilds the whole queue.
            #expect(!body.contains("among: items"))
        }
    }

    // AgentInputs.from counts every focus through the single pass, not one naturalKeys traversal per
    // focus. Paired with StageNavigationCountsTests, which proves that single pass agrees with the
    // per-focus navigation it replaced.
    @Test func agentInputsCountsInOnePass() {
        // Anchored on the NAME (#2784): #1570 added a `geo:` argument and #2365 folded it, the day and
        // the instant into one `context:`, and every such change used to move the text this pinned.
        guard let body = SourceGuardHelper.bodyOfFunction(named: "from", in: agentRoster) else {
            Issue.record("expected to find AgentInputs.from's body")
            return
        }
        #expect(body.contains("StageNavigation.counts("))
        // The old shape counted each focus with its own full navigation pass; that must not come back.
        #expect(!body.contains("StageNavigation.naturalKeys("))
    }
}
