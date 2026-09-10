import Testing
import Foundation

// #3760: a stall record says how many render passes it spanned.
//
// WHY THIS EXISTS. On 2026-09-10, on a build carrying every fix in milestone 80, the queue froze for
// 16.73s at baseline load on a quiet Mac. One store change costs 350.7 ms end to end, measured the same
// day, so that freeze is forty-eight of them or it is something else entirely, and those two call for
// opposite work. A stall record held a duration, an instant, a surface and a load reading, and nothing in
// it could choose between them.
//
// THE THREE VALUES ARE THE POINT, and only one of them is a number anybody expected to see. `nil` is
// UNMEASURED and is never folded into `0`: a zero standing for both "the surface did not rebuild" and
// "nobody was counting" makes the finding that REFUTES the burst reading indistinguishable from the
// instrument being absent (L98, L11).
//
// The counter is read on the MAIN thread at the moment the ping finally runs, which is the instant the
// main thread became free again, rather than on the watchdog's queue afterwards. Both are correct; this
// one cannot include a pass that happened after the freeze ended.
@Suite("A stall says how many passes it spans (#3760)")
struct AStallSaysHowManyPassesItSpansTests {

    // The arithmetic, as a pure function, so all three outcomes can be produced rather than reasoned
    // about (L151). Every one of them is reachable in the running app: nothing has ever bumped, the first
    // bump lands inside the stall, and the ordinary case.

    @Test func aProcessThatHasNeverCountedAPassCannotSayHowManyItSpanned() {
        #expect(StallLog.passesSpanned(from: nil, to: nil) == nil)
    }

    @Test func aStallWithNoPassInItSpansZeroRatherThanNothing() {
        #expect(StallLog.passesSpanned(from: 7, to: 7) == 0)
    }

    @Test func aStallCountsThePassesBetweenTheTwoReadings() {
        #expect(StallLog.passesSpanned(from: 7, to: 55) == 48)
    }

    // The first pass of the process landing INSIDE the stall. Counted from nothing, so all of them
    // belong to it. Folding this into `nil` would lose the count on precisely the freeze a cold launch
    // produces, which is the one Dan sees first.
    @Test func aFirstEverPassInsideTheStallCountsFromNothing() {
        #expect(StallLog.passesSpanned(from: nil, to: 3) == 3)
    }

    // A counter cannot go backwards: it has one writer and only ever increases. A reading that says it
    // did is a fault in the instrument, not a stall that un-rendered itself, and it must not be reported
    // as a negative number of passes (L11).
    @Test func aCounterThatWentBackwardsIsUnmeasuredRatherThanNegative() {
        #expect(StallLog.passesSpanned(from: 9, to: 4) == nil)
    }

    // The box itself: one writer (the main thread), one reader (the watchdog), and it starts at nothing
    // rather than at zero, which is what makes the three values above reachable at all.
    @Test func theCounterStartsAtNothingAndCountsFromThere() {
        let box = MainThreadWatchdog.PassCountBox()
        #expect(box.current == nil)
        box.bump()
        #expect(box.current == 1)
        box.bump()
        #expect(box.current == 2)
    }

    // A record written before this shipped carries no `passes` field at all. The live log holds hundreds
    // of them and they are the "before" half of this milestone's own reading, so they must go on decoding
    // rather than being lost the day the field is added.
    @Test func aRecordWrittenBeforeThisShippedStillDecodes() throws {
        let json = """
        {"session":"old","sequence":12,"at":768000000,"seconds":16.73,"surface":"queue",\
        "load":"baseline","loadAverage":3.7}
        """
        let record = try JSONDecoder().decode(StallRecord.self, from: Data(json.utf8))
        #expect(record.passes == nil)
        #expect(record.seconds == 16.73)
    }
}

// The wiring, driven through a REAL freeze rather than by calling the recorder directly, because what is
// under test is that the count is taken at the two moments the watchdog actually has, not that the
// arithmetic above works (it is proved on its own, up there).
//
// HOW THE FREEZE IS MADE follows `OneFreezeIsOneRecordTests` exactly: the stimulus IS a span of time with
// the main queue occupied, so it is posted as a block that sleeps, and this test never blocks the main
// thread from inside itself. Everything around it waits on a condition rather than a clock (L290).
@MainActor
@Suite("The watchdog counts the passes a freeze spans (#3760)")
struct TheWatchdogCountsPassesTests {

    private final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StallRecord] = []
        func add(_ r: StallRecord) { lock.withLock { items.append(r) } }
        var all: [StallRecord] { lock.withLock { items } }
    }

    private static let interval = 0.05
    private static let freeze = 0.6
    private static let passesDuringTheFreeze = 4

    @Test func aFreezeWithPassesInItRecordsHowManyItSpanned() async {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "passes", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          record: { records.add($0) })
        // One pass BEFORE the watchdog starts, so the count under test is a difference rather than a
        // total: a reading that returned the whole-process total would pass a test that started at zero.
        watchdog.passes.bump()
        watchdog.start()

        let passes = watchdog.passes
        let freeze = Self.freeze
        let during = Self.passesDuringTheFreeze
        DispatchQueue.main.async {
            // The main thread occupied, bumping as it goes, which is what a burst of store changes does.
            for _ in 0..<during {
                Thread.sleep(forTimeInterval: freeze / Double(during))
                passes.bump()
            }
        }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()

        let stall = records.all.max { $0.seconds < $1.seconds }
        #expect(stall != nil)
        // At least the passes bumped inside it. Never the total, which would be one more.
        #expect(stall?.passes != nil)
        #expect((stall?.passes ?? 0) >= 1)
        #expect((stall?.passes ?? 99) <= during)
    }

    @Test func aFreezeInAProcessThatNeverCountedAPassRecordsNothingRatherThanZero() async {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "no-passes", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          record: { records.add($0) })
        watchdog.start()

        let freeze = Self.freeze
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: freeze) }

        await waitUntil("a stall to be recorded", timeout: .seconds(20)) { !records.all.isEmpty }
        watchdog.stop()

        #expect(records.all.allSatisfy { $0.passes == nil })
    }
}
