import Testing
import Foundation

// #1134/#1129: the stage-only redesign is mostly view wiring, which a running test can't reach (a
// SwiftUI view isn't unit-testable in isolation, the same reason the other *GuardTests scan source).
// The behavioural rules are proven in ReachedOutStageTests / StageEmptyStateTests / PrepQueueButtonTests
// against pure helpers; this pins that QueueView actually calls them, so cutting any wire turns a test
// red instead of silently reintroducing the old blended pipeline.
@Suite("Stage-only navigation and the discoverable Prep button are wired (#1134/#1129)")
struct StageOnlyNavWiringGuardTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    // The blended pipeline is gone: no segmented Pipeline picker, no Pipeline enum, no filter bar.
    @Test func theBlendedPipelineIsGone() {
        #expect(!queueView.contains("Picker(\"Pipeline\""))
        #expect(!queueView.contains("enum Pipeline"))
        #expect(!queueView.contains("pipelineContent"))
    }

    // The Reached out stage renders its per-recipient list (not the standard natural-key rows).
    @Test func theReachedOutStageRendersReachedOutList() {
        guard let body = SourceGuardHelper.bodyOfFunction(named: "focusedSection", in: queueView) else {
            Issue.record("expected focusedSection's body"); return
        }
        #expect(body.contains("if focusedStage == .reachedOut"))
        #expect(body.contains("reachedOutList(data.reachedOut)"))
    }

    // #1129: the Prep stage view shows the discoverable button (gated by the tested PrepQueueButton) and
    // its tap starts a run through RootView's closure.
    @Test func thePrepButtonIsGatedAndWired() {
        #expect(queueView.contains("var onStartPrep: () -> Void = {}"))
        guard let body = SourceGuardHelper.bodyOfFunction(named: "focusedSection", in: queueView) else {
            Issue.record("expected focusedSection's body"); return
        }
        #expect(body.contains("PrepQueueButton.shouldShow(stage: focusedStage"))
        #expect(body.contains("onStartPrep()"))
    }

    // RootView threads the Prep-start closure into the SAME per-run selection sheet the toolbar menu and
    // Cmd+P open, so there is one Prep-start path, not two.
    @Test func rootViewWiresOnStartPrepToTheSelectionSheet() {
        #expect(rootView.contains("onStartPrep: { showPrepSelection = true }"))
    }
}
