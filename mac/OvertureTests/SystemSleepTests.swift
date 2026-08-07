import Testing
import Foundation
import Darwin

// #2220. The watch-gap rule needs to know how much of a stretch of wall clock the Mac spent asleep.
// #2091 took that from `ProcessInfo.systemUptime`, whose documentation says it counts awake time only.
//
// It does not, on this hardware. This suite is the measurement that says so, and the accumulator that
// replaced it.
@Suite("How much of a gap the Mac spent asleep (#2220)")
struct SystemSleepTests {
    private func scratch(_ name: String) throws -> UserDefaults {
        let suite = "overture.sleep.test.\(name).\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

    // MARK: the accumulator

    @Test func aSleepAndWakeAddTheirSpan() throws {
        let d = try scratch("span")
        #expect(SystemSleep.totalSeconds(now: at(0), in: d) == 0)

        SystemSleep.willSleep(now: at(100), into: d)
        SystemSleep.didWake(now: at(100 + 8 * 3_600), into: d)

        #expect(SystemSleep.totalSeconds(now: at(99_999), in: d) == 8 * 3_600)
    }

    @Test func spansAccumulateAcrossNights() throws {
        let d = try scratch("nights")
        SystemSleep.willSleep(now: at(0), into: d)
        SystemSleep.didWake(now: at(3_600), into: d)
        SystemSleep.willSleep(now: at(86_400), into: d)
        SystemSleep.didWake(now: at(86_400 + 7_200), into: d)
        #expect(SystemSleep.totalSeconds(now: at(200_000), in: d) == 3 * 3_600)
    }

    // The race that decides whether any of this works. The scheduler waits on a clock that keeps running
    // through sleep, so its timer comes due the instant the Mac wakes, and it can reach the reading
    // before the wake notification has been handled. An open span read at that moment must count as
    // sleep up to now, or the very tick that resumes after a night reads the night as awake time and
    // reports the false outage this issue is about.
    @Test func aSpanStillOpenAtReadingTimeCountsUpToNow() throws {
        let d = try scratch("race")
        SystemSleep.willSleep(now: at(0), into: d)
        #expect(SystemSleep.totalSeconds(now: at(8 * 3_600), in: d) == 8 * 3_600,
                "we are awake to be asking, so an open span means the wake is not handled YET")
    }

    // And handling the wake afterwards must not double-count it.
    @Test func handlingTheWakeAfterwardsAddsNothingTwice() throws {
        let d = try scratch("noduplicate")
        SystemSleep.willSleep(now: at(0), into: d)
        _ = SystemSleep.totalSeconds(now: at(8 * 3_600), in: d)
        SystemSleep.didWake(now: at(8 * 3_600), into: d)
        #expect(SystemSleep.totalSeconds(now: at(9 * 3_600), in: d) == 8 * 3_600)
    }

    // The failure path: a wake with no sleep recorded before it (the app launched while the Mac was
    // already awake, or the notification arrived alone). Nothing is known about a span that was never
    // opened, so nothing is claimed.
    @Test func aWakeWithNoSleepBeforeItAddsNothing() throws {
        let d = try scratch("orphanwake")
        SystemSleep.didWake(now: at(8 * 3_600), into: d)
        #expect(SystemSleep.totalSeconds(now: at(9 * 3_600), in: d) == 0)
    }

    // A clock that went backwards between the two notifications cannot produce a negative night.
    @Test func aBackwardsClockNeverSubtractsSleep() throws {
        let d = try scratch("backwards")
        SystemSleep.willSleep(now: at(3_600), into: d)
        SystemSleep.didWake(now: at(0), into: d)
        #expect(SystemSleep.totalSeconds(now: at(9_000), in: d) == 0)
    }

    // MARK: the measurement that retired the old clock

    // Read from the REAL clocks on the machine running this, not from a stub. L82: when a platform
    // primitive's documented guarantee is the entire reason a guard is safe, measure that guarantee on
    // the real target, because every test that injects the value agrees with the documentation by
    // construction and the suite is structurally unable to notice.
    //
    // Deliberately asserts the RELATIONSHIP between the clocks rather than a number, so it says
    // something true on any Mac and at any moment: the "uptime" family and `mach_absolute_time` are one
    // reading, not several independent opinions, so no amount of picking between them can produce a
    // clock that excludes sleep.
    @Test func theUptimeClocksAreAllOneReading() {
        var ts = timespec()
        clock_gettime(clockid_t(CLOCK_UPTIME_RAW.rawValue), &ts)
        let uptimeRaw = Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9

        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let machAbsolute = Double(mach_absolute_time()) * Double(info.numer) / Double(info.denom) / 1e9

        let systemUptime = ProcessInfo.processInfo.systemUptime

        #expect(abs(uptimeRaw - systemUptime) < 1.0)
        #expect(abs(machAbsolute - systemUptime) < 1.0)
    }

    // The recorded sample, measured on Dan's Mac on 2026-08-06 at 23:20 by reading every clock against
    // `kern.boottime` in one process (the numbers are in the fixture, and repeated in `SystemSleep`).
    // That 54.19 hour window contained two nights, one with the lid shut for ten hours by `pmset -g log`,
    // and the awake clock lost 7.6 minutes of it.
    //
    // A fixture rather than a live reading because the thing being asserted needs a real sleep to have
    // happened inside the window, which no test can arrange (L48: measured from real data, never shaped
    // to make the point). It exists so the next person to reach for `systemUptime` here meets the
    // measurement instead of the documentation.
    @Test func theRecordedMeasurementShowsTheAwakeClockRanThroughTenHoursOfSleep() throws {
        let url = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/watch-gap-clock-measurement.json")
        let data = try Data(contentsOf: url)
        let m = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        let wall = try #require(m["wallClockSinceBootSeconds"] as? Double)
        let awake = try #require(m["processInfoSystemUptimeSeconds"] as? Double)
        let sleptInWindow = try #require(m["observedSleepSecondsInWindow"] as? Double)

        #expect(sleptInWindow > 9 * 3_600, "the window really did contain a long sleep")
        #expect(wall - awake < 15 * 60,
                "and the clock documented to exclude sleep excluded almost none of it")
    }

    // MARK: the guard against reintroducing it

    // The measurement above cannot fail if somebody simply goes back to reading the old clock, so this
    // does. Named clocks rather than a general rule, because these are exactly the four that were
    // measured and found to run through sleep.
    @Test func nothingInTheWatchGapPathReadsAnAwakeClock() {
        let banned = ["systemUptime", "mach_absolute_time", "CLOCK_UPTIME_RAW", "mach_continuous_time"]
        for path in ["Overture/Domain/WatchGap.swift",
                     "Overture/App/ReconcileScheduler.swift",
                     "Overture/UI/WatchGapLine.swift",
                     "Overture/App/SleepObserver.swift"] {
            let source = SourceGuardHelper.source(path)
            #expect(!source.isEmpty, "\(path) must exist for this guard to mean anything")
            for clock in banned {
                // The prose in WatchGap and SystemSleep names these on purpose, to record why they are
                // not used. Only CODE is banned, so the comment lines are dropped first.
                let code = source.split(separator: "\n")
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                #expect(!code.contains(clock),
                        "\(path) reads \(clock), which was measured running through ten hours of sleep")
            }
        }
    }
}
