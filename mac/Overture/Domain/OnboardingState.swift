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

// #885: onboarding's status lines, out of the view.
//
// Every failure branch here is REMEDIATION: it tells Dan where to go and what to click. Copy that is
// only ever seen when something has gone wrong is copy nobody exercises by accident, which is exactly
// why it has to be the kind a test can read.
extension OnboardingState {
    static func notificationsStatus(granted: Bool) -> String {
        granted
            ? "Notifications allowed."
            : "Not allowed. Enable Overture in System Settings ▸ Notifications."
    }

    static func omniFocusStatus(granted: Bool) -> String {
        granted
            ? "OmniFocus permission granted."
            : "Still not granted. Allow Overture in the prompt, or in System Settings ▸ Privacy & Security ▸ Automation."
    }

    // The real reason travels with the failure, rather than a generic "couldn't connect" that leaves him
    // nothing to act on.
    static func gmailConnectFailed(reason: String) -> String {
        "Couldn't connect Gmail: \(reason)"
    }
}

// #885 (guard sweep): the sheet's close button says what closing MEANS: setup finished, or merely
// dismissed with steps outstanding.
extension OnboardingState {
    static func closeButtonTitle(isComplete: Bool) -> String { isComplete ? "Done" : "Close" }
}
