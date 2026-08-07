import Foundation

// #2220: how much of a stretch of wall clock the Mac spent ASLEEP, and when this process started.
//
// #2091 needed both facts and got them from `ProcessInfo.systemUptime`, on the documented premise that
// it counts awake time only. Measured on Dan's Mac on 2026-08-06, that is not true here:
//
//   wall clock since boot   54.19 h
//   ProcessInfo.systemUptime  54.07 h   (7.6 minutes lost)
//   CLOCK_UPTIME_RAW          54.07 h
//   mach_absolute_time        54.07 h
//   CLOCK_MONOTONIC           54.19 h
//   mach_continuous_time      54.20 h
//
// That window contained two nights, one of them with the lid shut for ten hours (`pmset -g log`,
// Clamshell Sleep 23:23:23 to 09:34:57). Every clock the platform offers ran through it. So there is no
// awake clock to read on this hardware, and the whole family is measured here rather than argued about:
// see `SystemSleepMeasurementTests` and `fixtures/watch-gap-clock-measurement.json`.
//
// What IS observable is the sleep itself. `NSWorkspace` posts a notification as the Mac goes to sleep
// and another as it wakes, and the span between them is directly measurable by a running app. This is
// the accumulator those two notifications write into.
//
// Pure and UserDefaults-backed for the same reason the heartbeat is: it is not user data, it has to
// survive a relaunch, and it has to be drivable from a test against a scratch suite.
enum SystemSleep {
    static let totalKey = "watchObservedSleepSeconds"
    static let sleepStartedAtKey = "watchSleepStartedAt"

    // The Mac is going to sleep. Only the instant is recorded; the span is closed on the other side.
    static func willSleep(now: Date, into defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: sleepStartedAtKey)
    }

    // The Mac woke. Close the open span into the running total.
    static func didWake(now: Date, into defaults: UserDefaults = .standard) {
        defaults.set(totalSeconds(now: now, in: defaults), forKey: totalKey)
        defaults.removeObject(forKey: sleepStartedAtKey)
    }

    // The total, including a span that is open at the moment of reading.
    //
    // An open span cannot mean "the Mac is asleep right now", because this code only runs while it is
    // awake. It means the wake notification has not been handled YET, and that is the ordinary case
    // rather than an edge one: the scheduler waits on a clock that keeps running through sleep, so its
    // timer comes due the instant the Mac wakes and races the notification. Closing the span here rather
    // than waiting to be told is what makes the reading independent of which of the two lands first.
    static func totalSeconds(now: Date, in defaults: UserDefaults = .standard) -> Double {
        let stored = defaults.double(forKey: totalKey)
        let open = defaults.double(forKey: sleepStartedAtKey)
        guard open > 0 else { return stored }
        return stored + max(0, now.timeIntervalSince1970 - open)
    }
}

// When THIS process started, and when the last one ended on purpose.
//
// #2220: with no awake clock to read, "Overture was not running" and "Overture was running and not
// watching" have to be told apart some other way, and they are two different sentences to Dan (L11).
// The process's own launch instant separates them exactly: a heartbeat older than this launch means
// something in between was not running, and nothing else can produce that.
enum ProcessLaunch {
    static let startedAtKey = "watchProcessStartedAt"
    static let quitCleanlyAtKey = "watchQuitCleanlyAt"

    static func stampStart(now: Date, into defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: startedAtKey)
    }

    // Dan quit, or the Mac shut down and asked every app to. Either way the process ending was somebody's
    // decision, so the silence that follows is not a fault and must not be reported as one.
    static func stampCleanQuit(now: Date, into defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: quitCleanlyAtKey)
    }

    static func startedAt(_ defaults: UserDefaults = .standard) -> Double {
        defaults.double(forKey: startedAtKey)
    }

    static func quitCleanlyAt(_ defaults: UserDefaults = .standard) -> Double {
        defaults.double(forKey: quitCleanlyAtKey)
    }
}

// When the Mac last booted, read from the kernel rather than derived from any clock. Used to keep a
// stretch when the Mac was OFF out of a gap: nothing could have been watching then, and calling it a
// failure is the daily-false-positive shape all over again.
enum SystemBoot {
    static func at() -> Double {
        var mib = [CTL_KERN, KERN_BOOTTIME]
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctl(&mib, 2, &tv, &size, nil, 0) == 0 else { return 0 }
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }
}
