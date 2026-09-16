import Testing
import Foundation

// #3785: what the app does on the main thread at launch, before Dan sees a usable window.
//
// WHY IT BELONGS IN THIS MILESTONE. Every other instrument here measures a store change or a redraw.
// Nothing measures launch. The milestone's bar is the stall distribution in `freeze-log.ndjson`, and a
// stall during launch lands in that file exactly like a stall during a press, so a bar read off that
// file while launch is unmeasured is a bar nobody can attribute (#3785).
//
// WHAT IT DRIVES, and what it cannot. `RootView`'s launch task calls six things in order, on the main
// actor. Four of them are private methods of a SwiftUI view, which no test can call, so this drives the
// DOMAIN WORK each one performs and says so, rather than reporting a number for a step it never ran:
//
//   reportAnyBoundaryViolation()   -> RunBoundaryViolations.newlyReported(in:)          DRIVEN
//   freezeWatch.start(support:)    -> not driven: it starts a Dispatch queue and returns; what it
//                                    costs is one file read, and the watchdog's own ceiling is
//                                    `WatchdogCostTests`, which already holds it
//   runFreezeLogHousekeeping()     -> FreezeLog.housekeeping(at:now:)                   DRIVEN
//   reportWhatWasRecorded()        -> CardDivergenceReport.newlyReported(in:)           DRIVEN
//   reattachScoutExtractRun()      -> not driven: it awaits a detached run to completion, so its cost
//                                    is that run's, not launch's. `ScoutExtractService.isRunning` is
//                                    the part launch always pays, and it IS driven
//   autoScoutIfDue()               -> not driven: on the due branch it starts a scout, which is the
//                                    thing being launched rather than a launch cost. The marker reads
//                                    that DECIDE it are driven
//
// AGAINST DAN'S REAL FILES, copied. The freeze log is the one input here whose size is the whole
// question: a fixture of five records would measure a different function from the one that runs, and
// `FreezeLog.housekeeping` WRITES, so it runs against a copy rather than against the live file (L2).
//
// IT REPORTS, it does not assert a threshold. A millisecond ceiling here would be measuring whatever
// else the Mac is doing (L224), and the reason to have the numbers is to know which term to attack.
// @MainActor because two of the launch steps it drives are: `ScoutExtractService.isRunning` and
// `PrepQueueService.slotStatus` are main-actor isolated, which is itself part of what this measures.
// Launch does that work ON the main thread, so a suite that drove them from anywhere else would be
// timing something the app never does (L472).
@MainActor
@Suite("What launch costs on the main thread (#3785)")
final class LaunchCostTests {

    // A PROPERTY of a final class suite, which is how `scripts/check-temp-dir-leaks.sh` wants it: the
    // sandboxes are cleaned up when the suite instance goes, rather than by counting call sites.
    private let sandboxes = TemporarySandboxes()

    private func seconds(_ work: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private func median(_ work: () -> Void) -> (median: Double, low: Double, high: Double) {
        var runs: [Double] = []
        for _ in 0..<5 { runs.append(seconds(work)) }
        runs.sort()
        return (runs[2], runs[0], runs[4])
    }

    @Test func measureWhatLaunchDoesBeforeTheFirstFrame() throws {
        guard ProcessInfo.processInfo.environment["MEASURE_LAUNCH"] != nil else {
            // Not silently skipped: an instrument that says nothing is indistinguishable from one that
            // ran and found nothing (L98).
            print("launch-cost: not measured. Set TEST_RUNNER_MEASURE_LAUNCH=1 to run it.")
            return
        }

        let live = StoreLocation.handoffDirectory
        let liveLog = FreezeLog.url(in: live)
        guard FileManager.default.fileExists(atPath: liveLog.path) else {
            // UNMEASURED is its own outcome: a machine with no freeze log yet is not a machine whose
            // launch is cheap (L98).
            print("launch-cost: UNMEASURED. No freeze log at \(liveLog.path), so the term this exists "
                  + "to size has nothing in it on this Mac.")
            return
        }

        // A copy, because housekeeping WRITES, and the live log is the record Dan's own freezes are in.
        let work = try sandboxes.make(named: "launch-cost")
        let copiedLog = FreezeLog.url(in: work)
        try FileManager.default.copyItem(at: liveLog, to: copiedLog)
        let archive = FreezeLog.archiveURL(besideLogAt: liveLog)
        if FileManager.default.fileExists(atPath: archive.path) {
            try? FileManager.default.copyItem(at: archive, to: FreezeLog.archiveURL(besideLogAt: copiedLog))
        }

        let records = FreezeLog.read(at: copiedLog).records.count
        let now = Date()

        // Each term as launch calls it. The freeze log read is timed apart from the housekeeping that
        // contains it, because "the log is big" and "compacting it is slow" are different facts.
        let readTerm = median { _ = FreezeLog.read(at: copiedLog) }
        // Housekeeping is run ONCE and not in a median: it compacts, so the second run would be timing
        // an already compacted file, which is a different question from the one launch asks (L102).
        let fresh = try sandboxes.make(named: "launch-cost-housekeeping")
        let freshLog = FreezeLog.url(in: fresh)
        try FileManager.default.copyItem(at: copiedLog, to: freshLog)
        let housekeepingSeconds = seconds { _ = FreezeLog.housekeeping(at: freshLog, now: now) }

        let boundaryTerm = median { _ = RunBoundaryViolations.newlyReported(in: live) }
        let divergenceTerm = median { _ = CardDivergenceReport.newlyReported(in: live, now: now) }
        let scoutMarkerTerm = median { _ = ScoutExtractService.isRunning(now: now) }
        let slotTerm = median { _ = PrepQueueService.slotStatus(now: now) }

        func ms(_ s: Double) -> String { String(format: "%.1f", s * 1000) }
        func spread(_ t: (median: Double, low: Double, high: Double)) -> String {
            "(5 runs, \(ms(t.low)) to \(ms(t.high)))"
        }

        let driven = readTerm.median + boundaryTerm.median + divergenceTerm.median
            + scoutMarkerTerm.median + slotTerm.median + housekeepingSeconds

        print("""
        launch-cost: what RootView's launch task does on the main thread, before the first usable frame
          freeze log records          \(records)

          reportAnyBoundaryViolation, as RunBoundaryViolations.newlyReported:
                                      \(ms(boundaryTerm.median)) ms   \(spread(boundaryTerm))
          the freeze log READ alone, which housekeeping below contains:
                                      \(ms(readTerm.median)) ms   \(spread(readTerm))
          runFreezeLogHousekeeping, as FreezeLog.housekeeping. ONE run, not a median: it compacts, so a
          second run would time an already compacted file, which is not the question launch asks:
                                      \(ms(housekeepingSeconds)) ms
          reportWhatWasRecorded, as CardDivergenceReport.newlyReported:
                                      \(ms(divergenceTerm.median)) ms   \(spread(divergenceTerm))
          the scout-extract marker read that decides whether to reattach:
                                      \(ms(scoutMarkerTerm.median)) ms   \(spread(scoutMarkerTerm))
          the prep and check slot markers autoScoutIfDue decides from:
                                      \(ms(slotTerm.median)) ms   \(spread(slotTerm))

          everything above, summed     \(ms(driven)) ms

        WHAT THIS SUM IS NOT. It is the launch work this suite can DRIVE, not the launch. Three steps are
        outside it and each is named rather than folded in: `freezeWatch.start` (a Dispatch queue and one
        file read, whose ceiling is WatchdogCostTests), `reattachScoutExtractRun` (it awaits a detached
        run, so its cost belongs to that run), and `autoScoutIfDue` on its due branch (it starts a scout,
        which is the thing being launched). Nor does it include the store open, the first @Query, or the
        first render pass, which QueueRenderPassLiveStoreCostTests prices separately.
        """)

        // The control, asserted, so a reading of "launch is free" cannot be a harness that measured
        // nothing (L98, L159).
        #expect(records > 0, """
            the copied freeze log holds no records, so every term above was measured against an empty \
            file and none of them says anything about Dan's launch
            """)
        #expect(driven > 0, "no term above measured any time at all, which cannot be right")
    }
}
