import Foundation

// #1114: an always-on, per-source record of how much each watched calendar moves between scouts, so #913
// can retune minReBaselineFraction against REAL movement rather than the reasoned 0.9 guess. One line per
// source per successful scout: the current readable count, the previous scout's count and their delta, and
// the baseline the run is judged against. Written best-effort to a rotated log under ~/Library/Logs/Overture.
//
// The line format is a pure function so it stays testable (#863). The default-file write is suppressed when
// running under tests: otherwise every test that drives recordSuccessfulRead would inject fake movement into
// the very evidence file #913 reads. Tests exercise the writing through the explicit-URL overload instead.
enum FeedMovementLog {
    static var fileURL: URL {
        AgentLogLocation.directory.appendingPathComponent("feed-movement.log")
    }

    // One parseable key=value line. The timestamp (ISO-8601, from the passed `now`) leads it so the file
    // sorts and greps by time; org is quoted so a space in the name can't split a field.
    static func line(sourceId: String, org: String, current: Int, previous: Int, baseline: Int, now: Date) -> String {
        let ts = ISO8601DateFormatter().string(from: now)
        let delta = current - previous
        // copy-inventory:ignore-start  a machine-parsed diagnostic log line for #913, never shown to Dan
        return "\(ts) source=\(sourceId) org=\(quoted(org)) current=\(current) previous=\(previous) delta=\(delta) baseline=\(baseline)"
        // copy-inventory:ignore-end
    }

    // Read straight off a source: uses the PREVIOUS scout's stored count and baseline, so the caller MUST
    // emit before recordSuccessfulRead overwrites them.
    static func line(for source: WatchedSource, current: Int, now: Date) -> String {
        line(sourceId: source.sourceId, org: source.orgName, current: current,
             previous: source.lastReadableCount, baseline: source.baselineFeedCount, now: now)
    }

    // Production entry point, called from recordSuccessfulRead. No-ops under tests (see the type comment).
    static func record(for source: WatchedSource, current: Int, now: Date) {
        guard !isUnderTest else { return }
        write(line(for: source, current: current, now: now), to: fileURL)
    }

    // Explicit-URL variant, so the formatting and the append are testable without touching the real log.
    static func record(sourceId: String, org: String, current: Int, previous: Int, baseline: Int, now: Date,
                       to url: URL) {
        write(line(sourceId: sourceId, org: org, current: current, previous: previous, baseline: baseline, now: now),
              to: url)
    }

    private static var isUnderTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    private static func quoted(_ s: String) -> String {
        "\"\(s.replacingOccurrences(of: "\"", with: "'"))\""
    }

    // Best-effort append (create the dir/file if missing, rotate when oversized). A diagnostic log that
    // cannot be written must never break a scout, so every step is `try?`.
    private static func write(_ text: String, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        LogRotation.cap(files: [url], maxBytes: AgentLogLocation.defaultMaxLogBytes)
        guard let data = (text + "\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
