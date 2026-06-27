import Foundation
import UserNotifications

// #285: a thin local-notification shim for acknowledging on-demand actions (e.g. a manual reconcile
// that found nothing to do). Untestable by nature — it talks to the live notification center — so the
// message it carries is built by tested pure code (ReconcileSummary) and only the delivery lives here.
// A stable identifier per action coalesces repeats rather than stacking duplicates.
enum LocalNotifier {
    static func post(title: String, body: String, id: String) {
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
