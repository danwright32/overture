import Testing
import Foundation

// #4154: a stall record says whether the MAIN THREAD was running while it lasted.
//
// WHAT WAS MEASURED. On 2026-09-22 a render pass that costs about 0.25s cost 9.53s at load 34.7, with
// Overture under 4% CPU, and nothing in the record could say what the time went on. #4154 reproduced it
// against a clone of the live store on 2026-09-25: under CPU contention the same pass took 5.45s median
// against 0.91s quiet, with the main thread's own CPU clock at 23% of the wall time, zero major faults,
// and a 1ms `sample` showing kernel waits as 5% of main thread samples. The thread was neither blocked
// nor computing: it was RUNNABLE AND NOT SCHEDULED. Raising it to user interactive QoS did not help.
//
// That took a hand-run probe, a synthetic load and a sample. The record should say it on its own, for
// every stall, so the next "no sample says why" is answered by the log.
//
// TWO READINGS, because one cannot separate three states:
//
//   mainThreadCPUSeconds   how much CPU the main thread consumed across the stall. Near the stall's
//                          duration is a thread COMPUTING. Far below it is a thread NOT RUNNING, which is
//                          either of the next two.
//   runnable and waiting   what the kernel said the main thread's run state was, sampled at the ping's
//   samples                post and on every skipped ping while it was outstanding (#4114's sampling
//                          point). RUNNABLE while not running is STARVED: other processes had the CPU.
//                          WAITING is BLOCKED: a lock, a read, a semaphore.
//
// THREE VALUES each, the same as every field beside them: `nil` is UNMEASURED (every record written
// before this shipped, or a reading the kernel refused), `0` is a measured zero, `N` is the reading.
@Suite("A stall says whether the main thread was running (#4154)")
struct AStallSaysWhetherTheMainThreadWasRunningTests {

    // MARK: - The arithmetic, pure, so every outcome is produced rather than reasoned about

    @Test func aProcessThatCannotReadTheMainThreadsClockCannotSayWhatItSpent() {
        #expect(StallLog.cpuSpanned(from: nil, to: nil) == nil)
    }

    @Test func aStallInWhichTheMainThreadRanNothingSpansZeroRatherThanNothing() {
        #expect(StallLog.cpuSpanned(from: 12.5, to: 12.5) == 0)
    }

    @Test func aStallCountsTheCPUBetweenTheTwoReadings() {
        #expect(StallLog.cpuSpanned(from: 12.5, to: 13.75) == 1.25)
    }

    // A thread's CPU clock only ever grows, so a reading that went BACKWARDS is a fault in the
    // instrument rather than a thread that un-ran, and it is unmeasured rather than negative (L11).
    @Test func aClockThatWentBackwardsIsUnmeasuredRatherThanNegative() {
        #expect(StallLog.cpuSpanned(from: 13.75, to: 12.5) == nil)
    }

    // A reading at only ONE end cannot be a span: unlike a counter that starts at zero with the process,
    // a CPU clock read at the far end alone would record the thread's whole lifetime as this stall.
    @Test func aReadingAtOnlyOneEndIsUnmeasured() {
        #expect(StallLog.cpuSpanned(from: nil, to: 13.75) == nil)
        #expect(StallLog.cpuSpanned(from: 12.5, to: nil) == nil)
    }

    @Test func theTallyCountsEachRunStateApartAndIgnoresTheOthers() {
        var tally = MainThreadStateTally()
        tally.observe(.runnable)
        tally.observe(.runnable)
        tally.observe(.waiting)
        tally.observe(.other)
        #expect(tally == MainThreadStateTally(runnable: 2, waiting: 1))
    }

    // MARK: - The wiring, driven through the real watchdog with a reading a test controls

    private final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StallRecord] = []
        func add(_ r: StallRecord) { lock.withLock { items.append(r) } }
        var all: [StallRecord] { lock.withLock { items } }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var cpu: Double = 40      // non zero at the start, so a total cannot pass for a span
        private var state: MainThreadRunState = .runnable
        var reading: MainThreadReading { lock.withLock { MainThreadReading(cpuSeconds: cpu, state: state) } }
        func spend(_ seconds: Double) { lock.withLock { cpu += seconds } }
        func become(_ next: MainThreadRunState) { lock.withLock { state = next } }
    }

    private static let interval = 0.05
    private static let freeze = 0.6

    // THE STARVED SHAPE, which is the one #4154 reproduced: runnable the whole time, and almost no CPU.
    @Test func aStarvedStallRecordsLittleCPUAndARunnableThread() async {
        let records = Records()
        let clock = Clock()
        let watchdog = MainThreadWatchdog(session: "starved", interval: Self.interval,
                                          loadReading: { (.elevated, 34.7) },
                                          mainThreadReading: { clock.reading },
                                          record: { records.add($0) })
        watchdog.start()

        let freeze = Self.freeze
        DispatchQueue.main.async {
            Thread.sleep(forTimeInterval: freeze)
            clock.spend(0.02)
        }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()

        let record = records.all.max { $0.seconds < $1.seconds }
        #expect(record?.mainThreadCPUSeconds.map { abs($0 - 0.02) < 1e-9 } == true, Comment(rawValue:
            "the stall recorded \(String(describing: record?.mainThreadCPUSeconds)) seconds of main "
            + "thread CPU rather than the 0.02 spent inside it, so a reader cannot tell a starved "
            + "thread from a computing one (#4154)"))
        #expect((record?.mainThreadRunnableSamples ?? 0) > 1, Comment(rawValue:
            "the stall recorded \(String(describing: record?.mainThreadRunnableSamples)) runnable "
            + "samples; the skipped pings during it were not sampled, so a runnable thread that was not "
            + "scheduled cannot be told from a blocked one"))
        #expect(record?.mainThreadWaitingSamples == 0, Comment(rawValue:
            "a thread runnable throughout recorded \(String(describing: record?.mainThreadWaitingSamples)) "
            + "waiting samples, where 0 was measured"))
    }

    // THE BLOCKED SHAPE: waiting the whole time. Must not read as starved.
    @Test func aBlockedStallRecordsAWaitingThread() async {
        let records = Records()
        let clock = Clock()
        clock.become(.waiting)
        let watchdog = MainThreadWatchdog(session: "blocked", interval: Self.interval,
                                          loadReading: { (.baseline, 2) },
                                          mainThreadReading: { clock.reading },
                                          record: { records.add($0) })
        watchdog.start()

        let freeze = Self.freeze
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: freeze) }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()

        let record = records.all.max { $0.seconds < $1.seconds }
        #expect((record?.mainThreadWaitingSamples ?? 0) > 1)
        #expect(record?.mainThreadRunnableSamples == 0)
        #expect(record?.mainThreadCPUSeconds == 0)
    }

    // A reading the kernel refused is UNMEASURED on every field, never zero (L98).
    @Test func aRefusedReadingIsUnmeasuredRatherThanZero() async {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "refused", interval: Self.interval,
                                          loadReading: { (.baseline, 2) },
                                          mainThreadReading: { nil },
                                          record: { records.add($0) })
        watchdog.start()

        let freeze = Self.freeze
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: freeze) }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()

        #expect(records.all.allSatisfy {
            $0.mainThreadCPUSeconds == nil && $0.mainThreadRunnableSamples == nil
                && $0.mainThreadWaitingSamples == nil
        })
    }

    // MARK: - The SHIPPED reading, against the real kernel, because a scripted clock proves only the wiring

    // A main thread asleep is waiting and spends nothing; a main thread spinning is runnable and spends
    // its time. Compared inside one test rather than against fixed numbers, because a spinning thread on
    // a contended Mac gets less than a core, which is the very thing this field exists to show (L224).
    @Test func theShippedReadingTellsASleepingMainThreadFromASpinningOne() async {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "real", interval: Self.interval,
                                          loadReading: { (.baseline, 2) },
                                          record: { records.add($0) })
        watchdog.start()

        DispatchQueue.main.async { Thread.sleep(forTimeInterval: 0.8) }
        await waitUntil("the sleeping stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        let asleep = records.all.max { $0.seconds < $1.seconds }
        let before = records.all.count

        DispatchQueue.main.async {
            let end = Date().addingTimeInterval(0.8)
            var n = 0
            while Date() < end { n &+= 1 }
            _ = n
        }
        await waitUntil("the spinning stall to be recorded", timeout: .seconds(20)) {
            records.all.count > before
        }
        watchdog.stop()
        let spinning = records.all.dropFirst(before).max { $0.seconds < $1.seconds }

        let sleptCPU = try? #require(asleep?.mainThreadCPUSeconds)
        let spunCPU = try? #require(spinning?.mainThreadCPUSeconds)
        #expect((spunCPU ?? 0) > (sleptCPU ?? 0) + 0.05, Comment(rawValue:
            "a spinning main thread recorded \(String(describing: spunCPU))s of CPU against "
            + "\(String(describing: sleptCPU))s for a sleeping one, so the shipped reading does not "
            + "measure the main thread's own clock"))
        #expect((asleep?.mainThreadWaitingSamples ?? 0) > (asleep?.mainThreadRunnableSamples ?? 0),
                Comment(rawValue: "a sleeping main thread was sampled "
                        + "\(String(describing: asleep?.mainThreadWaitingSamples)) waiting and "
                        + "\(String(describing: asleep?.mainThreadRunnableSamples)) runnable"))
        #expect((spinning?.mainThreadRunnableSamples ?? 0) > (spinning?.mainThreadWaitingSamples ?? 0),
                Comment(rawValue: "a spinning main thread was sampled "
                        + "\(String(describing: spinning?.mainThreadRunnableSamples)) runnable and "
                        + "\(String(describing: spinning?.mainThreadWaitingSamples)) waiting"))
    }

    // MARK: - Built is not wired (L3)

    @Test func theShippedWatchdogReadsTheMainThreadByDefault() {
        let source = SourceGuardHelper.source("Overture/Integration/MainThreadWatchdog.swift")
        #expect(!source.isEmpty, "MainThreadWatchdog could not be read, so this guard checked nothing")
        #expect(source.contains("mainThreadReading: @escaping @Sendable () -> MainThreadReading? "
                                + "= MainThreadWatchdog.mainThreadReading"), Comment(rawValue:
            "the watchdog's main thread reading is not defaulted to `MainThreadWatchdog.mainThreadReading`, "
            + "so the shipping app, which constructs one with `record:` alone, records nothing about it"))
    }

    // MARK: - The record carries it across a round trip, and an old record still decodes

    @Test func aRecordWrittenBeforeThisFieldExistedStillDecodes() throws {
        let line = #"{"session":"old","sequence":1,"at":"2026-09-22T15:24:00Z","seconds":18.64,"#
            + #""surface":"queue","load":"elevated","passes":1,"passSeconds":9.53}"#
        let data = try #require(line.data(using: .utf8))
        let record = try FreezeLog.decoder().decode(StallRecord.self, from: data)
        #expect(record.mainThreadCPUSeconds == nil)
        #expect(record.mainThreadRunnableSamples == nil)
        #expect(record.mainThreadWaitingSamples == nil)
    }

    @Test func theReadingsSurviveTheRoundTripThroughTheLog() throws {
        let written = StallRecord(session: "s", sequence: 1, at: Date(timeIntervalSince1970: 1_800_000_000),
                                  seconds: 18.64, surface: .queue, load: .elevated, loadAverage: 34.7,
                                  passes: 1, rootDraws: 1, passSeconds: 9.53, windows: .open,
                                  asleepSeconds: 0, runLoopActivity: .offTheRunLoop,
                                  mainThreadCPUSeconds: 0.41, mainThreadRunnableSamples: 180,
                                  mainThreadWaitingSamples: 6)
        let line = try #require(FreezeLog.line(for: written))
        let data = try #require(line.data(using: .utf8))
        let read = try FreezeLog.decoder().decode(StallRecord.self, from: data)
        #expect(read.mainThreadCPUSeconds == 0.41)
        #expect(read.mainThreadRunnableSamples == 180)
        #expect(read.mainThreadWaitingSamples == 6)
    }
}
