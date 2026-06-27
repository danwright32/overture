import Foundation
import UserNotifications

// #289: the ONE place notifications are delivered and authorization is requested. Previously two
// shims (LocalNotifier #285, OmniFocusUserNotifier #268) each called requestAuthorization on every
// post, which is redundant once granted and uncoordinated with the #270 onboarding grant. Here the
// grant is requested once, up front (by onboarding), and posts just deliver — they never re-prompt.
// Per-action identifiers live in one enum so a repeat replaces its predecessor instead of stacking.
// Delivery and the auth request both take an injected closure so the id mapping and request building
// are unit-testable without the live notification center.
enum NotificationService {
    enum Action: String {
        case reconcile = "overture.reconcile"
        case away = "overture.away"
        case omniFocusPermission = "overture.omnifocus.permission"
        case omniFocusFailed = "overture.omnifocus.failed"
    }

    // The single up-front authorization request (used by #270 onboarding). Returns whether granted;
    // a thrown error collapses to not-granted.
    @discardableResult
    static func requestAuthorization(
        request: (UNAuthorizationOptions) async throws -> Bool = {
            try await UNUserNotificationCenter.current().requestAuthorization(options: $0)
        }
    ) async -> Bool {
        (try? await request([.alert, .sound])) ?? false
    }

    // Deliver a notification keyed on its action identifier. Authorization is NOT requested here (it is
    // granted once up front via onboarding); if it isn't authorized the center silently drops this,
    // which is the intended best-effort behaviour for the windowless resident process.
    static func post(
        _ action: Action,
        title: String,
        body: String,
        deliver: (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        deliver(UNNotificationRequest(identifier: action.rawValue, content: content, trigger: nil))
    }
}
