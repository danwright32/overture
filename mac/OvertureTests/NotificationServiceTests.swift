import Testing
import Foundation
import UserNotifications
@testable import Overture

// #289: one notification service backs every alert, with a single up-front authorization request and
// per-action identifiers. Delivery and the auth request take injected closures so the id mapping and
// request building are unit-testable without touching the live notification center.
@Suite("Notification service (#289)")
struct NotificationServiceTests {
    @Test func actionIdentifiersStayStableSoRepeatsCoalesce() {
        // These ids existed before the consolidation; changing them would stop notifications from
        // replacing their predecessor and start stacking duplicates.
        #expect(NotificationService.Action.reconcile.rawValue == "overture.reconcile")
        #expect(NotificationService.Action.away.rawValue == "overture.away")
        #expect(NotificationService.Action.omniFocusPermission.rawValue == "overture.omnifocus.permission")
        #expect(NotificationService.Action.omniFocusFailed.rawValue == "overture.omnifocus.failed")
    }

    @Test func postBuildsARequestKeyedOnTheActionIdentifier() {
        var delivered: UNNotificationRequest?
        NotificationService.post(.away, title: "Overture", body: "1 new reply (Carnegie Hall)",
                                 deliver: { delivered = $0 })
        #expect(delivered?.identifier == "overture.away")
        #expect(delivered?.content.title == "Overture")
        #expect(delivered?.content.body == "1 new reply (Carnegie Hall)")
    }

    @Test func requestAuthorizationReportsWhetherGranted() async {
        let granted = await NotificationService.requestAuthorization(request: { _ in true })
        #expect(granted)
        let denied = await NotificationService.requestAuthorization(request: { _ in false })
        #expect(!denied)
    }

    @Test func requestAuthorizationTreatsAThrownErrorAsNotGranted() async {
        struct Boom: Error {}
        let granted = await NotificationService.requestAuthorization(request: { _ in throw Boom() })
        #expect(!granted)
    }

    // #301: an away/reply alert carries the lead's natural key so a tap can deep-link to it, and stamps
    // the action's category so the registered action buttons (e.g. Open Settings) attach.
    @Test func postStampsTheLeadKeyAndCategorySoATapCanDeepLink() {
        var delivered: UNNotificationRequest?
        NotificationService.post(.away, title: "Overture", body: "1 new reply (Carnegie Hall)",
                                 leadKey: "carnegie|2026-03-10|hall", deliver: { delivered = $0 })
        #expect(delivered?.content.userInfo[NotificationService.leadKeyUserInfoKey] as? String == "carnegie|2026-03-10|hall")
        #expect(delivered?.content.categoryIdentifier == NotificationService.Action.away.rawValue)
    }

    @Test func postWithoutALeadKeyCarriesNoDeepLink() {
        var delivered: UNNotificationRequest?
        NotificationService.post(.omniFocusPermission, title: "t", body: "b", deliver: { delivered = $0 })
        #expect(delivered?.content.userInfo[NotificationService.leadKeyUserInfoKey] == nil)
        #expect(delivered?.content.categoryIdentifier == NotificationService.Action.omniFocusPermission.rawValue)
    }

    // #301: the pure tap router. A default tap with a lead key deep-links; the Open Settings button
    // opens settings; a default tap with no key just opens the app; a dismiss routes nowhere.
    @Test func routeDeepLinksOnADefaultTapCarryingALeadKey() {
        let route = NotificationService.route(actionIdentifier: UNNotificationDefaultActionIdentifier,
                                              userInfo: [NotificationService.leadKeyUserInfoKey: "k1"])
        #expect(route == .openLead(key: "k1"))
    }

    @Test func routeOpensSettingsForTheOpenSettingsButton() {
        let route = NotificationService.route(actionIdentifier: NotificationService.Button.openSettings.rawValue,
                                              userInfo: [:])
        #expect(route == .openSettings)
    }

    @Test func routeOpensTheAppOnADefaultTapWithNoLeadKey() {
        let route = NotificationService.route(actionIdentifier: UNNotificationDefaultActionIdentifier,
                                              userInfo: [:])
        #expect(route == .openApp)
    }

    @Test func routeIgnoresADismiss() {
        let route = NotificationService.route(actionIdentifier: UNNotificationDismissActionIdentifier,
                                              userInfo: [NotificationService.leadKeyUserInfoKey: "k1"])
        #expect(route == nil)
    }

    // #301: the OmniFocus-permission category carries an Open Settings action button.
    @Test func categoriesIncludeOpenSettingsOnThePermissionAlert() {
        let permission = NotificationService.categories().first { $0.identifier == NotificationService.Action.omniFocusPermission.rawValue }
        #expect(permission != nil)
        #expect(permission?.actions.contains { $0.identifier == NotificationService.Button.openSettings.rawValue } == true)
    }
}
