import AppKit
import Foundation

// #2220: the only reliable way to know the Mac was asleep is to watch it happen.
//
// No clock on this hardware excludes sleep (the measurements are in `SystemSleep`), so the watch-gap
// rule stopped asking a clock and started subtracting sleep it has actually seen. `NSWorkspace` posts
// `willSleepNotification` as the Mac goes down and `didWakeNotification` as it comes back, and this is
// the thin layer that turns that pair into the span `SystemSleep` accumulates.
//
// Deliberately nothing but the wiring: the arithmetic, the open-span handling, and every decision made
// from the total live in `SystemSleep` and `WatchGap`, where they are pure and tested. What this class
// owns is the one thing a test cannot have, which is a real Mac going to sleep.
//
// Registered on `NSWorkspace.shared.notificationCenter`, NOT the default center. Sleep and wake are
// posted only to the workspace centre, and a plain `NotificationCenter.default` observer for them is
// the silent no-op version of this whole feature.
@MainActor
final class SleepObserver {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep),
                           name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake),
                           name: NSWorkspace.didWakeNotification, object: nil)
    }

    @objc private func willSleep() { SystemSleep.willSleep(now: Date(), into: defaults) }
    @objc private func didWake() { SystemSleep.didWake(now: Date(), into: defaults) }
}
