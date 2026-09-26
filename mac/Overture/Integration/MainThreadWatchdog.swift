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
// AND IT STANDS DOWN when the scene goes to the background, which for a menu bar app is most of the day,
// so an idle Overture posts nothing at all. That is the bound: the watchdog's total contribution is one
// ping per interval while the watch is RUNNING and zero otherwise. `RootView` drives it off `scenePhase`,
// and that is NOT the same as "while a window is on screen", which is what this comment claimed until
// #3788 measured it: with zero windows on screen the watch had been running for two hours, because Overture
// is resident in the menu bar so the scene never reaches `.background`. Each record now carries its own
// `windows` reading rather than the file's meaning resting on this premise
// and `TheWatchdogStandsDownTests` holds that something really does.
//
// The first version of this note claimed a `pause()` that did not exist and that nothing called, and the
// watchdog pinged for the life of the process. A constraint recorded only as a comment is enforced by
// nothing, and sitting there it reads as binding (L407).
final class MainThreadWatchdog: @unchecked Sendable {

    // #3752: the interval lives on `StallLog` now and this reads it, rather than each holding the number.
    //
    // It was declared here as 0.25 and copied into `StallLog.floorSeconds` as another 0.25, with a comment
    // in each naming the other. That is one fact in two places, and the day the interval moved the floor
    // would have stayed behind with nothing saying so (L41, L70). The floor is DERIVED from this, so they
    // cannot part.
    static var pingInterval: TimeInterval { StallLog.pingIntervalSeconds }

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

    // #3788: whether a window is open, on SurfaceBox's precedent and for its reason exactly. Asking the main
    // actor would make the answer unavailable at the one moment a record is being written (L345).
    final class WindowBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: WindowPresence = .unknown
        // Called by the MAIN thread. The only writer.
        func stamp(_ presence: WindowPresence) { lock.withLock { value = presence } }
        // Called by the watchdog. The only reader.
        var current: WindowPresence { lock.withLock { value } }
    }

    let windows = WindowBox()

    // #3760: how many render passes the main thread has run, on the SurfaceBox's precedent exactly.
    //
    // The main thread is the only writer and the watchdog the only reader, for the reason above it: a
    // value the watchdog has to ask the main actor for is unavailable at exactly the moment a record is
    // being written (L345). A lock rather than an actor, because an actor hop is the thing that cannot
    // happen here.
    //
    // It starts at NOTHING rather than at zero, and that is what makes "no pass was counted" and
    // "nobody was counting" different answers rather than one (L98, L11). What a counted zero may be
    // read as is narrower than it looks and is set out on `StallRecord.passes` (#3783). See
    // `StallLog.passesSpanned`.
    final class PassCountBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int?
        // Called by the MAIN thread. The only writer.
        func bump() { lock.withLock { value = (value ?? 0) + 1 } }
        // Called by the watchdog. The only reader.
        var current: Int? { lock.withLock { value } }
    }

    let passes = PassCountBox()

    // #3813: how often ROOTVIEW evaluated its own body, counted separately from the surface's passes.
    //
    // A SECOND BOX rather than another writer into the first, and that choice is the whole issue. Under
    // `.queue` two views draw, `RootView` and the `QueueView` inside it, and only the second bumps
    // `passes`. SwiftUI re-evaluates `QueueView` only when a value `RootView` hands it changes, so a
    // `RootView` evaluation that changes none of them rebuilds the window and bumps nothing, and a stall
    // spanning only those reads `passes: 0`.
    //
    // Folding it into `passes` was the other option and is refused: it would redefine the unit that field
    // counts, and milestone #80's before-and-after reading is taken across records already written
    // (measured 2026-09-11: 1,041 records, every one `surface: queue`, 398 of the 536 live ones carrying
    // a count taken from `QueueView` alone). Every new record would become incomparable with every old
    // one, silently (L683). Recorded separately, both numbers stay readable and the reading can say which
    // it is quoting.
    //
    // WHAT IS STILL UNMEASURED, stated rather than implied: how often `RootView` evaluates WITHOUT
    // `QueueView` following. #3813 asked for that population to be measured first, and it cannot be
    // measured without a counter that survives past a DEBUG trace into a real session. This box is that
    // counter. Read the field on a real log before drawing any conclusion from it.
    let rootDraws = PassCountBox()

    // #3815: how long those passes took, as a running total of seconds.
    //
    // A SECOND box rather than a field on the first, because the two are written at different moments: the
    // count is bumped when a pass STARTS so a pass in flight during a freeze is counted, and the cost is
    // added when it RETURNS. One box with two writes would read as one fact taken at one instant.
    //
    // Nothing rather than zero, for `PassCountBox`'s reason: a process where nothing has ever been timed
    // must be distinguishable from one where no pass ran during this stall (L98, L11).
    final class PassCostBox: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Double?
        // Called by the MAIN thread, when a pass returns. The only writer.
        func add(seconds delta: Double) {
            // A negative delta cannot come from a clock that only goes forward, so it is refused rather
            // than subtracted: accepting one would let the total go backwards, which the span rule then
            // correctly reports as unmeasured, turning one bad reading into a silent hole (L11).
            guard delta >= 0 else { return }
            lock.withLock { self.seconds = (self.seconds ?? 0) + delta }
        }
        // Called by the watchdog. The only reader.
        var current: Double? { lock.withLock { seconds } }
    }

    let passCost = PassCostBox()

    // #4114: what the main run loop was doing while the outstanding ping waited, folded across every
    // sample taken during it.
    //
    // WRITTEN AND READ BY THE WATCHDOG'S OWN QUEUE, unlike every box above it. Those four are stamped by
    // the main thread because only the main thread holds what they record. This one records a fact about
    // the main thread that is readable WITHOUT it, which is the whole reason it can be sampled during a
    // freeze at all (L345). A lock all the same, because the sampling and the reset happen on the
    // watchdog queue while the reader runs there too and a future change should not have to rediscover
    // why that was safe.
    final class ActivityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: RunLoopActivity = .notRecorded
        // Cleared when a ping is POSTED, so what a record carries is the samples taken during ITS stall
        // and never the ones before it.
        func reset() { lock.withLock { value = .notRecorded } }
        func observe(_ activity: RunLoopActivity) {
            lock.withLock { value = RunLoopActivity.moreTelling(value, activity) }
        }
        var current: RunLoopActivity { lock.withLock { value } }
    }

    let runLoopActivity = ActivityBox()

    // #4154: the main thread's run state samples across one stall, the sibling of `ActivityBox` above and
    // reset and sampled at exactly the same points. `nil` until a reading succeeds, so a stall during
    // which the kernel refused every reading records UNMEASURED rather than zero samples (L98).
    final class ThreadStateBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: MainThreadStateTally?
        func reset() { lock.withLock { value = nil } }
        func observe(_ reading: MainThreadReading?) {
            guard let reading else { return }
            lock.withLock {
                var next = value ?? MainThreadStateTally()
                next.observe(reading.state)
                value = next
            }
        }
        var current: MainThreadStateTally? { lock.withLock { value } }
    }

    let mainThreadStates = ThreadStateBox()

    private let queue = DispatchQueue(label: "com.danwright.overture.main-thread-watchdog", qos: .utility)
    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private let record: @Sendable (StallRecord) -> Void
    private let loadReading: @Sendable () -> (MachineLoad, Double?)
    private let session: String
    private let cap: Int
    // #4153: read at both ends of a ping, so a stall says how much of itself the machine was not running.
    private let observedSleep: @Sendable (Date) -> Double
    // #4114: the MAIN run loop's current mode, readable from this queue while the main thread is wedged.
    private let mainRunLoopMode: @Sendable () -> String?
    // #4154: the main thread's CPU clock and run state, readable from this queue while it is wedged.
    private let mainThreadReading: @Sendable () -> MainThreadReading?

    private var timer: DispatchSourceTimer?
    private var sequence = 0
    // #3635: whether a ping is still waiting on the main thread. Guarded by `keptLock`, which already
    // serialises everything else this class mutates.
    private var pingOutstanding = false
    private var kept = StallLog.Kept(records: [], highWater: nil, evicted: 0, belowFloor: 0)
    private let keptLock = NSLock()

    // Every collaborator is injected, so the suite can drive the whole decision path with no timer, no
    // file and no clock of its own (L196, L284).
    //
    // #3812: the CAP is injected for the same reason. The retention rule only does anything once the kept
    // set is FULL, so at the shipped cap of 200 a test would have to drive 201 real freezes to reach the
    // branch, which is the shape that leaves the branch that ships the one never exercised (L101). With
    // the cap injectable a test reaches it in two.
    init(session: String = UUID().uuidString,
         interval: TimeInterval = MainThreadWatchdog.pingInterval,
         now: @escaping @Sendable () -> Date = { Date() },
         loadReading: @escaping @Sendable () -> (MachineLoad, Double?) = MachineLoadReading.take,
         observedSleep: @escaping @Sendable (Date) -> Double = MainThreadWatchdog.observedSleep,
         mainRunLoopMode: @escaping @Sendable () -> String? = MainThreadWatchdog.mainRunLoopMode,
         mainThreadReading: @escaping @Sendable () -> MainThreadReading? = MainThreadWatchdog.mainThreadReading,
         cap: Int = StallLog.cap,
         record: @escaping @Sendable (StallRecord) -> Void) {
        self.session = session
        self.interval = interval
        self.now = now
        self.loadReading = loadReading
        self.observedSleep = observedSleep
        self.mainRunLoopMode = mainRunLoopMode
        self.mainThreadReading = mainThreadReading
        self.cap = cap
        self.record = record
    }

    // #4153: how much sleep this Mac has been SEEN to have, in total, as of an instant.
    //
    // Named and shipped as a value rather than written inline as the default, so the wiring is one symbol
    // a test can point at and a guard can name, and so the two ends of a ping cannot end up reading two
    // different things.
    //
    // `SystemSleep` rather than a clock, and that is a measurement rather than a preference. #2220 read
    // every clock macOS offers against `kern.boottime` in one process on Dan's Mac, over a 54.19 hour
    // window holding 71,341 seconds of real sleep, and recorded the result in
    // `fixtures/watch-gap-clock-measurement.json`: `mach_continuous_time` and `mach_absolute_time` differ
    // by 464.6s over that window, which is 0.65% of the sleep that happened. There is no awake clock to
    // read on this hardware, so the sleep is OBSERVED, through the `NSWorkspace` notifications
    // `SleepObserver` turns into this total.
    //
    // It takes the instant so that a span still open at the moment of reading is closed into the answer.
    // That is the ordinary case rather than an edge one: the ping posted before the Mac slept runs the
    // instant it wakes, racing the wake notification, and this makes the reading independent of which of
    // the two lands first.
    static let observedSleep: @Sendable (Date) -> Double = { SystemSleep.totalSeconds(now: $0) }

    // #4114: what mode the MAIN run loop is running, right now, asked from whatever thread is asking.
    //
    // Named and shipped as a value rather than written inline as the default, on `observedSleep`'s
    // precedent, so the wiring is one symbol a test can point at and a guard can name.
    //
    // CFRunLoop is one of the few thread-safe CoreFoundation types, so this is a legal question to ask
    // about another thread's run loop, and it is the only reading in this file that does not need the
    // main thread's cooperation. Verified before it was built on rather than taken from the
    // documentation: a background thread polling the main run loop sees a nested mode while the main
    // thread is inside it, and sees NOTHING at all when the main thread has left the run loop entirely
    // (L82, L177).
    //
    // `nil` is a reading, not a failure: it means the run loop is running no mode. `RunLoopActivity`
    // gives that its own case rather than folding it into the absent one.
    static let mainRunLoopMode: @Sendable () -> String? = {
        CFRunLoopCopyCurrentMode(CFRunLoopGetMain())?.rawValue as String?
    }

    // #4154: the MAIN thread's own CPU clock and kernel run state, asked from whatever thread is asking.
    //
    // Named and shipped as a value rather than written inline as the default, on `observedSleep`'s
    // precedent, so the wiring is one symbol a test can point at and a guard can name.
    //
    // `thread_info` on another thread's port is a legal question from any thread, which is what lets it be
    // asked while the main thread is wedged. The port is looked up per call rather than cached: it is a
    // name lookup of a few microseconds, and a cached port would be one more piece of state to get wrong.
    // `nil` when the kernel refuses, which the record carries as unmeasured rather than as zero.
    static let mainThreadReading: @Sendable () -> MainThreadReading? = {
        let port = pthread_mach_thread_np(overtureMainPthread())
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let cpu = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1_000_000
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1_000_000
        let state: MainThreadRunState
        switch info.run_state {
        case TH_STATE_RUNNING: state = .runnable
        case TH_STATE_WAITING, TH_STATE_UNINTERRUPTIBLE: state = .waiting
        default: state = .other
        }
        return MainThreadReading(cpuSeconds: cpu, state: state)
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
    //
    // AND ONLY ONE IN FLIGHT AT A TIME (#3635). This used to post on every interval whatever was already
    // outstanding, so during a freeze the pings QUEUED, and when the main thread finally drained they all
    // ran in the same instant and each recorded its own lateness. One freeze wrote a strictly decreasing
    // series, one record per interval it lasted, so the freeze's DURATION became its record COUNT and
    // every count taken from the log was inflated (L427). Measured on Dan's live Mac 2026-09-07: 611
    // records for 129 real freezes, and the app told him in its own voice that it had stopped responding
    // 611 times.
    //
    // Skipping is also what keeps the DRAIN cheap. A 40 second freeze used to leave 160 closures sitting
    // on the main queue, every one of which ran at the exact moment the app was trying to catch up, which
    // is work added to the worst moment there is by the thing measuring it.
    //
    // What is given up, said plainly: the skipped pings are not counted anywhere. The freeze's own
    // duration is what this exists to record and the longest queued ping was always the only record
    // carrying it, so nothing measured is lost; what is gone is a second, redundant estimate of the same
    // quantity.
    private func ping() {
        let claimed = keptLock.withLock { () -> Bool in
            guard !pingOutstanding else { return false }
            pingOutstanding = true
            return true
        }
        // #4114: THE SKIPPED PING IS THE SAMPLING POINT, and that is the whole of why this costs nothing.
        // A skip happens precisely while a ping is still waiting on the main thread, so this timer tick
        // is the one moment in this design that is awake during a freeze with nothing else to do. Reading
        // the mode only at the ping's two ends would miss a menu that went up and came down inside the
        // stall, which is exactly the 2026-09-21 case: the dropdown was open in the MIDDLE of a 1.62s
        // record. At the shipped 0.1s interval a 1.6s stall gives about sixteen samples.
        guard claimed else {
            runLoopActivity.observe(RunLoopActivity(modeName: mainRunLoopMode()))
            // #4154: the same sampling point, for the same reason: this is the moment that is awake
            // during a freeze with nothing else to do.
            mainThreadStates.observe(mainThreadReading())
            return
        }

        // Cleared FIRST, so what this record carries is the samples taken during its own stall and never
        // the ones left by the stall before it. Then sampled at once, so a stall short enough to hold no
        // skipped ping still carries a reading rather than nothing.
        runLoopActivity.reset()
        runLoopActivity.observe(RunLoopActivity(modeName: mainRunLoopMode()))
        // #4154: reset and sampled with the run loop above. The post reading also supplies the CPU clock
        // at this end, so the two come from ONE call and cannot describe different instants.
        mainThreadStates.reset()
        let threadAtPost = mainThreadReading()
        mainThreadStates.observe(threadAtPost)

        let posted = now()
        // #3760: read BEFORE the ping is posted, and again below when it finally runs, which is the
        // instant the main thread became free again. Reading the second one on the watchdog's queue
        // afterwards would also work and would be less exact: it could include a pass that happened
        // after the freeze had already ended.
        let passesAtPost = passes.current
        let rootAtPost = rootDraws.current
        let costAtPost = passCost.current
        // #4153: the sleep total at each end, for the same reason the three counters above are read at
        // each end. Taken here on the watchdog's own queue, which is the half that has to keep working
        // while the main thread is wedged.
        let sleptAtPost = observedSleep(posted)
        let sequence = nextSequence()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let ran = self.now()
            let passesAtRun = self.passes.current
            let rootAtRun = self.rootDraws.current
            let costAtRun = self.passCost.current
            // Read at the instant the main thread became free again, which for a stall that spanned a
            // sleep is the instant of the wake. `SystemSleep.totalSeconds` closes a span whose wake
            // notification has not been handled yet, so this does not depend on that notification having
            // landed first.
            let sleptAtRun = self.observedSleep(ran)
            // #4154: the CPU clock at the instant the main thread became free, taken on it.
            let cpuAtRun = self.mainThreadReading()?.cpuSeconds
            let delay = ran.timeIntervalSince(posted) - self.interval
            // Back on the watchdog's queue to judge and write, because everything after this point must
            // be able to happen while the main thread is wedged.
            self.queue.async {
                // RELEASED FIRST, and on every path. `recordIfStalled` returns early for a ping that was
                // not late, and a release that sat after that guard would leave the flag set for the rest
                // of the session on the very first on-time ping. The watchdog would then record one thing
                // and go quiet, and silence is exactly what a healthy session looks like (L98).
                self.keptLock.withLock { self.pingOutstanding = false }
                self.recordIfStalled(delay, sequence: sequence, at: ran,
                                     passes: StallLog.passesSpanned(from: passesAtPost, to: passesAtRun),
                                     rootDraws: StallLog.passesSpanned(from: rootAtPost, to: rootAtRun),
                                     passSeconds: StallLog.passSecondsSpanned(from: costAtPost,
                                                                             to: costAtRun),
                                     asleep: StallLog.sleepSpanned(from: sleptAtPost, to: sleptAtRun),
                                     // #4114: read AFTER the ping has run, so every sample taken while
                                     // it was outstanding is folded in. Read on this queue, which is
                                     // where they were written.
                                     runLoop: self.runLoopActivity.current,
                                     mainThreadCPU: StallLog.cpuSpanned(from: threadAtPost?.cpuSeconds,
                                                                       to: cpuAtRun),
                                     mainThreadStates: self.mainThreadStates.current)
            }
        }
    }

    private func recordIfStalled(_ delay: TimeInterval, sequence: Int, at: Date, passes: Int?,
                                 rootDraws: Int?, passSeconds: Double?, asleep: Double?,
                                 runLoop: RunLoopActivity, mainThreadCPU: Double?,
                                 mainThreadStates: MainThreadStateTally?) {
        // A ping that ran EARLY or on time is not a stall. Clamped rather than recorded as a negative,
        // which would be a measurement of the timer's own jitter dressed as a freeze.
        guard delay > 0 else { return }
        let reading = loadReading()
        let stall = StallRecord(session: session, sequence: sequence, at: at, seconds: delay,
                                surface: surface.current, load: reading.0, loadAverage: reading.1,
                                passes: passes,
                                rootDraws: rootDraws,
                                passSeconds: passSeconds,
                                // #3788: read from the box the main thread stamped, never asked of AppKit
                                // here. This runs on the watchdog's own queue during a freeze, and a value
                                // the main actor has to supply is unavailable at exactly the moment a record
                                // is being written (L345).
                                windows: windows.current,
                                // #4153: how much of `delay` above the machine was asleep for. Recorded
                                // beside the duration and never subtracted from it, so a real freeze that
                                // overlapped a sleep is still a record of a freeze (L116).
                                asleepSeconds: asleep,
                                // #4114: what the main run loop was doing while this stall lasted,
                                // folded from every sample taken across it. Recorded beside the duration
                                // and never subtracted from it, for the reason above: a freeze that
                                // happened to overlap a menu is still a freeze (L116).
                                runLoopActivity: runLoop,
                                // #4154: whether the main thread was running, starved or blocked while
                                // this stall lasted. Recorded beside `passSeconds`, never divided into it.
                                mainThreadCPUSeconds: mainThreadCPU,
                                mainThreadRunnableSamples: mainThreadStates?.runnable,
                                mainThreadWaitingSamples: mainThreadStates?.waiting)
        // #3812: the decision is the PURE rule's, taken whole. This used to compare the kept set's count
        // before and after, which tied "what is held in memory" to "what is written to the file" and made
        // the session stop recording at its 200th stall.
        let admission = keptLock.withLock { () -> StallLog.Admission in
            let result = StallLog.adding(stall, to: kept, cap: cap)
            kept = result.kept
            return result
        }
        guard admission.write else { return }
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

// #4154: libsystem_pthread's `pthread_main_thread_np`, which the Darwin module does not import into Swift.
// It is exported and stable, and it answers from ANY thread, which is the property the watchdog needs: the
// reading is taken while the main thread is wedged, so it cannot be asked for its own identity.
@_silgen_name("pthread_main_thread_np")
private func overtureMainPthread() -> pthread_t
