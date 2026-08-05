import Foundation

// #2091: noticing that the resident app has stopped watching, and saying so.
//
// Overture is resident by design (#266). With the window closed the ReconcileScheduler is still doing
// the watching half of the product: reply and bounce detection, calendar conflict rechecks, booking
// reconciliation, away alerts. When that process is not running, every one of those produces exactly
// the same observable result as a genuinely quiet day, so #2088 hid behind it for however long it was
// live: Dan noticed because he happened to look for the menu bar icon, not because the product told
// him. That is L13's shape (alert on the ABSENCE of an expected run) and L68's (assert the signature
// of the failure, never the data's current emptiness).
//
// Two things this has to get right, and both are structural rather than a matter of tuning.
//
// The gap is measured in AWAKE time, not wall clock. A Mac asleep for eight hours leaves the same
// wall-clock hole as an app that was dead for eight hours, and Dan's Mac sleeps every night, so a
// wall-clock threshold would cry wolf daily until it was tuned so high it hid the thing it watches
// (L36). ProcessInfo.systemUptime counts time the system has been AWAKE since boot, so a sleeping Mac
// simply does not accumulate a gap. The same reading tells a reboot apart from a continuous session:
// uptime lower than the last heartbeat's means the machine restarted, and the only unwatched awake
// time is what has elapsed since boot. That distinguishes "the Mac was off for three days" (nothing
// was missed that could have been caught) from "the login agent failed and the Mac has been awake for
// six hours with nothing watching" (exactly the blind spot), which a wall clock cannot do at all.
//
// The outage is RECORDED when watching resumes, not inferred later. `start()` runs a reconcile
// immediately at launch, and that tick stamps a fresh heartbeat, so a second after Overture comes back
// from three days dead there is nothing stale left to read: reading the heartbeat alone, the launch
// would erase its own evidence. `observeResume` therefore runs at the top of EVERY tick, before that
// tick's own stamp. Every tick rather than just the launch one because the menu's "Run reconcile now"
// resumes watching too, and a rule that covered only launch would silently miss it (L30).
//
// Everything here is pure: both clocks are arguments, so a test drives sleep, reboots and multi-day
// outages without touching the host's.
enum WatchGap {
    // A completed reconcile: when it happened by the wall clock, and how much awake time the Mac had
    // accumulated at that moment. Both are needed; neither alone can tell the four cases apart.
    struct Heartbeat: Equatable, Sendable {
        var at: Double = 0              // timeIntervalSince1970; 0 means Overture has never watched
        var awakeUptime: Double = 0     // ProcessInfo.systemUptime at the stamp
    }

    // A silence that has ENDED, kept so it can still be reported once the fresh stamp has hidden it.
    struct Outage: Equatable, Sendable {
        var awakeSeconds: Double
        var endedAt: Double             // timeIntervalSince1970 of the tick that resumed watching
    }

    enum Report: Equatable, Sendable {
        case ongoing(awakeSeconds: TimeInterval)
        case recovered(awakeSeconds: TimeInterval, endedAt: Date)
    }

    // How long a finished outage stays on screen. Bounded rather than permanent: its job is to explain
    // a quiet stretch Dan may still be looking at, and a day covers that without becoming furniture.
    static let reportRecoveredFor: TimeInterval = 86_400

    // L51: derived from the cadence that computes it, never a guessed constant, so it can never be
    // shorter than the interval that would have to fire for it to be reached. Three missed checks is
    // Dan's call (2026-08-04): the earliest point at which the silence is definitely not normal, which
    // is affordable because this is a quiet line on the queue rather than a notification.
    static let missedChecks: Double = 3
    static func staleAfter(intervalSeconds: Double) -> TimeInterval { missedChecks * intervalSeconds }

    static func heartbeat(now: Date, uptime: TimeInterval) -> Heartbeat {
        Heartbeat(at: now.timeIntervalSince1970, awakeUptime: uptime)
    }

    // The awake time that passed since `previous` without a reconcile, or nil when that is not an
    // outage. nil covers three distinct healthy states, each for its own reason: no heartbeat on record
    // (a fresh install has never watched, which the menu bar's own idle state already says, and calling
    // it a failure would light this line on day one for something that is not one), a clock that moved
    // backwards (no honest claim to make), and a gap that has not yet reached the window.
    static func outage(since previous: Heartbeat, now: Date, uptime: TimeInterval,
                       intervalSeconds: Double) -> TimeInterval? {
        guard previous.at > 0 else { return nil }
        let wall = now.timeIntervalSince1970 - previous.at
        guard wall > 0 else { return nil }
        // Same boot session: the awake time between the two readings. A lower uptime means the machine
        // restarted, so the previous session's reading is not comparable and the unwatched awake time
        // is everything since boot.
        let awake = uptime >= previous.awakeUptime ? uptime - previous.awakeUptime : uptime
        // Awake time can never exceed the wall-clock time it happened in, so a bogus uptime (a restored
        // snapshot, an OS clock adjustment) can never manufacture an outage longer than the real elapsed
        // time. Without this the two clocks could disagree and the larger one would always win.
        let gap = max(0, min(awake, wall))
        return gap > staleAfter(intervalSeconds: intervalSeconds) ? gap : nil
    }

    // What to say right now, if anything. A live silence outranks a finished one: it is the fault Dan
    // can still act on, and the finished one is only there to explain a quiet stretch.
    static func report(previous: Heartbeat, recorded: Outage?, now: Date, uptime: TimeInterval,
                       intervalSeconds: Double) -> Report? {
        if let live = outage(since: previous, now: now, uptime: uptime, intervalSeconds: intervalSeconds) {
            return .ongoing(awakeSeconds: live)
        }
        guard let recorded, now.timeIntervalSince1970 - recorded.endedAt <= reportRecoveredFor else {
            return nil
        }
        return .recovered(awakeSeconds: recorded.awakeSeconds,
                          endedAt: Date(timeIntervalSince1970: recorded.endedAt))
    }

    // The sentence both surfaces show. The queue masthead and the menu bar build it from here rather
    // than each assembling their own, so the two can never come to describe one fact differently.
    static func line(for report: Report, now: Date) -> String {
        switch report {
        case .ongoing(let seconds):
            return "Overture has not checked for replies or bookings in \(PrepStatus.duration(seconds: seconds))"
        case .recovered(let seconds, let endedAt):
            return "Overture was not checking for replies or bookings for \(PrepStatus.duration(seconds: seconds)), "
                + "and resumed \(PrepStatus.relative(from: endedAt, to: now))"
        }
    }
}

// Persistence for the heartbeat and the last recorded outage, in UserDefaults like
// DownbeatFeedFreshnessStore's own tracking: it is not user data and not a cross-boundary hand-off, so
// it needs no store table or JSON file. `defaults` is injectable throughout so the ordering that makes
// this work (observe the resume, THEN stamp) is testable against a scratch suite.
enum WatchHeartbeatStore {
    static let heartbeatAtKey = "watchHeartbeatAt"
    static let heartbeatUptimeKey = "watchHeartbeatUptime"
    static let outageAwakeSecondsKey = "watchOutageAwakeSeconds"
    static let outageEndedAtKey = "watchOutageEndedAt"

    static func load(_ defaults: UserDefaults = .standard) -> WatchGap.Heartbeat {
        WatchGap.Heartbeat(at: defaults.double(forKey: heartbeatAtKey),
                           awakeUptime: defaults.double(forKey: heartbeatUptimeKey))
    }

    static func loadOutage(_ defaults: UserDefaults = .standard) -> WatchGap.Outage? {
        let endedAt = defaults.double(forKey: outageEndedAtKey)
        guard endedAt > 0 else { return nil }
        return WatchGap.Outage(awakeSeconds: defaults.double(forKey: outageAwakeSecondsKey), endedAt: endedAt)
    }

    static func stamp(now: Date, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                      into defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: heartbeatAtKey)
        defaults.set(uptime, forKey: heartbeatUptimeKey)
    }

    // Called at the START of a reconcile tick, before `stamp` overwrites the heartbeat this reads. A
    // tick that is resuming after a real silence writes that silence down; an ordinary tick on the
    // cadence writes nothing, so normal operation can never light the line. The most recent outage
    // replaces any earlier one: what Dan needs is the silence he is currently living with the
    // consequences of, not the first one Overture ever noticed.
    static func observeResume(now: Date, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                              intervalSeconds: Double = ReconcileScheduler.intervalSeconds(),
                              into defaults: UserDefaults = .standard) {
        guard let gap = WatchGap.outage(since: load(defaults), now: now, uptime: uptime,
                                        intervalSeconds: intervalSeconds) else { return }
        defaults.set(gap, forKey: outageAwakeSecondsKey)
        defaults.set(now.timeIntervalSince1970, forKey: outageEndedAtKey)
    }

    // The live verdict, for the two surfaces that show it.
    static func currentReport(now: Date = Date(),
                              uptime: TimeInterval = ProcessInfo.processInfo.systemUptime,
                              intervalSeconds: Double = ReconcileScheduler.intervalSeconds(),
                              defaults: UserDefaults = .standard) -> WatchGap.Report? {
        WatchGap.report(previous: load(defaults), recorded: loadOutage(defaults), now: now,
                        uptime: uptime, intervalSeconds: intervalSeconds)
    }
}
