import Testing
import Foundation

// #4153: a stall record says how much of its duration the Mac spent ASLEEP.
//
// WHAT WAS MEASURED. The single longest record in Dan's live log on 2026-09-22 is not a freeze:
//
//   {"at":"2026-09-22T03:07:14Z","seconds":1057.90,"passes":0,"passSeconds":0,"rootDraws":0,
//    "load":"elevated","loadAverage":95.80,"surface":"queue","windows":"open"}
//
// `pmset -g log` puts a sleep of 1074 seconds ending at 23:07:14 local, which is that instant exactly.
// The last real stall before it ended fifteen seconds before the machine slept. The main thread was not
// blocked; it was not scheduled. At 49 times the next longest record, any maximum, percentile or worst
// case taken from that log is set by a period during which the app was not running, and milestone 80's
// bar is judged against exactly that instrument.
//
// THE MECHANISM, and the issue's proposed one is NOT what this uses. #4153 says "`mach_continuous_time`
// advances across sleep and `mach_absolute_time` does not, so the difference between the two across a
// ping is sleep time", and asks for that pairing to be verified on this OS before anything is built on
// it. It was verified, and it is false here. `fixtures/watch-gap-clock-measurement.json` is a reading of
// every clock macOS offers against `kern.boottime`, taken in one process on Dan's own Mac over a 54.19
// hour window containing 71,341 seconds of real sleep: `mach_continuous_time` 195,104.1s against
// `mach_absolute_time` 194,639.5s, a difference of 464.6s. That pairing recovers 0.65% of the sleep that
// happened. #2220 had already been through this and wrote the conclusion into the fixture: "There is no
// awake clock to read on this hardware."
//
// So this reads the sleep that was OBSERVED, through `SystemSleep`, which #2220 built for this exact
// question and which `SleepObserver` already drives from `NSWorkspace`'s sleep and wake notifications.
// Reading the total at the two ends of a ping gives the span that fell inside it.
//
// WHY IT CLOSES AN OPEN SPAN RATHER THAN WAITING TO BE TOLD. `SystemSleep.totalSeconds(now:)` folds in a
// span whose wake notification has not been handled yet, and that is the ordinary case here rather than
// an edge one: the ping that was posted before the Mac slept runs the instant it wakes, racing the
// notification. Nothing about the reading depends on which lands first.
//
// THE RECORD IS MARKED, NEVER DROPPED (L116, and the issue is explicit). An exclusion would also lose a
// real freeze that happened to overlap a sleep, so `seconds` stays exactly as measured and
// `asleepSeconds` says how much of it the machine was not running.
//
// THREE VALUES, the same shape as `passes` and `passSeconds` beside it: `nil` is UNMEASURED (a record
// written before this shipped, which is every one of the thousand in Dan's log that are milestone 80's
// own "before" half), `0` means the Mac did not sleep during this stall, `N` is the span.
@Suite("A stall says how much of it was sleep (#4153)")
struct AStallSaysHowMuchOfItWasSleepTests {

    // MARK: - The arithmetic, as a pure function, so every outcome is produced rather than reasoned about

    @Test func aProcessThatCannotReadTheSleepTotalCannotSayHowMuchItSlept() {
        #expect(StallLog.sleepSpanned(from: nil, to: nil) == nil)
    }

    @Test func aStallWithNoSleepInItSpansZeroRatherThanNothing() {
        #expect(StallLog.sleepSpanned(from: 480, to: 480) == 0)
    }

    @Test func aStallCountsTheSleepBetweenTheTwoReadings() {
        #expect(StallLog.sleepSpanned(from: 480, to: 480 + 1_074) == 1_074)
    }

    // The total only ever grows, so a reading that went BACKWARDS is a fault in the instrument rather
    // than a machine that un-slept, and it is reported as unmeasured rather than as negative sleep (L11).
    @Test func aTotalThatWentBackwardsIsUnmeasuredRatherThanNegative() {
        #expect(StallLog.sleepSpanned(from: 900, to: 100) == nil)
    }

    // A process whose FIRST reading lands inside the stall counts from nothing, on `passesSpanned`'s own
    // precedent: folding this into `nil` would lose the span on exactly the launch-time case.
    @Test func aFirstEverReadingInsideTheStallCountsFromNothing() {
        #expect(StallLog.sleepSpanned(from: nil, to: 1_074) == 1_074)
    }

    // MARK: - The wiring, driven through the real watchdog

    private final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StallRecord] = []
        func add(_ r: StallRecord) { lock.withLock { items.append(r) } }
        var all: [StallRecord] { lock.withLock { items } }
    }

    // The observed sleep total, as a box a test can move, standing in for the one thing a test cannot
    // have: a real Mac going to sleep (L196, and `SleepObserver`'s own docstring says the same of itself).
    private final class SleepTotal: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Double = 0
        var current: Double { lock.withLock { value } }
        func advance(by seconds: Double) { lock.withLock { value += seconds } }
    }

    private static let interval = 0.05
    private static let freeze = 0.6
    private static let sleptDuringTheFreeze = 1_074.0

    @Test func aStallThatSpannedASleepRecordsHowMuchOfItWasSleep() async {
        let records = Records()
        let slept = SleepTotal()
        // A total that is ALREADY non zero before the watchdog starts, so what is under test is a
        // difference rather than a total: a reading that recorded the running total would pass a test
        // that started at zero.
        slept.advance(by: 480)
        let watchdog = MainThreadWatchdog(session: "slept", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          observedSleep: { _ in slept.current },
                                          record: { records.add($0) })
        watchdog.start()

        let freeze = Self.freeze
        let span = Self.sleptDuringTheFreeze
        DispatchQueue.main.async {
            // The main thread unavailable, and the sleep observed while it was. Advanced AFTER the
            // occupation rather than before, so the reading taken when the ping was POSTED is the older
            // one whichever interval the ping landed on.
            Thread.sleep(forTimeInterval: freeze)
            slept.advance(by: span)
        }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()

        let spans = records.all.map(\.asleepSeconds)
        #expect(spans.allSatisfy { $0 != nil }, "a record carried no sleep reading at all")
        #expect(spans.contains { ($0 ?? 0) == span }, Comment(rawValue:
            "no record carried the \(span)s of sleep that fell inside the stall, so a sleeping Mac is "
            + "still recorded as one long freeze with nothing saying so (#4153)"))
        // And never more than was observed, which is what a reading of the running TOTAL rather than the
        // difference would produce: 480s was already on the clock before the watchdog started.
        #expect(spans.allSatisfy { ($0 ?? 0) <= span }, Comment(rawValue:
            "a record claimed more sleep than happened during it, so it is reporting the running total "
            + "rather than the span inside the stall"))
    }

    // THE OTHER HALF, and the one that makes the field readable at all. An ordinary freeze must record
    // `0` rather than nothing, or "the Mac did not sleep" and "nobody was watching" read alike (L98, L11).
    @Test func anOrdinaryFreezeRecordsNoSleepRatherThanNothing() async {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "awake", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          observedSleep: { _ in 480 },
                                          record: { records.add($0) })
        watchdog.start()

        let freeze = Self.freeze
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: freeze) }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()

        #expect(records.all.allSatisfy { $0.asleepSeconds == 0 }, Comment(rawValue:
            "an ordinary freeze on an awake Mac recorded "
            + "\(String(describing: records.all.first?.asleepSeconds)) rather than 0, so a reader "
            + "cannot tell a machine that stayed awake from one nothing was watching"))
    }

    // MARK: - The record carries it across a round trip

    // Dan's log holds a thousand records written before this field existed, and they are milestone 80's
    // own "before" half. A decode that rejected them would destroy the comparison the field exists to
    // enable (L133), so absence has to decode as `nil` rather than throw.
    @Test func aRecordWrittenBeforeThisFieldExistedStillDecodes() throws {
        let line = #"{"session":"old","sequence":1,"at":"2026-09-18T03:07:14Z","seconds":1057.9,"#
            + #""surface":"queue","load":"elevated","passes":0}"#
        let data = try #require(line.data(using: .utf8))
        let record = try FreezeLog.decoder().decode(StallRecord.self, from: data)
        #expect(record.asleepSeconds == nil)
        #expect(record.seconds == 1057.9)
    }

    // MARK: - The wiring, because built is not wired (L3)

    // The behavioural tests above inject the reading, so every one of them would pass over a watchdog
    // whose DEFAULT read nothing at all. What ships is what the app constructs, and `FreezeWatch` builds
    // one with `record:` alone, so the default is the whole of the wiring.
    @Test func theShippedWatchdogTakesItsSleepReadingFromSystemSleep() {
        let source = SourceGuardHelper.source("Overture/Integration/MainThreadWatchdog.swift")
        #expect(!source.isEmpty, "MainThreadWatchdog could not be read, so this guard checked nothing")
        #expect(source.contains("observedSleep: @escaping @Sendable (Date) -> Double "
                                + "= MainThreadWatchdog.observedSleep"), Comment(rawValue:
            "the watchdog's sleep reading is not defaulted to `MainThreadWatchdog.observedSleep`, so the "
            + "shipping app, which constructs one with `record:` alone, records nothing about sleep"))
        #expect(source.contains("SystemSleep.totalSeconds(now: $0)"), Comment(rawValue:
            "`MainThreadWatchdog.observedSleep` does not read `SystemSleep`, which is the only thing on "
            + "this hardware that can see a sleep at all (fixtures/watch-gap-clock-measurement.json)"))
    }

    // And the app really does construct one without overriding it, which is the half a source guard on
    // the default alone cannot see.
    @Test func theAppBuildsItsWatchdogWithoutOverridingTheReading() {
        let source = SourceGuardHelper.source("Overture/App/FreezeWatch.swift")
        #expect(!source.isEmpty, "FreezeWatch could not be read, so this guard checked nothing")
        #expect(source.contains("MainThreadWatchdog(record: {"), Comment(rawValue:
            "FreezeWatch no longer builds the watchdog with `record:` alone, so whether the shipping app "
            + "takes the default sleep reading is no longer something this guard can say"))
    }

    @Test func theSleepSpanSurvivesTheRoundTripThroughTheLog() throws {
        let written = StallRecord(session: "s", sequence: 1, at: Date(timeIntervalSince1970: 1_800_000_000),
                                  seconds: 1_057.9, surface: .queue, load: .elevated, loadAverage: 95.8,
                                  passes: 0, rootDraws: 0, passSeconds: 0, windows: .open,
                                  asleepSeconds: 1_074)
        let line = try #require(FreezeLog.line(for: written))
        let data = try #require(line.data(using: .utf8))
        let read = try FreezeLog.decoder().decode(StallRecord.self, from: data)
        #expect(read.asleepSeconds == 1_074)
    }
}
