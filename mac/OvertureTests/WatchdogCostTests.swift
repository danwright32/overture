import Testing
import Foundation

// #3435's L353 remedy, which the phase names as its own defect: this adds permanent recurring work to the
// app whose entire defect is main-thread work, and the plan stated neither a measured cost nor a bound.
//
// Both are here. An estimate is a measurement nobody took, and the quantity this scales with is TIME
// rather than the row count, which makes it the one addition in this milestone that costs something while
// Dan is doing nothing at all (Dan's standing note: an idle surface must pay nothing).
//
// IT WAITS THROUGH `waitUntil` AND NEVER PUMPS A RUN LOOP. The first version of this suite drove
// `RunLoop.current.run(mode:before:)` to drain the main queue, and the run hung: a main-actor test that
// blocks the main thread in a run loop deadlocks against Swift Testing's own scheduling, and a hang is
// worse than a failure because it is indistinguishable from a slow machine while holding the shared
// xcodebuild lock (L110). `waitUntil` SUSPENDS, which returns the main actor to its executor, which is
// the main queue, which is what lets the pings run at all (#3277).
@MainActor
@Suite("What the freeze watchdog costs (#3435)")
struct WatchdogCostTests {

    // Deliberately generous, and far above the measured figure rather than a round number just over it,
    // so anything approaching it is a change in kind rather than noise (L172). A SHARE of one ping
    // interval, never a duration, because a fixed millisecond figure measures what else this Mac is
    // running (L224).
    private static let allowedShareOfOneInterval = 0.01

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    // WHAT ONE PING COSTS THE MAIN THREAD, which is the only cost that matters: the watchdog's own queue
    // is not the thread Dan is waiting on.
    //
    // The work is exactly what a ping asks of it, at the volume a session really asks: an enqueue and a
    // closure that reads a clock. Compared against the INTERVAL, in the same run, so the answer is a share
    // of the time it has to fit into.
    @Test func onePingCostsAlmostNothingOnTheMainThread() async {
        let pings = 400
        let ran = Counter()

        let start = Date()
        for _ in 0..<pings {
            let posted = Date()
            DispatchQueue.main.async {
                _ = Date().timeIntervalSince(posted)
                ran.bump()
            }
        }
        // DRAINED here rather than left in flight, or this would time the enqueue alone and report the
        // half that is free (L102).
        let drained = await waitUntil("every ping to run on the main queue") { ran.value >= pings }
        let elapsed = Date().timeIntervalSince(start)

        let perPing = elapsed / Double(pings)
        let share = perPing / MainThreadWatchdog.pingInterval
        print("""
        watchdog-cost: what one ping costs the main thread (#3435)
          pings drained             \(ran.value) of \(pings)
          per ping                  \(String(format: "%.4f", perPing * 1000)) ms
          share of one interval     \(String(format: "%.4f%%", share * 100))

          Read the SHARE, never the milliseconds (L224). The interval is \(MainThreadWatchdog.pingInterval)s,
          so this is what the watchdog asks of the main thread between one ping and the next. It includes
          the wait's own suspensions, so it is a CEILING on the cost rather than the cost itself.
        """)

        #expect(drained, "not every ping ran, so this timed fewer than it counted")
        #expect(elapsed > 0, "draining \(pings) pings took no measurable time, so nothing was timed")
        #expect(share < Self.allowedShareOfOneInterval,
                Comment(rawValue: "one ping costs \(String(format: "%.3f%%", share * 100)) of the interval "
                        + "it has to fit into. This is permanent recurring work in an app that sits idle "
                        + "most of the day (#3435, L353)."))
    }

    // AND WHAT BOUNDS IT. #3435 requires an assertion that an idle app performs no more than N main-queue
    // pings over a stated interval, proved by mutating the interval.
    //
    // COUNTED THROUGH THE INJECTED CLOCK rather than through a hook inside the watchdog: a counter the
    // code under test increments proves only that the line is there. Every ping reads `now` exactly
    // twice, once where it is posted and once where it runs, so the reading is of what the watchdog
    // really does rather than of something added to help this test.
    @Test func anIdleAppPostsNoMoreThanOnePingPerInterval() async {
        let interval = 0.05
        let expectedPings = 8
        let clockReads = Counter()

        let watchdog = MainThreadWatchdog(session: "cost", interval: interval,
                                          now: { clockReads.bump(); return Date() },
                                          loadReading: { (.baseline, 0) },
                                          record: { _ in })
        watchdog.start()
        // Waits for the pings rather than for a fixed time, so this is not an assertion about how fast
        // the machine is (L290). Two clock reads per completed ping.
        _ = await waitUntil("the watchdog to complete \(expectedPings) pings",
                            timeout: .seconds(20)) { clockReads.value >= expectedPings * 2 }
        watchdog.stop()
        // Anything already in flight is allowed to land, and that wait is on a CONDITION rather than a
        // clock: a second watchdog nobody stops is the control, and waiting for IT to tick is what says
        // enough time has passed for a stopped one to have ticked too (L290).
        let control = Counter()
        let stillRunning = MainThreadWatchdog(session: "control", interval: interval,
                                              now: { control.bump(); return Date() },
                                              loadReading: { (.baseline, 0) },
                                              record: { _ in })
        stillRunning.start()
        _ = await waitUntil("a control watchdog to tick, which is how long a stopped one had to",
                            timeout: .seconds(20)) { control.value >= 4 }
        stillRunning.stop()
        let reads = clockReads.value

        // The CEILING is derived from the interval, with headroom, because a timer fires when the machine
        // lets it and this must not go red on a loaded Mac. What it catches is an interval that has
        // changed or a second timer that has been added.
        let ceiling = (expectedPings * 2) + 12
        #expect(reads >= expectedPings * 2,
                Comment(rawValue: "the watchdog read its clock \(reads) times, fewer than the "
                        + "\(expectedPings * 2) that \(expectedPings) pings need, so it did not run at "
                        + "all and the ceiling below is a bound on nothing (L98)."))
        #expect(reads <= ceiling,
                Comment(rawValue: "the watchdog read its clock \(reads) times against a ceiling of "
                        + "\(ceiling) at a \(interval)s interval. Either the interval has changed or "
                        + "something is posting more than one ping per turn (#3435)."))
    }

    // AND IT STANDS DOWN. The bound above is one ping per interval WHILE IT IS RUNNING; this is the half
    // that makes an idle Overture cost nothing at all, which is Dan's standing rule for an idle surface.
    @Test func aStoppedWatchdogPostsNothingAtAll() async {
        let clockReads = Counter()
        let watchdog = MainThreadWatchdog(session: "idle", interval: 0.02,
                                          now: { clockReads.bump(); return Date() },
                                          loadReading: { (.baseline, 0) },
                                          record: { _ in })
        // A CONTROL watchdog, started with the stopped one and never stopped. Waiting for IT is what
        // turns "long enough for the stopped one to have ticked" into a condition rather than a sleep,
        // and it is strictly stronger: a fixed wait asserts about the machine's speed, while this cannot
        // pass until a running watchdog at the same interval really has ticked many times (L290).
        let controlReads = Counter()
        let control = MainThreadWatchdog(session: "control", interval: 0.02,
                                         now: { controlReads.bump(); return Date() },
                                         loadReading: { (.baseline, 0) },
                                         record: { _ in })
        watchdog.start()
        control.start()
        _ = await waitUntil("the watchdog to ping at least once") { clockReads.value > 0 }
        watchdog.stop()
        let atStop = clockReads.value

        // ONE PING MAY STILL BE IN FLIGHT, and that is correct rather than a leak: `stop` cancels the
        // timer, and a ping already posted still runs its main-queue closure and reads the clock a second
        // time. Measured while writing this, which is how the distinction was found: the first version
        // asserted no read at all after `stop` and went red with exactly one. So the in-flight work is
        // allowed to land, and what is asserted is that NOTHING FURTHER happens after it.
        var controlAt = controlReads.value
        _ = await waitUntil("the control to tick, letting any in-flight ping land",
                            timeout: .seconds(20)) { controlReads.value >= controlAt + 8 }
        let settled = clockReads.value

        controlAt = controlReads.value
        _ = await waitUntil("the control to tick twenty more times, which a running watchdog would have",
                            timeout: .seconds(20)) { controlReads.value >= controlAt + 40 }
        control.stop()

        #expect(atStop > 0, "the watchdog never ran, so stopping it proves nothing")
        #expect(settled - atStop <= 2,
                Comment(rawValue: "\(settled - atStop) clock reads landed after the stop, which is more "
                        + "than the one ping that can be in flight."))
        #expect(controlReads.value >= controlAt + 40,
                "the control never ticked, so nothing here waited long enough to prove an absence")
        #expect(clockReads.value == settled,
                Comment(rawValue: "the watchdog read its clock \(clockReads.value - settled) more times "
                        + "after the in-flight ping had landed, over a window in which a running one "
                        + "ticked twenty times. A watchdog that cannot be stood down costs an idle app "
                        + "for the whole session."))
    }
}
