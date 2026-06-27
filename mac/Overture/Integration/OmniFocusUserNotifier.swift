import Foundation
import UserNotifications

// #268 / Phase 4 (minimal slice of Phase 5 #269): a real notification delivery so a not-granted or
// failed unattended OmniFocus sync is AUDIBLE, not just a masthead key the window has to be open to
// see. The runner already dedupes to one call per episode, so this just posts. Requesting
// authorization here is best-effort; the full first-run grant flow is Phase 6 (#270).
struct OmniFocusUserNotifier: OmniFocusNotifier {
    func notifyPermissionNeeded() {
        post(id: "overture.omnifocus.permission",
             title: "Overture needs OmniFocus permission",
             body: "Follow-up tasks aren't being created. Open Overture and allow it to control OmniFocus.")
    }

    func notifySyncFailed(_ message: String) {
        post(id: "overture.omnifocus.failed",
             title: "Overture couldn't update OmniFocus",
             body: "The last follow-up sync failed. Open Overture to retry.")
    }

    private func post(id: String, title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
