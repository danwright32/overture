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

// Persistence for the history, best-effort in both directions: a missing or malformed file reads as empty
// history (so the dialog simply shows no estimate), and a failed write is swallowed (telemetry must never
// disturb a run). Mirrors ScoutExtractProgressDecoder's tolerant-read convention.
enum RunDurationHistoryStore {
    static var defaultURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("overture-run-duration-history.json")
    }

    static func load(from url: URL = defaultURL) -> RunDurationHistory {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(RunDurationHistory.self, from: data) else {
            return RunDurationHistory()
        }
        return history
    }

    @discardableResult
    static func record(sources: Int, seconds: Double, at url: URL = defaultURL) -> RunDurationHistory {
        let updated = load(from: url).recording(sources: sources, seconds: seconds)
        if let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: url, options: .atomic)
        }
        return updated
    }
}
