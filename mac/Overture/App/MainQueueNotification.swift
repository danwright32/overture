import Foundation

// #4464: an observer for a notification that ANY thread can post, delivered on the main queue.
//
// NotificationCenter delivers a selector or a queue-less block observer on the thread that POSTED, and a
// setting written by background work (the freeze report since #4458 runs on FreezeLogHousekeeper) posts
// `UserDefaults.didChangeNotification` on that background thread. A main actor method reached from there
// traps in Swift's isolation check, which crashed Overture on every launch on 2026-10-02. Which thread
// posts is decided by whoever writes a setting, anywhere in the app, so the observer is the one place
// that can be made safe for all of them. `MainQueueNotificationTests` posts from a background thread.
enum MainQueueNotification {
    static func observe(_ name: Notification.Name, in center: NotificationCenter = .default,
                        _ action: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
    }
}
