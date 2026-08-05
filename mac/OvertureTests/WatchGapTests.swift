import Testing
import Foundation

// #2091: telling Dan the resident app has stopped watching.
//
// Overture is resident (#266): with the window closed the ReconcileScheduler is still doing reply
// detection, bounce detection, conflict rechecks and booking reconciliation. When that process is not
// running, every one of those produces the SAME observable result as a genuinely quiet day, which is
// how #2088 hid for however long it was live. This is the detection for the absence of an expected run
// (L13), and it asserts the SIGNATURE of the failure rather than the data's current emptiness (L68).
//
// Two things make this harder than "is the timestamp old":
//
//   1. The launch tick erases its own evidence. `start()` runs a reconcile immediately, which stamps
//      the heartbeat, so opening Overture after three days dead would leave nothing to read a second
//      later. The gap has to be observed BEFORE the resuming tick stamps.
//   2. A sleeping Mac produces exactly the same wall-clock gap as a dead app. Measuring the gap in
//      AWAKE time (ProcessInfo.systemUptime, which does not advance while the Mac sleeps) makes the
//      whole class structurally unable to fire on sleep, instead of relying on a threshold tuned high
//      enough to hide it (L36).
//
// All pure, so both clocks are driven from the test rather than the host's.
@Suite("Watch gap detection (#2091)")
struct WatchGapTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let interval: Double = 30 * 60          // the ReconcileScheduler default cadence
    private func after(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

    // MARK: the threshold

    // L51: the staleness window is derived from the cadence that computes it, never a guessed constant.
    // A window shorter than the interval could never fire; three missed checks is Dan's call (2026-08-04).
    @Test func theWindowIsThreeMissedChecksOfWhateverTheCadenceIs() {
        #expect(WatchGap.staleAfter(intervalSeconds: interval) == 90 * 60)
        #expect(WatchGap.staleAfter(intervalSeconds: 10 * 60) == 30 * 60)
        // Whatever the cadence, the window is always longer than one interval, so it is always reachable.
        for minutes in [1.0, 5.0, 30.0, 120.0] {
            let seconds = minutes * 60
            #expect(WatchGap.staleAfter(intervalSeconds: seconds) > seconds)
        }
    }

    // MARK: the awake gap

    // The ordinary case: ticks land on the cadence, the Mac is awake throughout, nothing is wrong.
    @Test func aTickOnTheCadenceIsNotAGap() {
        let previous = WatchGap.heartbeat(now: epoch, uptime: 10_000)
        let gap = WatchGap.outage(since: previous, now: after(interval), uptime: 10_000 + interval,
                                  intervalSeconds: interval)
        #expect(gap == nil)
    }

    // THE false positive this exists to be immune to. The Mac slept for eight hours: wall clock advanced
    // by eight hours, awake time did not advance at all, so nothing was missed and nothing is reported.
    // A wall-clock check would flag this every single morning, and an alert that cries wolf gets ignored.
    @Test func aMacAsleepAllNightIsNotAGap() {
        let previous = WatchGap.heartbeat(now: epoch, uptime: 10_000)
        // Eight hours of wall clock later, uptime has moved only the 60s the Mac was awake for.
        let gap = WatchGap.outage(since: previous, now: after(8 * 3_600), uptime: 10_060,
                                  intervalSeconds: interval)
        #expect(gap == nil)
    }

    // The window-close bug's own shape: the Mac stayed awake, the process did not. Awake time and wall
    // clock both advanced by three days, so this is a real outage and says so.
    @Test func aDeadProcessOnAnAwakeMacIsAGap() {
        let previous = WatchGap.heartbeat(now: epoch, uptime: 10_000)
        let threeDays = 3 * 86_400.0
        let gap = WatchGap.outage(since: previous, now: after(threeDays), uptime: 10_000 + threeDays,
                                  intervalSeconds: interval)
        #expect(gap == threeDays)
    }

    // A Mac that was SHUT DOWN for three days missed nothing it could have caught, and uptime resetting
    // is what tells the two apart: a reboot leaves uptime lower than the previous heartbeat's, and the
    // only unwatched awake time is what has elapsed since boot.
    @Test func aMacThatWasOffIsNotAGap() {
        let previous = WatchGap.heartbeat(now: epoch, uptime: 200_000)
        // Booted three days later and Overture came up at login: two minutes of uptime.
        let gap = WatchGap.outage(since: previous, now: after(3 * 86_400), uptime: 120,
                                  intervalSeconds: interval)
        #expect(gap == nil)
    }

    // The login agent failing is the same reboot shape with a very different answer: the Mac has been
    // awake for six hours since boot with nothing watching, which is exactly the blind spot #2091 names.
    @Test func aFailedLoginAgentIsAGapMeasuredFromBoot() {
        let previous = WatchGap.heartbeat(now: epoch, uptime: 200_000)
        let sixHours = 6 * 3_600.0
        let gap = WatchGap.outage(since: previous, now: after(3 * 86_400), uptime: sixHours,
                                  intervalSeconds: interval)
        #expect(gap == sixHours)
    }

    // Awake time can never exceed wall-clock time, so a bogus uptime (a restored snapshot, a clock the
    // OS adjusted) can never manufacture an outage longer than the elapsed time it happened in.
    @Test func theGapCanNeverExceedTheWallClockTimeItHappenedIn() {
        let previous = WatchGap.heartbeat(now: epoch, uptime: 10_000)
        // Uptime claims two days passed; the wall clock says four hours. Four hours is the honest ceiling.
        let fourHours = 4 * 3_600.0
        let gap = WatchGap.outage(since: previous, now: after(fourHours), uptime: 10_000 + 2 * 86_400,
                                  intervalSeconds: interval)
        #expect(gap == fourHours)
    }

    // A clock moved backwards makes no claim rather than a negative or wildly large one.
    @Test func aClockMovedBackwardsReportsNothing() {
        let previous = WatchGap.heartbeat(now: after(86_400), uptime: 10_000)
        #expect(WatchGap.outage(since: previous, now: epoch, uptime: 20_000, intervalSeconds: interval) == nil)
    }

    // Never having watched at all is not an outage: it is the first launch. The menu bar's own
    // "Watching for replies and bookings" idle state already covers that, and calling it an outage
    // would light this line on a fresh install for a reason that is not a failure (L11).
    @Test func noHeartbeatOnRecordIsNotAnOutage() {
        #expect(WatchGap.outage(since: WatchGap.Heartbeat(), now: epoch, uptime: 999_999,
                                intervalSeconds: interval) == nil)
    }

    // A gap that has not yet reached the window is not reported: two missed checks is not yet a fault.
    @Test func aGapShorterThanTheWindowIsNotReported() {
        let previous = WatchGap.heartbeat(now: epoch, uptime: 10_000)
        let short = 80 * 60.0                                   // inside the 90-minute window
        #expect(WatchGap.outage(since: previous, now: after(short), uptime: 10_000 + short,
                                intervalSeconds: interval) == nil)
        let long = 100 * 60.0                                   // past it
        #expect(WatchGap.outage(since: previous, now: after(long), uptime: 10_000 + long,
                                intervalSeconds: interval) == long)
    }

    // MARK: what gets reported, and for how long

    // While the ticks have stopped, the report is ONGOING: this is happening now, not history.
    @Test func aLiveGapReportsAsOngoing() {
        let previous = WatchGap.heartbeat(now: epoch, uptime: 10_000)
        let elapsed = 2 * 3_600.0
        let report = WatchGap.report(previous: previous, recorded: nil, now: after(elapsed),
                                     uptime: 10_000 + elapsed, intervalSeconds: interval)
        #expect(report == .ongoing(awakeSeconds: elapsed))
    }

    // The whole point of recording the outage: the resuming tick stamps a fresh heartbeat, so a moment
    // later there is nothing stale left to read. Without the recorded fact, opening Overture after three
    // days dead would show a perfectly healthy queue.
    @Test func aRecordedOutageIsStillReportedAfterWatchingResumes() {
        let resumedAt = after(3 * 86_400)
        let recorded = WatchGap.Outage(awakeSeconds: 3 * 86_400, endedAt: resumedAt.timeIntervalSince1970)
        // The heartbeat is now fresh, exactly as the resuming tick left it.
        let fresh = WatchGap.heartbeat(now: resumedAt, uptime: 200_000)
        let report = WatchGap.report(previous: fresh, recorded: recorded,
                                     now: resumedAt.addingTimeInterval(600), uptime: 200_600,
                                     intervalSeconds: interval)
        #expect(report == .recovered(awakeSeconds: 3 * 86_400, endedAt: resumedAt))
    }

    // The recovered notice is bounded rather than permanent: a day after watching resumed it has done
    // its job (it explains a quiet stretch Dan may still be looking at) and stops taking up the line.
    @Test func aRecoveredOutageStopsBeingReportedAfterADay() {
        let resumedAt = epoch
        let recorded = WatchGap.Outage(awakeSeconds: 3 * 86_400, endedAt: resumedAt.timeIntervalSince1970)
        let fresh = WatchGap.heartbeat(now: resumedAt, uptime: 200_000)
        #expect(WatchGap.report(previous: fresh, recorded: recorded, now: after(23 * 3_600),
                                uptime: 200_000, intervalSeconds: interval) != nil)
        #expect(WatchGap.report(previous: fresh, recorded: recorded, now: after(25 * 3_600),
                                uptime: 200_000, intervalSeconds: interval) == nil)
    }

    // A gap happening NOW outranks one that ended earlier: the live fault is the one Dan can act on.
    @Test func anOngoingGapOutranksARecoveredOne() {
        let previous = WatchGap.heartbeat(now: epoch, uptime: 10_000)
        let recorded = WatchGap.Outage(awakeSeconds: 99, endedAt: epoch.timeIntervalSince1970)
        let elapsed = 5 * 3_600.0
        let report = WatchGap.report(previous: previous, recorded: recorded, now: after(elapsed),
                                     uptime: 10_000 + elapsed, intervalSeconds: interval)
        #expect(report == .ongoing(awakeSeconds: elapsed))
    }

    // A healthy app reports nothing at all, so this line is never the one that is always there.
    @Test func ahealthyWatchReportsNothing() {
        let previous = WatchGap.heartbeat(now: epoch, uptime: 10_000)
        #expect(WatchGap.report(previous: previous, recorded: nil, now: after(interval),
                                uptime: 10_000 + interval, intervalSeconds: interval) == nil)
    }

    // MARK: what it says

    // Both surfaces (the queue masthead and the menu bar) build their sentence from this one function,
    // so the two can never come to say different things about the same fact.
    @Test func theOngoingLineNamesTheSilenceAndItsLength() {
        let line = WatchGap.line(for: .ongoing(awakeSeconds: 2 * 3_600), now: epoch)
        #expect(line == "Overture has not checked for replies or bookings in 2h")
    }

    @Test func theRecoveredLineNamesTheLengthAndWhenItEnded() {
        let endedAt = epoch
        let line = WatchGap.line(for: .recovered(awakeSeconds: 3 * 86_400, endedAt: endedAt),
                                 now: epoch.addingTimeInterval(12 * 60))
        #expect(line == "Overture was not checking for replies or bookings for 3d, and resumed 12m ago")
    }

    // MARK: the store

    // The round trip through UserDefaults, driven against a scratch suite rather than the real one.
    @Test func theHeartbeatAndOutageSurviveARelaunch() throws {
        let suite = "watch-gap-store-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(WatchHeartbeatStore.load(defaults) == WatchGap.Heartbeat())
        #expect(WatchHeartbeatStore.loadOutage(defaults) == nil)

        WatchHeartbeatStore.stamp(now: epoch, uptime: 10_000, into: defaults)
        #expect(WatchHeartbeatStore.load(defaults) == WatchGap.heartbeat(now: epoch, uptime: 10_000))
    }

    // The observation that has to happen BEFORE the resuming tick stamps, or the evidence is gone. The
    // ordering is the defect this guards: stamping first would leave a fresh heartbeat and no outage.
    @Test func resumingAfterAGapRecordsItBeforeTheFreshStampHidesIt() throws {
        let suite = "watch-gap-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        WatchHeartbeatStore.stamp(now: epoch, uptime: 10_000, into: defaults)
        let threeDays = 3 * 86_400.0
        let resumedAt = after(threeDays)
        WatchHeartbeatStore.observeResume(now: resumedAt, uptime: 10_000 + threeDays,
                                          intervalSeconds: interval, into: defaults)
        WatchHeartbeatStore.stamp(now: resumedAt, uptime: 10_000 + threeDays, into: defaults)

        let recorded = try #require(WatchHeartbeatStore.loadOutage(defaults))
        #expect(recorded.awakeSeconds == threeDays)
        #expect(recorded.endedAt == resumedAt.timeIntervalSince1970)
    }

    // An ordinary tick leaves no outage behind, so the line cannot be lit by normal operation.
    @Test func anOrdinaryTickRecordsNoOutage() throws {
        let suite = "watch-gap-ordinary-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        WatchHeartbeatStore.stamp(now: epoch, uptime: 10_000, into: defaults)
        WatchHeartbeatStore.observeResume(now: after(interval), uptime: 10_000 + interval,
                                          intervalSeconds: interval, into: defaults)
        #expect(WatchHeartbeatStore.loadOutage(defaults) == nil)
    }

    // A second, longer outage replaces the first rather than being dropped for it: the line must always
    // name the most recent silence, not the first one Overture ever noticed.
    @Test func aLaterOutageReplacesAnEarlierOne() throws {
        let suite = "watch-gap-latest-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        WatchHeartbeatStore.stamp(now: epoch, uptime: 10_000, into: defaults)
        let firstGap = 2 * 3_600.0
        WatchHeartbeatStore.observeResume(now: after(firstGap), uptime: 10_000 + firstGap,
                                          intervalSeconds: interval, into: defaults)
        WatchHeartbeatStore.stamp(now: after(firstGap), uptime: 10_000 + firstGap, into: defaults)

        let secondEnd = firstGap + 5 * 3_600
        WatchHeartbeatStore.observeResume(now: after(secondEnd), uptime: 10_000 + secondEnd,
                                          intervalSeconds: interval, into: defaults)
        let recorded = try #require(WatchHeartbeatStore.loadOutage(defaults))
        #expect(recorded.awakeSeconds == 5 * 3_600)
        #expect(recorded.endedAt == after(secondEnd).timeIntervalSince1970)
    }
}
