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
//   2. A sleeping Mac produces exactly the same wall-clock gap as a dead app.
//
// #2220 is the rewrite of the answer to the second one. The first version measured "awake time" from
// ProcessInfo.systemUptime, which is documented as excluding sleep and, measured on Dan's Mac, does not:
// it lost 7.6 minutes across 54 hours containing two nights, one with the lid shut for ten. So the line
// fired every morning, reporting his laptop being asleep as Overture having failed. Every test injected
// that clock as an argument, which made the whole suite structurally unable to notice (L52, L82).
//
// So there is no awake clock here now. Sleep is OBSERVED (NSWorkspace's sleep and wake notifications,
// accumulated by SystemSleep) and the process's own launch instant separates "Overture was not running"
// from "Overture was running and did not check", which are different faults and different sentences.
@Suite("Watch gap detection (#2091, #2220)")
struct WatchGapTests {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private let interval: Double = 30 * 60          // the ReconcileScheduler default cadence
    private func after(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

    // A Mac that has been up for a week, with Overture running the whole time and nothing having slept.
    private func healthyMac(sleptSeconds: Double = 0) -> WatchGap.Readings {
        WatchGap.Readings(sleptSeconds: sleptSeconds,
                          processStartedAt: epoch.timeIntervalSince1970 - 7 * 86_400,
                          quitCleanlyAt: 0,
                          bootedAt: epoch.timeIntervalSince1970 - 7 * 86_400 - 60)
    }

    private func beat(_ seconds: Double, slept: Double = 0) -> WatchGap.Heartbeat {
        WatchGap.Heartbeat(at: after(seconds).timeIntervalSince1970, sleptSeconds: slept)
    }

    // MARK: the threshold

    // L51: the staleness window is derived from the cadence that computes it, never a guessed constant.
    // A window shorter than the interval could never fire; three missed checks is Dan's call (2026-08-04).
    @Test func theWindowIsThreeMissedChecksOfWhateverTheCadenceIs() {
        #expect(WatchGap.staleAfter(intervalSeconds: interval) == 90 * 60)
        #expect(WatchGap.staleAfter(intervalSeconds: 10 * 60) == 30 * 60)
    }

    // MARK: Overture running and not checking

    @Test func aTickOnTheCadenceIsNotAGap() {
        let gap = WatchGap.notWatching(since: beat(0), now: after(interval),
                                       readings: healthyMac(), intervalSeconds: interval)
        #expect(gap == nil)
    }

    @Test func aGapShorterThanTheWindowIsNotReported() {
        let gap = WatchGap.notWatching(since: beat(0), now: after(89 * 60),
                                       readings: healthyMac(), intervalSeconds: interval)
        #expect(gap == nil)
    }

    @Test func fourHoursAwakeWithNoCheckIsAGap() {
        let fourHours = 4 * 3_600.0
        let gap = WatchGap.notWatching(since: beat(0), now: after(fourHours),
                                       readings: healthyMac(), intervalSeconds: interval)
        #expect(gap == fourHours)
    }

    // THE defect (#2220). Dan shuts the lid at 23:23 and opens it at 09:34; Overture was running the
    // whole time and could not have checked. Twelve hours of wall clock, ten of them asleep, and what is
    // left is under the window.
    @Test func aMacAsleepAllNightIsNotAGap() {
        // Measured from Dan's own Mac (fixtures/watch-gap-clock-measurement.json): lid shut 23:23:23,
        // opened 09:34:48. Overture ticked at 23:00 and again as soon as the lid opened.
        let night = 10 * 3_600.0 + 46 * 60
        let slept = 10 * 3_600.0 + 11 * 60 + 25
        let gap = WatchGap.notWatching(since: beat(0), now: after(night),
                                       readings: healthyMac(sleptSeconds: slept),
                                       intervalSeconds: interval)
        #expect(gap == nil, "his laptop being shut is not Overture failing")
    }

    // And the awake part of that same night still counts. Two hours awake with nothing checking is a
    // real finding, and it must not be swallowed along with the sleep.
    @Test func theAwakeHalfOfANightWithNoCheckIsStillAGap() {
        let gap = WatchGap.notWatching(since: beat(0), now: after(12 * 3_600.0),
                                       readings: healthyMac(sleptSeconds: 10 * 3_600.0),
                                       intervalSeconds: interval)
        #expect(gap == 2 * 3_600.0)
    }

    // A gap can never be longer than the wall-clock time it happened in, and sleep can never subtract
    // more than the whole window: a bogus accumulator must not be able to manufacture or erase one.
    @Test func sleepCanNeverSubtractMoreThanTheWindowItSitsIn() {
        let gap = WatchGap.notWatching(since: beat(0), now: after(4 * 3_600),
                                       readings: healthyMac(sleptSeconds: 99 * 3_600),
                                       intervalSeconds: interval)
        #expect(gap == nil)
    }

    @Test func aClockMovedBackwardsReportsNothing() {
        let gap = WatchGap.notWatching(since: beat(1_000), now: after(0),
                                       readings: healthyMac(), intervalSeconds: interval)
        #expect(gap == nil)
    }

    @Test func noHeartbeatOnRecordIsNotAnOutage() {
        let gap = WatchGap.notWatching(since: WatchGap.Heartbeat(), now: after(10 * 86_400),
                                       readings: healthyMac(), intervalSeconds: interval)
        #expect(gap == nil, "a fresh install has never watched; that is not a failure")
    }

    // MARK: Overture not running at all

    // The fault #2091 exists for: the process was gone, and it says so in those words rather than
    // claiming awake time nothing was there to measure.
    @Test func aProcessThatWasNotThereIsItsOwnFault() {
        let readings = WatchGap.Readings(sleptSeconds: 0,
                                         processStartedAt: after(6 * 3_600).timeIntervalSince1970,
                                         quitCleanlyAt: 0,
                                         bootedAt: epoch.timeIntervalSince1970 - 86_400)
        #expect(WatchGap.notRunning(since: beat(0), readings: readings, intervalSeconds: interval)
                == 6 * 3_600.0)
        #expect(WatchGap.notWatching(since: beat(0), now: after(6 * 3_600), readings: readings,
                                     intervalSeconds: interval) == nil,
                "one silence must never be reported twice under two names")
    }

    // A Mac that was OFF was not failing to watch. The gap is measured from boot, so the login agent
    // starting Overture promptly reports nothing however long the machine was off.
    @Test func aMacThatWasOffIsNotAGap() {
        let readings = WatchGap.Readings(sleptSeconds: 0,
                                         processStartedAt: after(3 * 86_400 + 20).timeIntervalSince1970,
                                         quitCleanlyAt: 0,
                                         bootedAt: after(3 * 86_400).timeIntervalSince1970)
        #expect(WatchGap.notRunning(since: beat(0), readings: readings, intervalSeconds: interval) == nil)
    }

    // And the case that is exactly the blind spot: the Mac came back but Overture did not, so it is six
    // hours since boot with nothing watching.
    @Test func aFailedLoginAgentIsAGapMeasuredFromBoot() {
        let readings = WatchGap.Readings(sleptSeconds: 0,
                                         processStartedAt: after(3 * 86_400 + 6 * 3_600).timeIntervalSince1970,
                                         quitCleanlyAt: 0,
                                         bootedAt: after(3 * 86_400).timeIntervalSince1970)
        #expect(WatchGap.notRunning(since: beat(0), readings: readings, intervalSeconds: interval)
                == 6 * 3_600.0)
    }

    // Dan quit it himself. Reporting a person's own decision back to them as a failure is how a report
    // stops being read (L36).
    @Test func aDeliberateQuitIsNotAFault() {
        let readings = WatchGap.Readings(sleptSeconds: 0,
                                         processStartedAt: after(12 * 3_600).timeIntervalSince1970,
                                         quitCleanlyAt: after(60).timeIntervalSince1970,
                                         bootedAt: epoch.timeIntervalSince1970 - 86_400)
        #expect(WatchGap.notRunning(since: beat(0), readings: readings, intervalSeconds: interval) == nil)
    }

    // A quit BEFORE the last heartbeat belongs to an earlier session and says nothing about this one, so
    // a stale marker must not silence a real crash afterwards.
    @Test func anOldCleanQuitDoesNotSilenceALaterCrash() {
        let readings = WatchGap.Readings(sleptSeconds: 0,
                                         processStartedAt: after(12 * 3_600).timeIntervalSince1970,
                                         quitCleanlyAt: epoch.timeIntervalSince1970 - 86_400,
                                         bootedAt: epoch.timeIntervalSince1970 - 2 * 86_400)
        #expect(WatchGap.notRunning(since: beat(0), readings: readings, intervalSeconds: interval)
                == 12 * 3_600.0)
    }

    // MARK: what gets reported

    @Test func aLiveGapReportsAsOngoing() {
        let report = WatchGap.report(previous: beat(0), recorded: nil, now: after(4 * 3_600),
                                     readings: healthyMac(), intervalSeconds: interval)
        #expect(report == .ongoing(awakeSeconds: 4 * 3_600))
    }

    @Test func ahealthyWatchReportsNothing() {
        let report = WatchGap.report(previous: beat(0), recorded: nil, now: after(interval),
                                     readings: healthyMac(), intervalSeconds: interval)
        #expect(report == nil)
    }

    @Test func aRecordedOutageIsStillReportedAfterWatchingResumes() {
        let recorded = WatchGap.Outage(cause: .notRunning, seconds: 5 * 3_600,
                                       endedAt: after(0).timeIntervalSince1970)
        let report = WatchGap.report(previous: beat(0), recorded: recorded, now: after(600),
                                     readings: healthyMac(), intervalSeconds: interval)
        #expect(report == .recovered(cause: .notRunning, seconds: 5 * 3_600, endedAt: after(0)))
    }

    @Test func aRecoveredOutageStopsBeingReportedAfterADay() {
        let recorded = WatchGap.Outage(cause: .notWatching, seconds: 5 * 3_600,
                                       endedAt: after(0).timeIntervalSince1970)
        let report = WatchGap.report(previous: beat(86_400 - 60), recorded: recorded,
                                     now: after(86_400 + 120), readings: healthyMac(),
                                     intervalSeconds: interval)
        #expect(report == nil)
    }

    @Test func anOngoingGapOutranksARecoveredOne() {
        let recorded = WatchGap.Outage(cause: .notRunning, seconds: 5 * 3_600,
                                       endedAt: after(0).timeIntervalSince1970)
        let report = WatchGap.report(previous: beat(0), recorded: recorded, now: after(4 * 3_600),
                                     readings: healthyMac(), intervalSeconds: interval)
        #expect(report == .ongoing(awakeSeconds: 4 * 3_600))
    }

    // MARK: the sentence

    @Test func theOngoingLineNamesTheSilenceAndItsLength() {
        let line = WatchGap.line(for: .ongoing(awakeSeconds: 4 * 3_600), now: after(0))
        #expect(line == "Overture has not checked for replies or bookings in 4h")
    }

    @Test func theRecoveredNotWatchingLineNamesTheLengthAndWhenItEnded() {
        let line = WatchGap.line(for: .recovered(cause: .notWatching, seconds: 5 * 3_600,
                                                 endedAt: after(0)), now: after(3_600))
        #expect(line.hasPrefix("Overture was not checking for replies or bookings for 5h, and resumed "))
    }

    // A different fault gets a different sentence: this one claims nothing about awake time, because
    // nothing was there to measure it (L11).
    @Test func theRecoveredNotRunningLineSaysTheAppWasNotThere() {
        let line = WatchGap.line(for: .recovered(cause: .notRunning, seconds: 5 * 3_600,
                                                 endedAt: after(0)), now: after(3_600))
        #expect(line.hasPrefix("Overture was not running for 5h, and started again "))
    }

    // MARK: the stored side

    private func scratch(_ name: String) throws -> UserDefaults {
        let suite = "overture.watchgap.test.\(name).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func theHeartbeatAndOutageSurviveARelaunch() throws {
        let defaults = try scratch("roundtrip")
        WatchHeartbeatStore.stamp(now: after(0), readings: healthyMac(sleptSeconds: 120), into: defaults)
        #expect(WatchHeartbeatStore.load(defaults) == beat(0, slept: 120))

        defaults.set(5 * 3_600.0, forKey: WatchHeartbeatStore.outageSecondsKey)
        defaults.set(after(0).timeIntervalSince1970, forKey: WatchHeartbeatStore.outageEndedAtKey)
        defaults.set(WatchGap.Cause.notRunning.rawValue, forKey: WatchHeartbeatStore.outageCauseKey)
        #expect(WatchHeartbeatStore.loadOutage(defaults)?.cause == .notRunning)
    }

    // A stored cause this build cannot read is not scored as one of today's two. Defaulting would put
    // the awake-time sentence on a silence nothing measured awake time for (L11).
    @Test func anUnreadableStoredCauseIsNotGuessedAt() throws {
        let defaults = try scratch("badcause")
        defaults.set(5 * 3_600.0, forKey: WatchHeartbeatStore.outageSecondsKey)
        defaults.set(after(0).timeIntervalSince1970, forKey: WatchHeartbeatStore.outageEndedAtKey)
        defaults.set("somethingLater", forKey: WatchHeartbeatStore.outageCauseKey)
        #expect(WatchHeartbeatStore.loadOutage(defaults) == nil)
    }

    @Test func resumingAfterAGapRecordsItBeforeTheFreshStampHidesIt() throws {
        let defaults = try scratch("resume")
        WatchHeartbeatStore.stamp(now: after(0), readings: healthyMac(), into: defaults)

        let now = after(6 * 3_600)
        WatchHeartbeatStore.observeResume(now: now, readings: healthyMac(),
                                          intervalSeconds: interval, into: defaults)
        WatchHeartbeatStore.stamp(now: now, readings: healthyMac(), into: defaults)

        let outage = WatchHeartbeatStore.loadOutage(defaults)
        #expect(outage?.seconds == 6 * 3_600.0)
        #expect(outage?.cause == .notWatching)
        #expect(WatchHeartbeatStore.currentReport(now: now.addingTimeInterval(60),
                                                  intervalSeconds: interval, defaults: defaults)
                == .recovered(cause: .notWatching, seconds: 6 * 3_600, endedAt: now))
    }

    @Test func anOrdinaryTickRecordsNoOutage() throws {
        let defaults = try scratch("ordinary")
        WatchHeartbeatStore.stamp(now: after(0), readings: healthyMac(), into: defaults)
        WatchHeartbeatStore.observeResume(now: after(interval), readings: healthyMac(),
                                          intervalSeconds: interval, into: defaults)
        #expect(WatchHeartbeatStore.loadOutage(defaults) == nil)
    }

    // #2220 step 3: the verdict currently in Dan's defaults was reached with the retired clock, so it is
    // a false twelve-hour outage that would render for a day. Keyed on that clock's own reading, so it
    // runs once per Mac and is a no-op forever after.
    @Test func averdictFromTheRetiredClockIsDiscardedOnce() throws {
        let defaults = try scratch("discard")
        defaults.set(188_460.0, forKey: WatchHeartbeatStore.retiredUptimeKey)
        defaults.set(after(0).timeIntervalSince1970, forKey: WatchHeartbeatStore.heartbeatAtKey)
        defaults.set(12.02 * 3_600, forKey: WatchHeartbeatStore.outageSecondsKey)
        defaults.set(after(0).timeIntervalSince1970, forKey: WatchHeartbeatStore.outageEndedAtKey)
        defaults.set(WatchGap.Cause.notWatching.rawValue, forKey: WatchHeartbeatStore.outageCauseKey)

        WatchHeartbeatStore.discardVerdictsFromTheRetiredClock(defaults)

        #expect(WatchHeartbeatStore.loadOutage(defaults) == nil)
        #expect(WatchHeartbeatStore.load(defaults).at == 0, "a fresh baseline, taken on the next tick")
        #expect(defaults.object(forKey: WatchHeartbeatStore.retiredUptimeKey) == nil)

        // And it leaves a later, honestly-measured outage alone.
        defaults.set(5 * 3_600.0, forKey: WatchHeartbeatStore.outageSecondsKey)
        defaults.set(after(0).timeIntervalSince1970, forKey: WatchHeartbeatStore.outageEndedAtKey)
        defaults.set(WatchGap.Cause.notRunning.rawValue, forKey: WatchHeartbeatStore.outageCauseKey)
        WatchHeartbeatStore.discardVerdictsFromTheRetiredClock(defaults)
        #expect(WatchHeartbeatStore.loadOutage(defaults)?.seconds == 5 * 3_600.0)
    }
}
