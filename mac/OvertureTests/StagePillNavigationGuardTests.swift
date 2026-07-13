import Testing
import Foundation

// #338: stage pills become real navigation. The actual filtering logic (StageNavigation) is
// unit-tested directly; this guards the view wiring, which has no separate behavioral surface,
// matching this project's existing convention for view-only changes.
@Suite("Stage pill navigation wiring (#338)")
struct StagePillNavigationGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var queueView: String { source("Overture/UI/QueueView.swift") }
    private var rootView: String { source("Overture/App/RootView.swift") }

    // Each pill must actually be tappable now, not just a styled Capsule with .help().
    @Test func agentChipIsWrappedInAButton() {
        #expect(!queueView.isEmpty)
        guard let chipRange = queueView.range(of: "private func agentChip(") else {
            Issue.record("agentChip not found")
            return
        }
        let body = queueView[chipRange.lowerBound...].prefix(400)
        #expect(body.contains("Button"))
    }

    // Prep/Review/Send route through the same criteria AgentRoster uses for their counts. #863: routed by
    // the pill's FOCUS, not its name, so the Send pill's tap follows whichever of its five problems it is
    // actually reporting instead of always resolving the approved queue.
    @Test func stagePillsNavigateByTheirFocus() {
        #expect(queueView.contains("StageNavigation.naturalKeys(for: status.focus"))
        #expect(!queueView.contains("naturalKeys(forStage:"),
                "the name-keyed API cannot express Send's five states and must not come back")
    }

    // Follow-ups reuses the existing FollowUpsView sheet instead of a second filtered-list
    // implementation of the same thing.
    @Test func followUpsPillOpensTheExistingSheet() {
        #expect(queueView.contains("onShowFollowUps"))
        #expect(rootView.contains("onShowFollowUps: { showFollowUps = true }"))
    }
}
