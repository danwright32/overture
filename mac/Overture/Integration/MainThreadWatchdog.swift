import Foundation

// #3435 Phase 2e: the app measures its own main thread, and writes what it finds without using it.
//
// HOW. A repeating timer on a Dispatch GLOBAL queue posts a sequenced ping to the main queue and records
// how late it runs. If the main thread is wedged, the ping waits, and the delay IS the stall.
//
// A DISPATCH QUEUE AND NEVER THE COOPERATIVE POOL. Swift's cooperative pool is bounded and does not grow,
// so a blocked item there starves every other piece of concurrent work in the process (L241). This one
// blocks by design: it is waiting on the main thread.
//
// THE RECORD IS WRITTEN BY THE WATCHDOG, not by the main thread, or it could not be written during the
// freeze it is recording. Nothing in the write path touches the main actor.
//
// WHAT IT COSTS, measured rather than reasoned about, because this adds permanent recurring work to the
// app whose entire defect is main-thread work (L353, and Dan's standing note that an idle surface must
// pay nothing). One `DispatchQueue.main.async` per interval, which is an enqueue and a closure that reads
// two `Date`s. `WatchdogCostTests` prices it and `anIdleAppPostsNoMoreThanOnePingPerInterval` bounds how
// many there can be.
//
// AND IT STANDS DOWN. `pause()` is called when the app has no window on screen, which for a menu bar app
// is most of the day, so an idle Overture posts nothing at all. That is the bound: the watchdog's total
// contribution is one ping per interval WHILE A WINDOW IS OPEN and zero otherwise.
final class MainThreadWatchdog: @unchecked Sendable {

    // Every 250ms. Fast enough that a stall Dan can perceive is caught by several pings and slow enough
    // that the enqueue cost is nothing. It is also the source of `StallLog.floorSeconds`: a ping late by
    // less than one interval has missed no more than one turn of the run loop.
    static let pingInterval: TimeInterval = 0.25

    // What the MAIN thread stamps and this only ever READS.
    //
    // The surface is a fact only the main thread holds, and this design's whole premise is that nothing on
    // the main thread can participate during a freeze. Asking the main actor for it at write time would
    // make the field unavailable at exactly the moment the record is being written, so the guard falls
    // silent on precisely the input it exists to judge (L345, L11). Instead the main thread commits it
    // whenever the surface changes, and the value present during a freeze is the last one it committed.
    //
    // A LOCK rather than an actor, for the same reason: an actor hop is the thing that cannot happen here.
    final class SurfaceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: StallSurface = .notRecorded
        // Called by the MAIN thread. The only writer.
        func stamp(_ surface: StallSurface) { lock.withLock { value = surface } }
        // Called by the watchdog. The only reader.
        var current: StallSurface { lock.withLock { value } }
    }

    let surface = SurfaceBox()

    private let queue = DispatchQueue(label: "com.danwright.overture.main-thread-watchdog", qos: .utility)
    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private let record: @Sendable (StallRecord) -> Void
    private let loadReading: @Sendable () -> (MachineLoad, Double?)
    private let session: String

    private var timer: DispatchSourceTimer?
    private var sequence = 0
    private var kept = StallLog.Kept(records: [], highWater: nil, evicted: 0, belowFloor: 0)
    private let keptLock = NSLock()

    // Every collaborator is injected, so the suite can drive the whole decision path with no timer, no
    // file and no clock of its own (L196, L284).
    init(session: String = UUID().uuidString,
         interval: TimeInterval = MainThreadWatchdog.pingInterval,
         now: @escaping @Sendable () -> Date = { Date() },
         loadReading: @escaping @Sendable () -> (MachineLoad, Double?) = MachineLoadReading.take,
         record: @escaping @Sendable (StallRecord) -> Void) {
        self.session = session
        self.interval = interval
        self.now = now
        self.loadReading = loadReading
        self.record = record
    }

    var snapshot: StallLog.Kept { keptLock.withLock { kept } }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + self.interval, repeating: self.interval)
            t.setEventHandler { [weak self] in self?.ping() }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.timer?.cancel()
            self?.timer = nil
        }
    }

    // ONE ping. Posted from the watchdog's own queue; the closure runs on the main thread and does nothing
    // but read a clock, so the measurement is the DELAY and not the work.
    private func ping() {
        let posted = now()
        let sequence = nextSequence()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ran = self.now()
            let delay = ran.timeIntervalSince(posted) - self.interval
            // Back on the watchdog's queue to judge and write, because everything after this point must
            // be able to happen while the main thread is wedged.
            self.queue.async { self.recordIfStalled(delay, sequence: sequence, at: ran) }
        }
    }

    private func recordIfStalled(_ delay: TimeInterval, sequence: Int, at: Date) {
        // A ping that ran EARLY or on time is not a stall. Clamped rather than recorded as a negative,
        // which would be a measurement of the timer's own jitter dressed as a freeze.
        guard delay > 0 else { return }
        let reading = loadReading()
        let stall = StallRecord(session: session, sequence: sequence, at: at, seconds: delay,
                                surface: surface.current, load: reading.0, loadAverage: reading.1)
        let shouldWrite = keptLock.withLock { () -> Bool in
            let before = kept.records.count
            kept = StallLog.adding(stall, to: kept)
            return kept.records.count > before
        }
        guard shouldWrite else { return }
        record(stall)
    }

    private func nextSequence() -> Int {
        keptLock.withLock { sequence += 1; return sequence }
    }
}

// #3442: how busy this Mac was, read off the main thread and cheaply enough to take at the moment of a
// stall.
//
// WHY THE LOAD AVERAGE AND NOT THE PROCESS TABLE. `scripts/freeze-measure.sh` reads the process table and
// NAMES what was busy, which is far better evidence, and it is a shell script run around a sample rather
// than something inside the app. #3442's own comment says so: "for the #3435 in-app detector the
// constraint stands and this is not a drop in". `getloadavg` is a single system call of a few
// microseconds, so it can be taken during a stall rather than from a cached verdict that may be a minute
// stale.
//
// WHAT IT GIVES UP, said plainly: it cannot say WHAT was busy. The record carries the number as well as
// the class, so a later reader can re-judge the line without the classification being the only thing kept
// (L316), and `freeze-measure.sh` remains what says by what.
//
// The threshold is DERIVED from the core count rather than set at a round number: one runnable thread per
// core is a machine with nothing spare, and the readings #3442 recorded as genuinely loaded were 13.01 on
// a 12 core Mac.
enum MachineLoadReading {
    static let take: @Sendable () -> (MachineLoad, Double?) = {
        var averages = [Double](repeating: 0, count: 3)
        guard getloadavg(&averages, 3) == 3 else { return (.unmeasured, nil) }
        let oneMinute = averages[0]
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        return (classify(oneMinute, cores: cores), oneMinute)
    }

    // Pure, so the line itself is exercised rather than the system call (L196).
    static func classify(_ oneMinute: Double, cores: Double) -> MachineLoad {
        guard oneMinute.isFinite, oneMinute >= 0 else { return .unmeasured }
        return oneMinute > cores ? .elevated : .baseline
    }
}
