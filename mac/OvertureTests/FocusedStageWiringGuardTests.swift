import Testing
import Foundation

// #1140: the behavioural rule (a stage list tracks live membership) is proven in
// FocusedStageMembershipTests against StageNavigation.focusedKeys. What no running test can reach is the
// WIRING inside QueueView: that the focused list actually calls that live re-derivation, and that every
// exit leaves stage mode. A SwiftUI view isn't unit-testable in isolation (the same reason
// MastheadGuardTests / LocationFilterInQueueOnlyGuardTests scan source), so this guards the wiring's
// shape: cut any of these and the freeze-in-place bug returns with every other test still green.
@Suite("The focused list re-derives stage membership live (#1140)")
struct FocusedStageWiringGuardTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    // The focused list resolves its rows through the tested live dispatcher, not by filtering a frozen
    // key array captured at tap time.
    @Test func focusedSectionResolvesMembershipLive() {
        guard let body = SourceGuardHelper.propertyBody(
            "private func focusedSection(_ keys: [String], data: RenderData) -> some View {",
            in: queueView) else {
            Issue.record("expected to find focusedSection's body")
            return
        }
        #expect(body.contains("StageNavigation.focusedKeys(stage: focusedStage"))
    }

    // Tapping a stage pill records the stage (so the list can re-derive), and every exit clears it, so a
    // later render can't keep re-deriving a stage Dan has left.
    @Test func stageIsSetOnEntryAndClearedOnEveryExit() {
        // Set when a pill is tapped.
        guard let focusOnStage = SourceGuardHelper.propertyBody(
            "private func focusOnStage(_ status: AgentStatus) {", in: queueView) else {
            Issue.record("expected focusOnStage's body"); return
        }
        #expect(focusOnStage.contains("focusedStage = status.focus"))

        // Cleared by "Show all", by the away-alert leads path, and by a deep-link navigation.
        #expect(queueView.contains("focusedKeys = nil; focusedHeading = nil; focusedStage = nil"))
        guard let focusOnLeads = SourceGuardHelper.propertyBody(
            "private func focusOnLeads(_ keys: [String], proxy: ScrollViewProxy) {", in: queueView) else {
            Issue.record("expected focusOnLeads's body"); return
        }
        #expect(focusOnLeads.contains("focusedStage = nil"))
        guard let navigateToLead = SourceGuardHelper.propertyBody(
            "private func navigateToLead(_ key: String, proxy: ScrollViewProxy) {", in: queueView) else {
            Issue.record("expected navigateToLead's body"); return
        }
        #expect(navigateToLead.contains("focusedStage = nil"))
    }
}
