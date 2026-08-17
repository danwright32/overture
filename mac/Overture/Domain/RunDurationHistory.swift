import Foundation

// #1427: how long past Reading-calendars runs took, so the progress dialog can predict "~X remaining"
// instead of only counting up. A small capped log of completed runs (source count + wall-clock seconds),
// from which a per-source pace is learned and multiplied by THIS run's remaining source count.
//
// Deliberately NOT in the live SwiftData store: this is operational telemetry, not user data, and that
// store has a history of corruption incidents (AGENTS.md, "Restoring Overture from a backup"), so a new
// table for something this low-stakes is not worth the risk. It lives as its own JSON file in the handoff
// directory (docs/contracts.md), written and read by the app alone.
//
// Two rules keep the estimate honest: only runs that FINISH NORMALLY are recorded (a cancelled or
// timed-out run's partial timing does not reflect real pace), and no estimate shows at all until a handful
// of runs exist, so a fresh install never guesses from one data point.
struct RunDurationHistory: Codable, Equatable, Sendable {
    var version: Int = 1
    var runs: [Run] = []

    struct Run: Codable, Equatable, Sendable {
        var sources: Int
        var seconds: Double
    }

    // Keep the last ten completed runs, so the pace tracks recent behaviour (a newly added slow feed, a
    // faster machine) rather than averaging over all history forever.
    static let maxEntries = 10
    // "A handful": below this, an average is too noisy to show. A single 40-source run says nothing about
    // the next 3-source one, so the dialog stays exactly as it is today (elapsed only) until there is enough.
    static let minForEstimate = 3

    // Append a completed run and cap at the last `maxEntries`. Degenerate samples (no sources, or a
    // non-positive duration from clock skew) are dropped rather than stored, so they can never skew the
    // pace. Pure and value-returning; the store persists the result.
    func recording(sources: Int, seconds: Double) -> RunDurationHistory {
        guard sources > 0, seconds > 0 else { return self }
        var next = runs
        next.append(Run(sources: sources, seconds: seconds))
        if next.count > Self.maxEntries {
            next.removeFirst(next.count - Self.maxEntries)
        }
        return RunDurationHistory(version: version, runs: next)
    }

    // Pooled seconds-per-source across the stored runs (total seconds / total sources), not the mean of
    // per-run ratios: pooling weights a 40-source run more than a 3-source one, which is what we want, and
    // is stable against a single tiny run. nil until `minForEstimate` runs exist, so the caller shows no
    // estimate rather than a guess.
    var secondsPerSource: Double? {
        guard runs.count >= Self.minForEstimate else { return nil }
        let totalSources = runs.reduce(0) { $0 + $1.sources }
        guard totalSources > 0 else { return nil }
        let totalSeconds = runs.reduce(0.0) { $0 + $1.seconds }
        return totalSeconds / Double(totalSources)
    }

    // The predicted time left: the learned pace times how many sources are still to go. nil when there is
    // not enough history to have a pace at all. Clamps a completed >= total to zero rather than negative.
    func remaining(total: Int, completed: Int) -> TimeInterval? {
        guard let pace = secondsPerSource else { return nil }
        let left = max(0, total - completed)
        return pace * Double(left)
    }
}

// Persistence for the history. Best-effort for a READER: a missing or malformed file reads as empty
// history, so the dialog simply shows no estimate, and a failed write is swallowed (telemetry must never
// disturb a run).
//
// #2879: NOT best-effort for the writer. `record` refuses to write over a file it could not read, because
// rebuilding the file from a read that answered empty is how an unreadable history got erased outright
// (L105). Absent still writes: there is nothing to lose, and the first run of a fresh install has to land.
enum RunDurationHistoryStore {
    static var defaultURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("overture-run-duration-history.json")
    }

    static func load(from url: URL = defaultURL) -> RunDurationHistory {
        read(from: url).value ?? RunDurationHistory()
    }

    // #2879: the read `record` goes through, keeping absent apart from unreadable. `load` flattens both
    // to an empty history, which is right for a READER (no learned pace yet, either way) and catastrophic
    // for the WRITER below.
    private static func read(from url: URL) -> HandoffRead<RunDurationHistory> {
        HandoffFile.read(at: url) { try JSONDecoder().decode(RunDurationHistory.self, from: $0) }
    }

    @discardableResult
    static func record(sources: Int, seconds: Double, at url: URL = defaultURL) -> RunDurationHistory {
        let existing = read(from: url)
        // #2879: REFUSES to write over a file it could not read. This rebuilt the file from `load`, which
        // answered an unreadable file with an empty history, so the first corrupt or half-written read
        // erased every run ever recorded and the estimate silently started again from nothing (L105).
        // Absent is different and still writes: there is genuinely nothing to lose.
        if case .unreadable = existing { return RunDurationHistory() }
        let updated = (existing.value ?? RunDurationHistory()).recording(sources: sources, seconds: seconds)
        if let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: url, options: .atomic)
        }
        return updated
    }
}
