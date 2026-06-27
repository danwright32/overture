import Testing
import Foundation
@testable import Overture

// #270 / Phase 6: first-run onboarding moves every interactive grant to a moment Dan is present. The
// pure state — which steps are satisfied, whether onboarding is complete, and whether to auto-show on
// launch (Dan chose: whenever anything is missing) — is testable; the window and the live grant
// prompts are verified visually.
@Suite("Onboarding state (#270)")
struct OnboardingStateTests {
    private func allSatisfied() -> OnboardingState {
        OnboardingState(gmailConnected: true, omniFocusGranted: true,
                        notificationsAuthorized: true, loginAgentInstalled: true)
    }

    @Test func everyStepSatisfiedIsCompleteAndDoesNotAutoShow() {
        let s = allSatisfied()
        #expect(s.isComplete)
        #expect(s.shouldAutoShow == false)
        for step in OnboardingStep.allCases { #expect(s.isSatisfied(step)) }
    }

    @Test func anyMissingStepAutoShows() {
        var s = allSatisfied()
        s.omniFocusGranted = false
        #expect(s.isComplete == false)
        #expect(s.shouldAutoShow)
        #expect(s.isSatisfied(.omniFocus) == false)
        #expect(s.isSatisfied(.gmail))   // the others remain satisfied
    }

    @Test func loginAgentInstalledChecksTheFileOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory
        let present = dir.appendingPathComponent("agent-\(UUID().uuidString).plist")
        let absent = dir.appendingPathComponent("missing-\(UUID().uuidString).plist")
        try Data().write(to: present)
        defer { try? FileManager.default.removeItem(at: present) }
        #expect(OnboardingState.agentInstalled(at: present))
        #expect(OnboardingState.agentInstalled(at: absent) == false)
    }
}
