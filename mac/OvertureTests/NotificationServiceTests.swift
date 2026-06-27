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
}
