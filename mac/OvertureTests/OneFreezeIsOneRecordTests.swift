import Testing
import Foundation

// #3635: one freeze must write ONE record.
//
// `MainThreadWatchdog` posts a ping to the main queue on a fixed interval and did not wait for the
// previous one to come back. So during a freeze the pings QUEUE, and when the main thread finally drains
// they all run in the same instant, each recording its own lateness. One freeze wrote a strictly
// decreasing series (D, D - interval, D - 2 * interval, ...) down to the floor, one record each.
//
// Measured on Dan's live Mac 2026-09-07: 611 records for 129 real freezes, 79% of them duplicates, one
// 13.95s freeze wrote 47 of them. The app told him in its own voice that it had stopped responding 611
// times, because `FreezeReport` counts records (L427).
//
// HOW THE FREEZE IS MADE, because it is the one thing here that cannot be a condition. The stimulus IS a
// span of time with the main queue occupied, so it is posted as a block that sleeps. Everything AROUND it
// waits on a condition rather than a clock (L290): the settle wait below is driven by a control watchdog
// ticking, not by a duration.
//
// The test does NOT block the main thread from inside itself. It posts the occupying block and then
// SUSPENDS, which returns the main actor to its executor, which is the main queue, which is what lets the
// block run at all. Blocking here instead deadlocks against Swift Testing's own scheduling, and a hang is
// worse than a failure (L110, and the note at the head of `WatchdogCostTests`).
@MainActor
@Suite("One freeze is one record (#3635)")
struct OneFreezeIsOneRecordTests {

    private final class Records: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [StallRecord] = []
        func add(_ r: StallRecord) { lock.withLock { items.append(r) } }
        var all: [StallRecord] { lock.withLock { items } }
        var count: Int { lock.withLock { items.count } }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }

    // The interval and the freeze are chosen so the two behaviours are far apart rather than adjacent: at
    // this pairing a fan-out writes roughly a dozen records and the correct behaviour writes one, so no
    // amount of machine jitter can move one verdict into the other (L224).
    private static let interval = 0.05
    private static let freeze = 0.8

    @Test func aSingleFreezeWritesASingleRecord() async {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "one-freeze", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          record: { records.add($0) })
        watchdog.start()

        // A CONTROL, started with it and never stopped, so "long enough for a straggler to have landed"
        // is a condition rather than a duration (L290).
        let control = Counter()
        let controlDog = MainThreadWatchdog(session: "control", interval: Self.interval,
                                            now: { control.bump(); return Date() },
                                            loadReading: { (.baseline, 0) },
                                            record: { _ in })
        controlDog.start()
        _ = await waitUntil("both watchdogs to be ticking on an idle main queue") { control.value >= 4 }

        // An idle main queue must have produced NOTHING, or what follows is counting something else.
        let beforeTheFreeze = records.count

        // THE FREEZE. Posted rather than run here, so the main actor is free to suspend below.
        DispatchQueue.main.async { Thread.sleep(forTimeInterval: Self.freeze) }
        let sawTheFreeze = await waitUntil("the freeze to be recorded", timeout: .seconds(30)) {
            records.count > beforeTheFreeze
        }

        // Let every ping that was queued behind the freeze land. Without the fix they arrive together in
        // the drain, so this is the window in which a fan-out becomes visible.
        let settleFrom = control.value
        _ = await waitUntil("the control to tick well past the drain", timeout: .seconds(30)) {
            control.value >= settleFrom + 20
        }
        watchdog.stop()
        controlDog.stop()

        let written = records.all
        let forTheFreeze = written.count - beforeTheFreeze
        print("""
        one-freeze-one-record (#3635)
          interval                  \(Self.interval)s
          freeze                    \(Self.freeze)s  (\(Int(Self.freeze / Self.interval)) intervals)
          records before the freeze \(beforeTheFreeze)
          records for the freeze    \(forTheFreeze)
          durations                 \(written.suffix(forTheFreeze).map { String(format: "%.2f", $0.seconds) })
        """)

        #expect(beforeTheFreeze == 0,
                Comment(rawValue: "an idle main queue wrote \(beforeTheFreeze) records before the freeze, "
                        + "so the count below is not a measurement of the freeze."))
        #expect(sawTheFreeze, "the freeze was never recorded, so nothing here was measured (L98)")
        #expect(forTheFreeze == 1,
                Comment(rawValue: "one freeze wrote \(forTheFreeze) records. A ping posted while another "
                        + "is still outstanding queues behind the freeze and records its own lateness "
                        + "when the drain comes, so the freeze's DURATION becomes its record COUNT and "
                        + "every count taken from the log is inflated (#3635, L427)."))
    }

    // The flag that suppresses the extra pings must CLEAR, or the watchdog records the first freeze of a
    // session and then goes silent for ever, and silence is exactly what a healthy session looks like
    // (L98). So a second freeze has to be recorded too.
    @Test func asecondFreezeIsStillRecordedAfterTheFirst() async {
        let records = Records()
        let watchdog = MainThreadWatchdog(session: "two-freezes", interval: Self.interval,
                                          loadReading: { (.baseline, 0) },
                                          record: { records.add($0) })
        watchdog.start()

        let control = Counter()
        let controlDog = MainThreadWatchdog(session: "control", interval: Self.interval,
                                            now: { control.bump(); return Date() },
                                            loadReading: { (.baseline, 0) },
                                            record: { _ in })
        controlDog.start()
        _ = await waitUntil("both watchdogs to be ticking") { control.value >= 4 }

        DispatchQueue.main.async { Thread.sleep(forTimeInterval: Self.freeze) }
        _ = await waitUntil("the first freeze to be recorded", timeout: .seconds(30)) { records.count >= 1 }
        let afterFirst = records.count

        let settleFrom = control.value
        _ = await waitUntil("the control to tick past the first drain", timeout: .seconds(30)) {
            control.value >= settleFrom + 20
        }

        DispatchQueue.main.async { Thread.sleep(forTimeInterval: Self.freeze) }
        let sawSecond = await waitUntil("the second freeze to be recorded", timeout: .seconds(30)) {
            records.count > afterFirst
        }
        watchdog.stop()
        controlDog.stop()

        #expect(afterFirst >= 1, "the first freeze was never recorded, so this proves nothing about a second")
        #expect(sawSecond,
                Comment(rawValue: "the second freeze wrote nothing. The watchdog recorded one freeze and "
                        + "then went silent, which reads exactly like a session with no freezes at all "
                        + "(#3635, L98)."))
    }
}
