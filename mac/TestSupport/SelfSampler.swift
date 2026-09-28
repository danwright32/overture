import Foundation

// Moved here from ScoutLandingAttributionProbeTests (#4275) so the hosted view attribution probe (#4106)
// samples its own process through the same sampler rather than a copy of it (L613). It names no app type,
// which is what lets it live in TestSupport and compile into both test targets.

/// `/usr/bin/sample` pointed at THIS process. It prints its "Sampling process" line once attached, which is
/// what `start` waits on (bounded), so the landing never begins before the sampler is looking.
final class LandingSelfSampler: @unchecked Sendable {
    private let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var attached = false
    private var said = ""
    let file: URL
    let seconds: Int

    init(seconds: Int, file: URL) {
        self.seconds = seconds
        self.file = file
    }

    func start() async throws {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(getpid()), String(seconds), "1", "-mayDie", "-file", file.path]
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let text = String(decoding: h.availableData, as: UTF8.self)
            guard let self else { return }
            self.lock.lock()
            self.said += text
            if self.said.contains("Sampling process") { self.attached = true }
            self.lock.unlock()
        }
        try process.run()
        let deadline = ContinuousClock.now + .seconds(15)
        while ContinuousClock.now < deadline {
            if isAttached { return }
            if !process.isRunning { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        throw SamplerError.notAttached(output)
    }

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
        if process.isRunning { process.terminate(); return false }
        pipe.fileHandleForReading.readabilityHandler = nil
        return process.terminationStatus == 0 && FileManager.default.fileExists(atPath: file.path)
    }

    enum SamplerError: Error { case notAttached(String) }
}

