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
// A Mac asleep for eight hours leaves the same wall-clock hole as an app that was dead for eight hours,
// and Dan's Mac sleeps every night, so a bare wall-clock threshold would cry wolf daily until it was
// tuned so high it hid the thing it watches (L36).
//
// #2220 is what happens when you take the platform's word for the way out of that. The first version
// measured the gap in "awake time" from `ProcessInfo.systemUptime`, which is documented as counting
// only time the system has been awake. Measured on Dan's Mac, that clock and every sibling of it ran
// straight through two nights of closed lid, losing 7.6 minutes in 54 hours (the numbers are in
// `SystemSleep`). So the line fired every single morning, reporting his laptop being asleep as Overture
// having failed, which is the exact outcome it was written to design around. Every test injected the
// clock as an argument, so 100% of the coverage confirmed the assumption about the API rather than the
// API itself (L52, L82).
//
// So nothing here reads a clock that claims to know about sleep. Two facts are OBSERVED instead, and
// each answers one of the two questions a gap raises:
//
//   Was the Mac asleep?  `SystemSleep` accumulates the span between NSWorkspace's sleep and wake
//                        notifications. Directly measurable, and true whether or not any clock is.
//   Was Overture there?  `ProcessLaunch` stamps the instant this process started. A heartbeat older
//                        than that means something in between was not running, and nothing else does.
//
// Those are DIFFERENT faults with different remedies, so they get different sentences (L11). "Overture
// was not running" is a claim about the process and needs no sleep accounting to be true. "Overture was
// running and did not check" is a claim about awake time and gets the sleep subtracted from it.
//
// The outage is RECORDED when watching resumes, not inferred later. `start()` runs a reconcile
// immediately at launch, and that tick stamps a fresh heartbeat, so a second after Overture comes back
// from three days dead there is nothing stale left to read: reading the heartbeat alone, the launch
// would erase its own evidence. `observeResume` therefore runs at the top of EVERY tick, before that
// tick's own stamp. Every tick rather than just the launch one because the menu's "Run reconcile now"
// resumes watching too, and a rule that covered only launch would silently miss it (L30).
//
// Everything here is pure: every reading is an argument, so a test drives sleep, reboots, crashes and
// multi-day outages without touching the host's.
enum WatchGap {
    // A completed reconcile: when it happened by the wall clock, and how much sleep had been observed by
    // that moment. Both are needed; neither alone can tell the cases apart.
    struct Heartbeat: Equatable, Sendable {
        var at: Double = 0              // timeIntervalSince1970; 0 means Overture has never watched
        var sleptSeconds: Double = 0    // SystemSleep's running total at the stamp
    }

    // Why the watching stopped. Two faults, two remedies, two sentences.
    enum Cause: String, Equatable, Sendable {
        case notRunning     // the process was gone
        case notWatching    // the process was there and its tick did not happen
    }

    // Everything the decision is made from, gathered at the call site that owns the real readings.
    struct Readings: Equatable, Sendable {
        var sleptSeconds: Double        // SystemSleep.totalSeconds
        var processStartedAt: Double    // ProcessLaunch.startedAt
        var quitCleanlyAt: Double       // ProcessLaunch.quitCleanlyAt
        var bootedAt: Double            // SystemBoot.at
    }

    // A silence that has ENDED, kept so it can still be reported once the fresh stamp has hidden it.
    struct Outage: Equatable, Sendable {
        var cause: Cause
        var seconds: Double
        var endedAt: Double             // timeIntervalSince1970 of the tick that resumed watching
    }

    enum Report: Equatable, Sendable {
        case ongoing(awakeSeconds: TimeInterval)
        case recovered(cause: Cause, seconds: TimeInterval, endedAt: Date)
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

    static func heartbeat(now: Date, sleptSeconds: Double) -> Heartbeat {
        Heartbeat(at: now.timeIntervalSince1970, sleptSeconds: sleptSeconds)
    }

    // Overture was RUNNING through this whole stretch and did not check: the awake time between the last
    // heartbeat and now, with the observed sleep taken out of it.
    //
    // nil covers several healthy states, each for its own reason: no heartbeat on record (a fresh
    // install has never watched, which the menu bar's own idle state already says, and calling it a
    // failure would light this line on day one for something that is not one), a clock that moved
    // backwards (no honest claim to make), a process that started after the heartbeat (that is the OTHER
    // fault, below, and reporting both would double-count one silence), and a gap under the window.
    static func notWatching(since previous: Heartbeat, now: Date, readings: Readings,
                            intervalSeconds: Double) -> TimeInterval? {
        guard previous.at > 0 else { return nil }
        let wall = now.timeIntervalSince1970 - previous.at
        guard wall > 0 else { return nil }
        // A process that started after the heartbeat did not live through this stretch, so it has no
        // sleep observations for it and no business claiming awake time in it.
        guard readings.processStartedAt <= previous.at else { return nil }
        let slept = max(0, readings.sleptSeconds - previous.sleptSeconds)
        // Sleep can never exceed the wall-clock time it happened in, so a bogus accumulator can never
        // subtract more than the whole window and turn a real outage negative.
        let gap = max(0, wall - min(slept, wall))
        return gap > staleAfter(intervalSeconds: intervalSeconds) ? gap : nil
    }

    // Overture's process was NOT THERE for a stretch: from the last heartbeat (or the boot, whichever is
    // later) to the moment this process started.
    //
    // Wall clock, deliberately and honestly. Nothing was observing sleep during it, so no sleep can be
    // subtracted, and the sentence this produces claims only the thing that was measured: the app was
    // not running. A stretch when the Mac was OFF is excluded by the boot floor, because nothing could
    // have been watching then and calling that a fault is the daily-false-positive shape again.
    //
    // A clean quit is not a fault. Dan quitting from the menu bar, or a shutdown asking every app to
    // stop, is somebody's decision, and a product that reports a decision back as a failure is one whose
    // reports stop being read.
    static func notRunning(since previous: Heartbeat, readings: Readings,
                           intervalSeconds: Double) -> TimeInterval? {
        guard previous.at > 0 else { return nil }
        guard readings.processStartedAt > previous.at else { return nil }
        guard readings.quitCleanlyAt < previous.at else { return nil }
        let from = max(previous.at, readings.bootedAt)
        let gap = readings.processStartedAt - from
        return gap > staleAfter(intervalSeconds: intervalSeconds) ? gap : nil
    }

    // The silence this tick is resuming after, if any, ready to be written down.
    static func resumedOutage(since previous: Heartbeat, now: Date, readings: Readings,
                              intervalSeconds: Double) -> Outage? {
        if let dead = notRunning(since: previous, readings: readings, intervalSeconds: intervalSeconds) {
            return Outage(cause: .notRunning, seconds: dead, endedAt: now.timeIntervalSince1970)
        }
        if let quiet = notWatching(since: previous, now: now, readings: readings,
                                   intervalSeconds: intervalSeconds) {
            return Outage(cause: .notWatching, seconds: quiet, endedAt: now.timeIntervalSince1970)
        }
        return nil
    }

    // What to say right now, if anything. A live silence outranks a finished one: it is the fault Dan
    // can still act on, and the finished one is only there to explain a quiet stretch.
    //
    // Only `.notWatching` can be ONGOING. A process that is not running is not evaluating this, so by
    // the time anything notices, that silence is over by definition.
    static func report(previous: Heartbeat, recorded: Outage?, now: Date, readings: Readings,
                       intervalSeconds: Double) -> Report? {
        if let live = notWatching(since: previous, now: now, readings: readings,
                                  intervalSeconds: intervalSeconds) {
            return .ongoing(awakeSeconds: live)
        }
        guard let recorded, now.timeIntervalSince1970 - recorded.endedAt <= reportRecoveredFor else {
            return nil
        }
        return .recovered(cause: recorded.cause, seconds: recorded.seconds,
                          endedAt: Date(timeIntervalSince1970: recorded.endedAt))
    }

    // The sentence both surfaces show. The queue masthead and the menu bar build it from here rather
    // than each assembling their own, so the two can never come to describe one fact differently.
    static func line(for report: Report, now: Date) -> String {
        switch report {
        case .ongoing(let seconds):
            return "Overture has not checked for replies or bookings in \(PrepStatus.duration(seconds: seconds))"
        case .recovered(.notWatching, let seconds, let endedAt):
            return "Overture was not checking for replies or bookings for \(PrepStatus.duration(seconds: seconds)), "
                + "and resumed \(PrepStatus.relative(from: endedAt, to: now))"
        case .recovered(.notRunning, let seconds, let endedAt):
            return "Overture was not running for \(PrepStatus.duration(seconds: seconds)), "
                + "and started again \(PrepStatus.relative(from: endedAt, to: now))"
        }
    }
}

// Persistence for the heartbeat and the last recorded outage, in UserDefaults like
// DownbeatFeedFreshnessStore's own tracking: it is not user data and not a cross-boundary hand-off, so
// it needs no store table or JSON file. `defaults` is injectable throughout so the ordering that makes
// this work (observe the resume, THEN stamp) is testable against a scratch suite.
enum WatchHeartbeatStore {
    static let heartbeatAtKey = "watchHeartbeatAt"
    static let heartbeatSleptKey = "watchHeartbeatSleptSeconds"
    static let outageSecondsKey = "watchOutageAwakeSeconds"
    static let outageEndedAtKey = "watchOutageEndedAt"
    static let outageCauseKey = "watchOutageCause"
    // #2220: the reading the retired awake clock wrote. Its presence is what identifies defaults holding
    // a verdict reached the broken way, and it is removed by the discard below.
    static let retiredUptimeKey = "watchHeartbeatUptime"

    // #2220 step 3: the outage currently sitting in Dan's defaults was measured with the clock this
    // issue retired, so it is a false positive that would keep rendering for a day after the fix ships.
    // It cannot be reinterpreted (the reading it was based on means nothing now), so it is discarded,
    // along with the heartbeat, which takes a fresh baseline on the next tick a moment later.
    //
    // Keyed on the retired reading itself rather than on a version number, so it runs exactly once per
    // Mac, on the first launch after the fix, and is a no-op forever afterwards.
    static func discardVerdictsFromTheRetiredClock(_ defaults: UserDefaults = .standard) {
        guard defaults.object(forKey: retiredUptimeKey) != nil else { return }
        for key in [retiredUptimeKey, heartbeatAtKey, outageSecondsKey, outageEndedAtKey, outageCauseKey] {
            defaults.removeObject(forKey: key)
        }
    }

    static func load(_ defaults: UserDefaults = .standard) -> WatchGap.Heartbeat {
        WatchGap.Heartbeat(at: defaults.double(forKey: heartbeatAtKey),
                           sleptSeconds: defaults.double(forKey: heartbeatSleptKey))
    }

    static func loadOutage(_ defaults: UserDefaults = .standard) -> WatchGap.Outage? {
        let endedAt = defaults.double(forKey: outageEndedAtKey)
        guard endedAt > 0 else { return nil }
        // An unreadable cause is not scored as one of today's two (L11). Defaulting to `notWatching`
        // would put the awake-time sentence on a silence nothing measured awake time for.
        guard let raw = defaults.string(forKey: outageCauseKey),
              let cause = WatchGap.Cause(rawValue: raw) else { return nil }
        return WatchGap.Outage(cause: cause, seconds: defaults.double(forKey: outageSecondsKey),
                               endedAt: endedAt)
    }

    // Everything the verdict is made from, read from the real system. One place, so the surfaces and the
    // scheduler cannot come to read different clocks.
    static func readings(now: Date = Date(), defaults: UserDefaults = .standard) -> WatchGap.Readings {
        WatchGap.Readings(sleptSeconds: SystemSleep.totalSeconds(now: now, in: defaults),
                          processStartedAt: ProcessLaunch.startedAt(defaults),
                          quitCleanlyAt: ProcessLaunch.quitCleanlyAt(defaults),
                          bootedAt: SystemBoot.at())
    }

    static func stamp(now: Date, readings: WatchGap.Readings, into defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970, forKey: heartbeatAtKey)
        defaults.set(readings.sleptSeconds, forKey: heartbeatSleptKey)
    }

    // Called at the START of a reconcile tick, before `stamp` overwrites the heartbeat this reads. A
    // tick that is resuming after a real silence writes that silence down; an ordinary tick on the
    // cadence writes nothing, so normal operation can never light the line. The most recent outage
    // replaces any earlier one: what Dan needs is the silence he is currently living with the
    // consequences of, not the first one Overture ever noticed.
    static func observeResume(now: Date, readings: WatchGap.Readings,
                              intervalSeconds: Double = ReconcileScheduler.intervalSeconds(),
                              into defaults: UserDefaults = .standard) {
        guard let outage = WatchGap.resumedOutage(since: load(defaults), now: now, readings: readings,
                                                  intervalSeconds: intervalSeconds) else { return }
        defaults.set(outage.seconds, forKey: outageSecondsKey)
        defaults.set(outage.endedAt, forKey: outageEndedAtKey)
        defaults.set(outage.cause.rawValue, forKey: outageCauseKey)
    }

    // The live verdict, for the two surfaces that show it.
    static func currentReport(now: Date = Date(),
                              intervalSeconds: Double = ReconcileScheduler.intervalSeconds(),
                              defaults: UserDefaults = .standard) -> WatchGap.Report? {
        WatchGap.report(previous: load(defaults), recorded: loadOutage(defaults), now: now,
                        readings: readings(now: now, defaults: defaults),
                        intervalSeconds: intervalSeconds)
    }
}
