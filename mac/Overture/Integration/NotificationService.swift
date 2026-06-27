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

    // #301: custom tap-button identifiers (the buttons that appear under a notification). The
    // OmniFocus-permission alert carries an Open Settings button; the OmniFocus-failed alert carries a
    // Retry sync button (#306).
    enum Button: String {
        case openSettings = "overture.action.openSettings"
        case retrySync = "overture.action.retrySync"
    }

    // #301: where a tapped notification should route. Pure result of `route(...)`, acted on by the
    // UNUserNotificationCenterDelegate (AppDelegate).
    enum Route: Equatable, Sendable {
        case openLead(key: String)
        // #308: a coalesced multi-lead away alert routes here, to the queue filtered to exactly the new
        // leads. The single-lead tap stays .openLead (#301).
        case openLeads(keys: [String])
        case openSettings
        case openApp
        case retrySync
    }

    // #301/#308: userInfo key carrying the new leads' natural keys (a one-element array for a single
    // lead), so a tap can deep-link straight to them.
    static let leadKeysUserInfoKey = "leadKeys"

    // #301: categories register the custom action buttons with the center. The permission alert has an
    // Open Settings button; the failed alert has a Retry sync button (#306); the others rely on the
    // default tap. Registered once at launch by the delegate via
    // UNUserNotificationCenter.setNotificationCategories.
    static func categories() -> Set<UNNotificationCategory> {
        let openSettings = UNNotificationAction(identifier: Button.openSettings.rawValue,
                                                title: "Open Settings", options: [.foreground])
        let permission = UNNotificationCategory(identifier: Action.omniFocusPermission.rawValue,
                                                actions: [openSettings], intentIdentifiers: [],
                                                options: [])
        // #306: Retry runs the reconcile quietly in the resident process — no .foreground, so it doesn't
        // yank the windowless app to the front. The reconcile acks itself with a result notification.
        let retrySync = UNNotificationAction(identifier: Button.retrySync.rawValue,
                                             title: "Retry sync", options: [])
        let failed = UNNotificationCategory(identifier: Action.omniFocusFailed.rawValue,
                                            actions: [retrySync], intentIdentifiers: [],
                                            options: [])
        return [permission, failed]
    }

    // #301/#308: the pure tap router. The Open Settings button routes to settings; the Retry sync button
    // (#306) forces a reconcile; a default tap deep-links to the lead(s) that rode along — one lead opens
    // it directly, several open the filtered new-leads view — else just opens the app; a dismiss routes
    // nowhere.
    static func route(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> Route? {
        if actionIdentifier == Button.openSettings.rawValue { return .openSettings }
        if actionIdentifier == Button.retrySync.rawValue { return .retrySync }
        if actionIdentifier == UNNotificationDismissActionIdentifier { return nil }
        let keys = (userInfo[leadKeysUserInfoKey] as? [String])?.filter { !$0.isEmpty } ?? []
        if keys.count == 1 { return .openLead(key: keys[0]) }
        if keys.count >= 2 { return .openLeads(keys: keys) }
        return .openApp
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
        leadKeys: [String] = [],
        deliver: (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // #301/#308: the category attaches the registered action buttons (e.g. Open Settings on the
        // permission alert); the new leads' keys ride in userInfo so a tap can deep-link to them.
        content.categoryIdentifier = action.rawValue
        let keys = leadKeys.filter { !$0.isEmpty }
        if !keys.isEmpty { content.userInfo = [leadKeysUserInfoKey: keys] }
        deliver(UNNotificationRequest(identifier: action.rawValue, content: content, trigger: nil))
    }
}
