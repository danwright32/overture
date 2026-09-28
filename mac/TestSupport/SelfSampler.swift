import Foundation
import Darwin
import Testing

// Moved here from ScoutLandingAttributionProbeTests (#4275) so the hosted view attribution probe (#4106)
// samples its own process through the same sampler rather than a copy of it (L613). It names no app type,
// which is what lets it live in TestSupport and compile into both test targets.

/// #4307: whether `/usr/bin/sample` has really begun SAMPLING, judged from the sampler's own counters.
///
/// Its "Sampling process" line only says it has attached: #4106 measured readings timed from that line going
/// wholly unsampled, and on a large process the symbol grab `-mayDie` asks for runs between the two. Each
/// sample suspends the target, walks every thread's stack and resumes it, then waits for the next, which reads
/// on the sampler's counters as one context switch per sample and a burst of Mach calls around it, with few
/// Unix calls. The attach and symbol phase does the opposite (Unix calls to read images, or nothing at all).
/// Counters, rather than the target timing its own pauses, because counts do not move with the Mac's load:
/// measured 2026-09-28 at a load average near 100, a watcher in the target saw as many short pauses before
/// sampling began as during it.
enum SamplingStart {
    /// One reading of a process's cumulative counters. `at` is nanoseconds on `CLOCK_UPTIME_RAW`.
    struct Reading: Equatable, Sendable {
        let at: UInt64
        let machCalls: UInt64
        let unixCalls: UInt64
        let switches: UInt64
    }

    /// How many intervals in a row must look like sampling. One burst could be anything; two is the rhythm.
    static let consecutive = 2

    /// Whether the interval from `a` to `b` has the per sample rhythm: at least three samples' worth of
    /// context switches, at least five Mach calls per switch (a small process measured 11, one with 60 extra
    /// threads 70), and Unix calls at most a fifth of the Mach calls (the symbol phase measured 44% and
    /// above). A counter or the clock going backwards (a reused pid, a bad read, readings out of order) is never
    /// sampling.
    static func looksLikeSampling(from a: Reading, to b: Reading) -> Bool {
        guard b.at > a.at, b.machCalls >= a.machCalls, b.unixCalls >= a.unixCalls, b.switches >= a.switches else {
            return false
        }
        let mach = b.machCalls - a.machCalls
        let unix = b.unixCalls - a.unixCalls
        let switches = b.switches - a.switches
        return switches >= 3 && mach >= 5 * switches && mach >= 5 * unix
    }

    /// The `at` of the reading that opens the first run of `consecutive` sampling intervals, which is the
    /// earliest sampling can be said to have begun, or nil when no such run has been seen yet.
    static func began(_ readings: [Reading]) -> UInt64? {
        guard readings.count > consecutive else { return nil }
        for i in 0..<(readings.count - consecutive) {
            let run = (i..<(i + consecutive)).allSatisfy { looksLikeSampling(from: readings[$0], to: readings[$0 + 1]) }
            if run { return readings[i].at }
        }
        return nil
    }

    /// The live reading of `pid`'s counters, or nil when the process cannot be read (it has exited).
    static func read(pid: Int32) -> Reading? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return Reading(at: clock_gettime_nsec_np(CLOCK_UPTIME_RAW),
                       machCalls: UInt64(max(0, info.pti_syscalls_mach)),
                       unixCalls: UInt64(max(0, info.pti_syscalls_unix)),
                       switches: UInt64(max(0, info.pti_csw)))
    }
}

/// `/usr/bin/sample` pointed at THIS process. `start` returns only once the sampler is really SAMPLING (#4307),
/// not merely attached: it waits for the "Sampling process" line and then for `SamplingStart` to see the per
/// sample rhythm on the sampler's own counters, both bounded, so measured work never begins before the
/// samples do. Every caller gets that by calling `start`; there is no way to begin on the attach line alone.
final class LandingSelfSampler: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var attached = false
    private var said = ""
    private var attachedAtNs: UInt64?
    private let executable: URL
    private let counters: (Int32) -> SamplingStart.Reading?
    private let readingEvery: Duration
    private let beginTimeout: Duration
    private let attachTimeout: Duration
    let file: URL
    let seconds: Int
    /// When sampling began (`CLOCK_UPTIME_RAW` nanoseconds, the reading that opened the first sampling
    /// interval), once `start` has returned; nil before, or when it never began.
    private(set) var beganAt: UInt64?
    /// How many counter readings `start` took before it could say sampling had begun.
    private(set) var readingsTaken = 0

    /// `executable`, `counters`, `readingEvery` and `beginTimeout` are seams for the wiring test; the defaults
    /// are the real sampler, its real counters, a reading every 50 ms (a few samples per interval even at a
    /// slow cadence) and a minute for a large process's symbol grab.
    init(seconds: Int, file: URL, executable: URL = URL(fileURLWithPath: "/usr/bin/sample"),
         counters: @escaping (Int32) -> SamplingStart.Reading? = SamplingStart.read,
         readingEvery: Duration = .milliseconds(50), beginTimeout: Duration = .seconds(60),
         attachTimeout: Duration = .seconds(15)) {
        self.seconds = seconds
        self.file = file
        self.executable = executable
        self.counters = counters
        self.readingEvery = readingEvery
        self.beginTimeout = beginTimeout
        self.attachTimeout = attachTimeout
    }

    /// Milliseconds from the attach line to the first sampling interval: the head a caller starting on the
    /// attach line would have left unsampled (a lower bound, since sampling began somewhere in that interval).
    var attachToBeganMs: Double? {
        lock.lock(); defer { lock.unlock() }
        guard let a = attachedAtNs, let b = beganAt else { return nil }
        return b >= a ? Double(b - a) / 1e6 : 0
    }

    /// Every refusal ends the sampler before it is thrown (the #4318 review): callers catch a failed start and
    /// carry on, so a sampler left running would outlive the test holding its pipe, still suspending this
    /// process, and write a file nobody reads (L235, L114).
    @MainActor
    func start() async throws {
        do {
            try await attachAndWaitForSampling()
        } catch {
            await stop()
            throw error
        }
    }

    @MainActor
    private func attachAndWaitForSampling() async throws {
        process.executableURL = executable
        process.arguments = [String(getpid()), String(seconds), "1", "-mayDie", "-file", file.path]
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard let self else { return }
            self.lock.lock()
            self.said += text
            if !self.attached && self.said.contains("Sampling process") {
                self.attached = true
                self.attachedAtNs = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
            }
            self.lock.unlock()
        }
        try process.run()
        let deadline = ContinuousClock.now + attachTimeout
        while ContinuousClock.now < deadline {
            if isAttached { break }
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard isAttached else { throw SamplerError.notAttached(output) }
        try await waitForSampling()
    }

    // Attached is not sampling (#4307): read the sampler's counters until two intervals in a row have the per
    // sample rhythm, bounded by `beginTimeout` through `waitUntil`, and refuse if the sampler exits first.
    @MainActor
    private func waitForSampling() async throws {
        let pid = process.processIdentifier
        var readings: [SamplingStart.Reading] = []
        var lastRead: ContinuousClock.Instant?
        _ = await waitUntil("the sampler to begin sampling (not only attach)", timeout: beginTimeout) {
            if !process.isRunning { return true }
            let now = ContinuousClock.now
            if lastRead.map({ now - $0 >= readingEvery }) ?? true {
                lastRead = now
                if let r = counters(pid) { readings.append(r) }
            }
            return SamplingStart.began(readings) != nil
        }
        readingsTaken = readings.count
        guard let at = SamplingStart.began(readings) else {
            throw SamplerError.neverBegan("\(readings.count) counter readings, none with the sampling rhythm; "
                                          + "sampler said: \(output.suffix(200))")
        }
        record(beganAt: at)
    }

    private func record(beganAt at: UInt64) { lock.lock(); beganAt = at; lock.unlock() }

    private var isAttached: Bool { lock.lock(); defer { lock.unlock() }; return attached }

    /// Whether the sampling WINDOW is over: `sample` has said "Sampling completed", or has exited. Readable
    /// synchronously, so a caller doing work on the main thread can keep working until then. #4106 measured
    /// why it must: the "Sampling process" line can arrive well before the first sample is taken, so work
    /// timed from that line to the sampler's nominal duration finished before sampling began, and every
    /// sample in the file was the main thread idle afterwards.
    var samplingFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return said.contains("Sampling completed") || !process.isRunning
    }
    var output: String { lock.lock(); defer { lock.unlock() }; return said }

    /// Waits for the sampler to finish its window and write its file, bounded by its own duration plus 60 s.
    func finish() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds + 60)
        while process.isRunning && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if process.isRunning { await stop(); return false }
        pipe.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: file.path)
    }

    /// Ends the sampler: terminates it if it is still running, waits for it to exit (5 s, then a kill and one
    /// more second), and clears the pipe's handler. Returns whether it is gone. Safe on a sampler that never
    /// launched, since only a running process is signalled.
    @discardableResult
    func stop() async -> Bool {
        if process.isRunning { process.terminate() }
        var deadline = ContinuousClock.now + .seconds(5)
        while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            deadline = ContinuousClock.now + .seconds(1)
            while process.isRunning && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        return !process.isRunning
    }

    /// Whether the sampler process is still running, and whether its output handler has been cleared: what a
    /// caller (and the wiring test) checks to know nothing was left behind.
    var isRunning: Bool { process.isRunning }
    var outputHandlerCleared: Bool { pipe.fileHandleForReading.readabilityHandler == nil }

    enum SamplerError: Error { case notAttached(String), neverBegan(String) }
}

