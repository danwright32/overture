import Testing
import Foundation

// #3828: #3796 moved `FreezeLog.housekeeping` onto `RootView`'s hourly tick, which runs on the MAIN
// ACTOR, and nothing measured what it costs there.
//
// At LAUNCH that was accepted, because a launch is already doing heavy work and nobody is waiting on a
// frame. Hourly, for the whole life of a resident process, is a different question, and it is precisely
// the question this milestone exists to ask: main thread cost on a surface Dan is looking at.
//
// THIS IS NOT A CLAIM THAT IT IS EXPENSIVE. It is a claim that it was UNMEASURED, on the one path where
// "probably fine" is the thing this milestone has been correcting all week. The same reasoning made a
// 69 ms call invisible on the Sources sheet for days (#3829).
//
// BOTH CASES ARE MEASURED, and that is the half a single reading would get wrong. `housekeeping` returns
// early when the file is at or under its cap, which is what it does 23 hours out of 24, so a figure taken
// only in that state measures the short circuit and reassures about exactly the case nobody tested
// (L102). The working case rewrites the file and writes the archive.
@Suite("What the hourly freeze-log maintenance costs the main actor (#3828)")
final class WhatTheHourlyMaintenanceCostsTests {
    private let sandboxes = TemporarySandboxes()

    // THE CEILING is a RATCHET on the work itself rather than a budget for the main actor, and the
    // difference is the whole finding. The first reading of this test put the working case at 12.75 ms
    // against a 10 ms ceiling derived from #3660's bar, and that red was correct: the answer was not to
    // raise the ceiling but to take the work off the main actor, which #3828 asks for in those words.
    //
    // What is left to guard is that the work does not change in KIND as the file grows. A per-record file
    // open, or a second full parse, would show here. Set far above the measurement rather than just over
    // it, so anything approaching it is a change in kind and not noise (L172).
    private static let ceilingSeconds = 0.100

    // One frame at 60Hz, for the report only. Naming it makes the figure readable without making it the
    // thing that decides.
    private static let oneFrameSeconds = 1.0 / 60.0

    // The whole fixture's clock, taken once, and every record placed RELATIVE to it. The runs below are
    // given `Date()`, so both ends of the relationship move together and the fixture cannot age into a
    // different case (L130).
    //
    // WHY IT IS RELATIVE. The first version dated these from a fixed 2025-10-09 epoch, and the archive's
    // 31-day retention then deleted every record the compaction had just archived, so the concurrency
    // test read an EMPTY archive and "no record was archived twice" was trivially true of nothing. Its
    // positive control is what caught it (L98, L159). 800 records at ten minutes apart spans about five
    // and a half days, comfortably inside the retention window and far from its edge (L401).
    private let base = Date()

    private func record(_ n: Int) -> StallRecord {
        StallRecord(session: "cost-\(n / 100)", sequence: n,
                    // Spread over real time, ascending like the real file, so the archive prune has dates
                    // to judge rather than one instant.
                    at: base.addingTimeInterval(Double(n - 800) * 600),
                    seconds: 0.1 + Double(n % 40) / 10, surface: .queue, load: .baseline,
                    loadAverage: 3.7, passes: n % 3)
    }

    private func write(_ count: Int, to url: URL) throws {
        let text = (0..<count).compactMap { FreezeLog.line(for: record($0)) }.joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func seconds(_ work: () -> Void) -> Double {
        let started = DispatchTime.now().uptimeNanoseconds
        work()
        return Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
    }

    @Test func thehourlyTickCostsLittleEnoughToRunOnTheMainActor() throws {
        let dir = try sandboxes.make(named: "hourly-maintenance-cost")

        // THE QUIET CASE: a file exactly at its cap, which is what the tick finds almost every hour. It
        // reads the whole file and writes nothing.
        let quietLog = dir.appendingPathComponent("quiet-\(FreezeLog.fileName)")
        try write(FreezeLog.fileCap, to: quietLog)
        let quiet = seconds { _ = FreezeLog.housekeeping(at: quietLog, now: Date()) }

        // THE WORKING CASE: a file over its cap, so the compaction archives what it drops and rewrites the
        // live file, and the prune then reads the archive it just created. Over by a full session's worth
        // of records rather than by one, because one record over the cap exercises the branch and not the
        // work (L101).
        let busyLog = dir.appendingPathComponent("busy-\(FreezeLog.fileName)")
        try write(FreezeLog.fileCap + StallLog.cap, to: busyLog)
        let working = seconds { _ = FreezeLog.housekeeping(at: busyLog, now: Date()) }

        // And a SECOND run over the file the first one just compacted, which is what the next hour finds.
        let settled = seconds { _ = FreezeLog.housekeeping(at: busyLog, now: Date()) }

        func ms(_ v: Double) -> String { String(format: "%6.2f", v * 1000) }
        func shareOfFrame(_ v: Double) -> String { String(format: "%5.1f", 100 * v / Self.oneFrameSeconds) }

        print("""
        hourly-maintenance-cost (#3828)
          quiet, a file at its \(FreezeLog.fileCap) cap      \(ms(quiet)) ms   \(shareOfFrame(quiet))% of one 60Hz frame
          working, \(FreezeLog.fileCap + StallLog.cap) records, archives+rewrites  \(ms(working)) ms   \(shareOfFrame(working))% of one frame
          the hour after that, already compacted \(ms(settled)) ms   \(shareOfFrame(settled))% of one frame
          ceiling                                \(ms(Self.ceilingSeconds)) ms   (a hundredth of #3660's 100 ms bar)

          The quiet figure is what the tick pays almost every hour: it reads the whole file and writes
          nothing. The working figure is the hour it compacts, and it is the one worth watching, because
          the file grows and this grows with it.
        """)

        // POSITIVE CONTROL. A run that compacted NOTHING would report a reassuring near-zero for the
        // emptiest possible reason, and the ceiling below would pass over a measurement of nothing (L98).
        let didWork = FreezeLog.read(at: busyLog).records.count
        #expect(didWork <= FreezeLog.fileCap,
                Comment(rawValue: "the working run left \(didWork) records, over the "
                        + "\(FreezeLog.fileCap) cap, so it never compacted and its timing is not a "
                        + "measurement of the work this test exists to price (L98, L102)."))
        #expect(quiet > 0, "the quiet run took no measurable time at all, so it never read the file")

        #expect(working < Self.ceilingSeconds,
                Comment(rawValue: "the compacting run takes \(ms(working)) ms against a ratchet of "
                        + "\(ms(Self.ceilingSeconds)) ms. Past this the work has changed in kind, not "
                        + "merely grown: a per-record file open or a second full parse is what reads "
                        + "like this (#3828)."))
        #expect(quiet < Self.ceilingSeconds,
                Comment(rawValue: "the quiet run takes \(ms(quiet)) ms against a ratchet of "
                        + "\(ms(Self.ceilingSeconds)) ms, and it does no writing at all (#3828)."))
    }

    // WHERE IT RUNS is asserted by `TheFreezeLogIsBoundedWhileTheAppRunsTests.bothCallersShareOneImplementation`,
    // which is #3796's own guard on the two callers reaching one implementation and was re-aimed at the
    // housekeeper by this change. It is not repeated here: one fact, one place (L605).

    // WHAT SERIALISES THE TWO CALLERS, asserted on the TYPE, because the behavioural test below cannot
    // produce the interleaving.
    //
    // This was found rather than assumed. The test below was written first, as the guard, and
    // `scripts/mutate.sh` marking `run` as `nonisolated` (which removes the serialisation entirely) left
    // it GREEN: the first run compacts the file in about 12 ms and the second then finds nothing over the
    // cap, so the window in which both could read the same records almost never opens. A guard that stays
    // green with the thing it guards removed is not a guard (L1), and a race that is merely unlikely is
    // exactly the kind a test cannot be relied on to produce (L159).
    //
    // So the protection is STRUCTURAL and is checked structurally: the housekeeper is an `actor`, and
    // `run` is isolated to it. That is what makes two overlapping runs impossible rather than unlikely.
    @Test func thehousekeeperSerialisesByBeingAnActor() {
        let source = SourceGuardHelper.source("Overture/Integration/FreezeLogHousekeeper.swift")
        #expect(!source.isEmpty, "FreezeLogHousekeeper is gone, so nothing here was measured")
        let isAnActor = source.contains("actor FreezeLogHousekeeper {")
        let runIsIsolated = source.contains("func run(at url: URL, now: Date) -> FreezeLog.Housekeeping {")
            && !source.contains("nonisolated func run(")
        #expect(isAnActor,
                Comment(rawValue: "FreezeLogHousekeeper is no longer an actor, so two overlapping "
                        + "compactions of one file can each archive the same dropped records (#3828)."))
        #expect(runIsIsolated,
                Comment(rawValue: "FreezeLogHousekeeper.run is nonisolated, which is the actor in name "
                        + "only: the work runs concurrently and nothing serialises the launch call "
                        + "against the hourly one (#3828)."))
    }

    // AND THE OUTCOME, over two runs started together. This does NOT prove the serialisation, for the
    // reason written on the guard above; what it proves is that the ordinary two-run sequence leaves one
    // copy of each archived record and a file under its cap, which is the state a launch arriving during
    // an hourly tick has to end in.
    @Test func twoOverlappingRunsArchiveEachRecordOnce() async throws {
        let dir = try sandboxes.make(named: "hourly-maintenance-concurrency")
        let log = dir.appendingPathComponent(FreezeLog.fileName)
        let over = FreezeLog.fileCap + StallLog.cap
        try write(over, to: log)

        let housekeeper = FreezeLogHousekeeper()
        async let first = housekeeper.run(at: log, now: Date())
        async let second = housekeeper.run(at: log, now: Date())
        _ = await (first, second)

        let archive = FreezeLog.read(at: FreezeLog.archiveURL(besideLogAt: log))
        let identities = archive.records.map(\.identity)
        // POSITIVE CONTROL: a run that archived nothing would leave an empty archive, and "no duplicates"
        // is trivially true of nothing (L98, L159).
        #expect(!identities.isEmpty, "nothing was archived at all, so this proves nothing about duplicates")
        #expect(identities.count == Set(identities).count,
                Comment(rawValue: "the archive holds \(identities.count) records and "
                        + "\(Set(identities).count) distinct ones, so two overlapping runs each archived "
                        + "the same dropped records (#3828)."))
        #expect(FreezeLog.read(at: log).records.count <= FreezeLog.fileCap,
                "the live file is still over its cap after two runs")
    }
}
