import Testing
import Foundation

// #3796: `FreezeLog.housekeeping` was called once, in `RootView`'s launch task, and Overture is installed
// as a login agent that stays resident in the menu bar. "At launch" is therefore as far apart as Dan's
// logins: measured 2026-09-11, the live log held 700 records against a cap of 500, and the process holding
// it was 23 hours old. The archive's month-long retention rode the same rare event, so a month really meant
// "until Dan next logs in".
//
// The fix is a SCHEDULE beside the launch call, on the hourly loop that already exists in `RootView` rather
// than a third cadence of its own. Two things are guarded here, because either alone proves nothing: that
// the loop does its work on EVERY tick (exercised, with the sleep injected, so nothing waits an hour), and
// that the app's hourly tick is actually wired to the housekeeping (source, because a `.task` inside a
// SwiftUI view has no other seam and this is the file's established pattern).
@MainActor
@Suite("The freeze log is bounded while the app runs, not only at launch (#3796)")
final class TheFreezeLogIsBoundedWhileTheAppRunsTests {

    private let sandboxes = TemporarySandboxes()

    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    private func stall(_ seconds: Double, sequence: Int, at: Date) -> StallRecord {
        StallRecord(session: "s", sequence: sequence, at: at, seconds: seconds,
                    surface: .queue, load: .baseline, loadAverage: 1.0, passes: nil)
    }

    // MARK: - the loop

    // THE ONE THAT MATTERS. Once was the defect, so a loop that ticks once is not a fix.
    @Test("the hourly loop does its work on every tick, not once")
    func everyTickDoesTheWork() async {
        var ticks = 0
        var slept: [TimeInterval] = []
        await HourlyMaintenance.run(sleep: { slept.append($0) },
                                    isCancelled: { ticks >= 3 },
                                    tick: { ticks += 1 })
        #expect(ticks == 3, "the tick's work did not run once per interval")
        // Each wait is the real interval, so the loop cannot pass this by spinning without waiting.
        #expect(slept == Array(repeating: HourlyMaintenance.intervalSeconds, count: 3),
                "the loop did not wait its own interval between ticks: \(slept)")
    }

    // A cancelled sleep RETURNS rather than throwing, so the obvious loop shape runs one more full tick on
    // the way out. That tick is a file read and rewrite at the moment the window that owns it is going away.
    @Test("a cancelled loop does no work on the way out")
    func cancellationIsReadAgainAfterTheSleep() async {
        var ticks = 0
        var cancelled = false
        await HourlyMaintenance.run(sleep: { _ in cancelled = true },
                                    isCancelled: { cancelled },
                                    tick: { ticks += 1 })
        #expect(ticks == 0, "the loop ran a tick after it had been cancelled")
    }

    // The cadence is checked as a RANGE rather than against the literal it happens to hold, because the
    // decision recorded in #3796 is "long enough to cost nothing, short enough to mean something" and a
    // guard on the exact number would go red on any refinement of it while protecting neither end (L103).
    @Test("the cadence is neither the minute loop nor a day")
    func theCadenceIsInTheBandTheIssueAsksFor() {
        #expect(HourlyMaintenance.intervalSeconds >= 10 * 60,
                "a read-modify-write of the log this often is paying a rewrite for a file that did not change")
        #expect(HourlyMaintenance.intervalSeconds <= 24 * 60 * 60,
                "a period this long is the launch-only defect again, wearing a timer")
    }

    // MARK: - the wiring

    // A loop that ticks and an app that calls it are two different claims (L3).
    @Test("the app's hourly task is this loop")
    func theHourlyTaskRunsTheSharedLoop() {
        #expect(!rootView.isEmpty)
        // Bound to a Bool before the expectation rather than written inline, because a failing
        // expectation RENDERS its operands and `rootView.contains(...)` renders the whole of RootView
        // between the reader and the sentence saying what went wrong (L445). Measured on this suite's own
        // red run: 2,800 lines of source under the first failure.
        let runsTheSharedLoop = rootView.contains("await HourlyMaintenance.run")
        #expect(runsTheSharedLoop, "RootView's hourly task is not running the shared loop")
        let holdsItsOwnHourlySleep = rootView.contains("60 * 60 * 1_000_000_000")
        #expect(!holdsItsOwnHourlySleep,
                "RootView still holds its own inline hourly sleep, so there are two hourly cadences")
    }

    @Test("the hourly tick runs the freeze log's housekeeping")
    func theHourlyTickDoesTheHousekeeping() {
        guard let body = SourceGuardHelper.bodyOfFunction(named: "hourlyMaintenance", in: rootView) else {
            Issue.record("hourlyMaintenance body not found in RootView"); return
        }
        #expect(body.contains("runFreezeLogHousekeeping()"),
                "the hourly tick does not bound the freeze log, which is the whole of #3796")
        // The tick's other half is still there: this is an addition to the hourly work, not a replacement.
        #expect(body.contains("autoScoutIfDue()"),
                "the scout schedule lost its hourly tick")
    }

    // The launch call stays, and it stays BEFORE the report that reads the file it has just rewritten.
    @Test("the launch task still does the housekeeping, before it reports what the log holds")
    func theLaunchCallSurvivesAndKeepsItsOrder() {
        guard let launchRegion = SourceGuardHelper.between("freezeWatch.start(", and: "reportAnyFreezes()",
                                                           in: rootView) else {
            Issue.record("the launch task's freeze block was not found in RootView"); return
        }
        let launchBoundsTheLog = launchRegion.contains("runFreezeLogHousekeeping()")
        #expect(launchBoundsTheLog, "the launch task no longer bounds the log before reporting on it")
    }

    // ONE implementation, so the launch call and the scheduled one cannot drift into doing different
    // things (L613). Both call sites go through the same private method, which is the only place in the
    // view that names the domain call.
    @Test("there is one housekeeping implementation, not one per caller")
    func bothCallersShareOneImplementation() {
        // #3828 RE-AIMED THIS, and it is not a reversal of #3796. The claim is unchanged: the launch task
        // and the hourly tick must reach ONE implementation, so they cannot drift into doing different
        // things. What changed is where that implementation lives. The work is no longer done on the main
        // actor (it cost 12.75 ms of a frame in the hour it compacts), so `RootView` now names the
        // housekeeper and the housekeeper names the domain call.
        let named = rootView.components(separatedBy: "FreezeLogHousekeeper.shared.run(").count - 1
        #expect(named == 1,
                Comment(rawValue: "RootView names the housekeeper \(named) times, so its callers can "
                        + "drift apart (#3796, #3828)"))
        let doesItOnTheMainActor = rootView.components(separatedBy: "FreezeLog.housekeeping(").count - 1
        #expect(doesItOnTheMainActor == 0,
                Comment(rawValue: "RootView calls FreezeLog.housekeeping directly \(doesItOnTheMainActor) "
                        + "time(s), which is the read, modify, write #3828 took off the main actor"))
        guard let body = SourceGuardHelper.bodyOfFunction(named: "runFreezeLogHousekeeping", in: rootView) else {
            Issue.record("runFreezeLogHousekeeping body not found in RootView"); return
        }
        #expect(body.contains("FreezeLogHousekeeper.shared.run(at:"),
                "the shared method does not actually hand the housekeeping to the housekeeper")
    }

    // MARK: - running it more often has to be harmless

    // #3796 asks for this in as many words: a launch immediately after a scheduled run must be a no-op.
    // Now that it runs every hour rather than once, a housekeeping that did something on a file already
    // housekept would rewrite two files hourly for the life of the session.
    @Test("a second housekeeping over the same files changes nothing")
    func housekeepingIsIdempotent() throws {
        let dir = try sandboxes.make(named: "freeze-idempotent")
        let log = FreezeLog.url(in: dir)
        let archive = FreezeLog.archiveURL(besideLogAt: log)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 60 * 60 * 24
        let window = Double(FreezeLog.archiveRetentionDays) * day
        // Enough to give the first call both halves of its work: records to archive, and archived records
        // old enough to prune. A pair that both did nothing would make this test agree with anything.
        let old = (0..<6).map { stall(Double($0) * 0.1 + 0.2, sequence: $0 + 1,
                                      at: now.addingTimeInterval(-window - Double(90 - $0) * day)) }
        let recent = (0..<4).map { stall(0.9 + Double($0) * 0.1, sequence: $0 + 7,
                                         at: now.addingTimeInterval(-day)) }
        for record in old + recent { _ = FreezeLog.append(record, to: log) }

        let first = FreezeLog.housekeeping(at: log, now: now, cap: 4)
        #expect(first.compaction == .archived(count: 6), "the first call did not do the work this asks about")
        let liveAfterFirst = try Data(contentsOf: log)
        let archiveAfterFirst = try? Data(contentsOf: archive)

        let second = FreezeLog.housekeeping(at: log, now: now, cap: 4)

        #expect(second.compaction == .nothingToArchive,
                "the second call archived again: \(second.compaction)")
        #expect(second.prune == .nothingToRemove,
                "the second call pruned again: \(second.prune)")
        #expect((try? Data(contentsOf: log)) == liveAfterFirst, "the second call rewrote the live log")
        #expect((try? Data(contentsOf: archive)) == archiveAfterFirst, "the second call rewrote the archive")
    }
}
