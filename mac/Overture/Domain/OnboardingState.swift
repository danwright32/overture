import Foundation

// #270 / Phase 6: the first-run onboarding checklist. Each step is an interactive permission the
// resident process needs but can only obtain while Dan is present; onboarding exists to move every one
// of them on-screen. The state here is pure (testable); the window and the live grant prompts are not.
enum OnboardingStep: CaseIterable {
    case gmail          // connect Gmail so the resident process inherits a live token
    case omniFocus      // one foreground sync to establish the Automation TCC grant
    case notifications  // authorize notifications so away-from-desk alerts arrive
    case loginAgent     // confirm the launchd agent that keeps Overture resident is installed
}

struct OnboardingState: Equatable, Sendable {
    var gmailConnected: Bool
    var omniFocusGranted: Bool
    var notificationsAuthorized: Bool
    var loginAgentInstalled: Bool

    func isSatisfied(_ step: OnboardingStep) -> Bool {
        switch step {
        case .gmail: return gmailConnected
        case .omniFocus: return omniFocusGranted
        case .notifications: return notificationsAuthorized
        case .loginAgent: return loginAgentInstalled
        }
    }

    var isComplete: Bool { OnboardingStep.allCases.allSatisfy(isSatisfied) }

    // Dan's choice (#270): auto-show on launch whenever anything is missing, so a lapsed grant
    // resurfaces on its own rather than failing silently while away.
    var shouldAutoShow: Bool { !isComplete }

    // The login agent is "installed" when its LaunchAgent plist is in place; the build installs it to
    // ~/Library/LaunchAgents/com.danwright.overture.plist (#267).
    static func agentInstalled(at url: URL = defaultAgentURL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static var defaultAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.danwright.overture.plist")
    }
}
