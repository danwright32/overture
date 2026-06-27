import Foundation

// #268 / Phase 4 (minimal slice of Phase 5 #269): a real notification delivery so a not-granted or
// failed unattended OmniFocus sync is AUDIBLE, not just a masthead key the window has to be open to
// see. The runner already dedupes to one call per episode, so this just posts. Delivery and the single
// up-front authorization now live in NotificationService (#289); this adapter keeps the
// OmniFocusNotifier protocol the runner depends on.
struct OmniFocusUserNotifier: OmniFocusNotifier {
    func notifyPermissionNeeded() {
        NotificationService.post(.omniFocusPermission,
            title: "Overture needs OmniFocus permission",
            body: "Follow-up tasks aren't being created. Open Overture and allow it to control OmniFocus.")
    }

    func notifySyncFailed(_ message: String) {
        NotificationService.post(.omniFocusFailed,
            title: "Overture couldn't update OmniFocus",
            body: "The last follow-up sync failed. Tap Retry sync to try again.")
    }
}
