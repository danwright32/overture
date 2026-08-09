import Foundation

// #1616: how long a reachability check really takes, learned from the checks that have actually run.
//
// The selection bar quotes a wait before Dan spends anything, and until this it multiplied the number of
// rounds by ONE hand-set constant taken from a single 2026-07-27 sample of three shows run one after
// another. Every run since has recorded its own wall clock (`runCost.durationMs`, written into
// `overture-prep-results.json` by `mac/scripts/lib/models.sh`), so the app had better evidence on disk than
// the guess it was using, and the bar promised a wait the run could not keep.
//
// WHAT THE RECORDED DATA ACTUALLY DISTINGUISHES, measured before any of this was written:
//
//   `runCost` lives in the results file, which the next run OVERWRITES, and a Prep run and a check share
//   that one file. So at any moment exactly one runCost record exists on this Mac, it does not say which
//   kind of run wrote it, and it carries no lookup count. It is a reading, not a history.
//
//   What it does carry is `durationMs` (deliberately the LONGEST stream, not the sum, so it really is the
//   run's wall clock) and `streams` (the chunk count, which for a check is how many lookups ran at once).
//
// Both halves of that shape the design. The history has to be accumulated by the app, on the settle path
// where `RunKind` already knows a check from a Prep run, with the lookup count taken from the check's own
// marker. And the per-run figure that is worth pooling is SECONDS PER ROUND, never seconds per lookup.
//
// A ROUND is one wave of concurrent lookups, and its wall clock is its SLOWEST member, not its average.
// The one recorded check on this Mac (2026-08-07, three shows in three chunks) took 146s, 390s and 150s in
// its three streams and therefore 390s overall. That is why a run that did NOT fan out teaches nothing
// here: 157 seconds for one lookup with the machine to itself and 390 seconds for the slowest of three are
// not the same measurement, and an average over both predicts neither.
struct ProbeDurationHistory: Codable, Equatable, Sendable {
    var version: Int = 1
    var runs: [Run] = []

    // `streams` is stored, not derived. It is the concurrency the runner ACTUALLY used, which is what says
    // whether this run is comparable with the next one, and deriving it from `lookups` would assume a cap
    // that `OVERTURE_PREP_MAX_PARALLEL` can change under us.
    struct Run: Codable, Equatable, Sendable {
        var lookups: Int
        var streams: Int
        var seconds: Double
    }

    // The last ten, so the pace tracks recent behaviour rather than averaging over all history forever.
    // Same window as the Reading-calendars pace (RunDurationHistory), for the same reason.
    static let maxEntries = 10

    // "A handful". Below this an average is noise: the three lookups inside one recorded check spanned
    // 146s to 390s, so one run says very little about the next. Until three exist the bar quotes the
    // hand-set constant, exactly as it did before any of this, rather than a confident-looking figure
    // drawn from a single night.
    static let minForEstimate = 3

    // How many waves a run of this size took at this concurrency. The runner splits the work-list into
    // `streams` chunks and each chunk works through its slice in order, so this is the depth of the
    // deepest chunk, which is what the wall clock measures.
    static func rounds(lookups: Int, streams: Int) -> Int {
        guard lookups > 0, streams > 0 else { return 0 }
        return (lookups + streams - 1) / streams
    }

    // Whether this run measures the same thing the next one will.
    //
    // Fanned out (`streams >= 2`) and therefore a real round of competing lookups, at least two lookups
    // deep, with a duration that is a number and a per-round figure inside what the run's own stall
    // warning considers normal. A round longer than that is not a pace, it is a run that went wrong, and
    // one of those stored would inflate every wait the bar quotes for the next ten checks.
    //
    // `streams > lookups` is impossible (the runner never makes an empty chunk), so it means the record is
    // not describing what it claims to describe and is refused rather than reasoned about.
    static func isComparable(lookups: Int, streams: Int, seconds: Double) -> Bool {
        guard lookups >= 2, streams >= 2, streams <= lookups else { return false }
        guard seconds.isFinite, seconds > 0 else { return false }
        let waves = rounds(lookups: lookups, streams: streams)
        guard waves > 0 else { return false }
        return seconds / Double(waves) <= RunTimeouts.reachabilityProbe
    }

    // Append and cap. A run that cannot teach anything is refused HERE rather than stored and filtered on
    // the way out: stored, ten one-show rechecks would push the last real evidence off the front of the
    // file and the estimate would silently go back to the constant with a full history sitting beside it.
    func recording(lookups: Int, streams: Int, seconds: Double) -> ProbeDurationHistory {
        guard Self.isComparable(lookups: lookups, streams: streams, seconds: seconds) else { return self }
        var next = runs
        next.append(Run(lookups: lookups, streams: streams, seconds: seconds))
        if next.count > Self.maxEntries {
            next.removeFirst(next.count - Self.maxEntries)
        }
        return ProbeDurationHistory(version: version, runs: next)
    }

    // The learned figure: pooled seconds per round over the comparable stored runs, so a three-round run
    // weighs three times a single-round one rather than each run's own ratio counting equally.
    //
    // nil, never a number, until there are enough of them. The caller falls back to the constant on nil,
    // which is the state that ships first and the one that has to be honest: no history, no claim.
    //
    // Every stored run is re-judged here even though `recording` already refused the bad ones. Nothing
    // parsed off disk is trusted for having been written (L50): a hand edit, a file from an older shape,
    // or a zero written by a bug must read as no evidence rather than as a pace of nought.
    var learnedSecondsPerRound: Double? {
        let usable = runs.filter { Self.isComparable(lookups: $0.lookups, streams: $0.streams, seconds: $0.seconds) }
        guard usable.count >= Self.minForEstimate else { return nil }
        let totalRounds = usable.reduce(0) { $0 + Self.rounds(lookups: $1.lookups, streams: $1.streams) }
        guard totalRounds > 0 else { return nil }
        let totalSeconds = usable.reduce(0.0) { $0 + $1.seconds }
        guard totalSeconds.isFinite, totalSeconds > 0 else { return nil }
        return totalSeconds / Double(totalRounds)
    }
}

// Persistence, best-effort in both directions and for the same reasons RunDurationHistoryStore is: a
// missing or malformed file reads as no history (so the bar quotes the constant), and a failed write is
// swallowed, because telemetry must never disturb a run that has just finished settling paid-for answers.
//
// Deliberately its own JSON file in the handoff directory rather than a table in the live SwiftData store:
// operational telemetry, not Dan's data, and that store has a history of corruption incidents.
enum ProbeDurationHistoryStore {
    static var defaultURL: URL {
        StoreLocation.handoffDirectory.appendingPathComponent("overture-probe-duration-history.json")
    }

    static func load(from url: URL = defaultURL) -> ProbeDurationHistory {
        guard let data = try? Data(contentsOf: url),
              let history = try? JSONDecoder().decode(ProbeDurationHistory.self, from: data) else {
            return ProbeDurationHistory()
        }
        return history
    }

    // Takes an optional so the one call site can hand over whatever the finished run produced without a
    // decision of its own: nothing to record is a no-op here, and never a zero written into the file.
    @discardableResult
    static func record(_ run: ProbeDurationHistory.Run?, at url: URL = defaultURL) -> ProbeDurationHistory {
        let existing = load(from: url)
        guard let run else { return existing }
        let updated = existing.recording(lookups: run.lookups, streams: run.streams, seconds: run.seconds)
        guard updated != existing, let data = try? JSONEncoder().encode(updated) else { return existing }
        try? data.write(to: url, options: .atomic)
        return updated
    }
}

// #1616: what a finished run recorded about itself, read back out of the results file.
//
// `runCost` is written by `mac/scripts/lib/models.sh` after the run has finished, and `docs/contracts.md`
// pins the split this depends on: `recorded: true` carries `durationMs`, and `recorded: false` carries NO
// `durationMs` key at all, only `partialDurationMs`. That absence is the point. A chunked check is up to
// ten concurrent claudes, so one dead chunk leaves a real but incomplete figure, and a partial wall clock
// read as the whole would teach the bar that checks are faster than they are.
struct RecordedRunCost: Equatable, Sendable {
    let seconds: TimeInterval
    // How many chunks ran at once. For a check this is the concurrency; a Prep run is never chunked.
    let streams: Int

    // Decoded, never subscripted. `JSONSerialization` hands back an NSNumber for both `true` and `1`, so a
    // hand-written `as? Double` would read `"recorded": true` as a duration of one millisecond; Codable
    // refuses the type outright, which is the behaviour this needs.
    private struct Envelope: Decodable {
        struct Cost: Decodable {
            var recorded: Bool?
            var durationMs: Double?
            var streams: Int?
        }
        var runCost: Cost?
    }

    // nil for anything that is not a complete, usable reading: not JSON, no `runCost`, a run that reported
    // partially, a duration that is missing or not a number or not positive, a missing stream count.
    //
    // The one rule the whole type exists for (L50): a value parsed from stored data never reaches a
    // comparison or an average. It arrives as a number or it does not arrive, and the caller falls back to
    // the hand-set constant rather than to whichever side a failed parse happens to land on.
    static func complete(from data: Data) -> RecordedRunCost? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              let cost = envelope.runCost,
              cost.recorded == true,
              let durationMs = cost.durationMs, durationMs.isFinite, durationMs > 0,
              let streams = cost.streams, streams >= 1
        else { return nil }
        return RecordedRunCost(seconds: durationMs / 1000, streams: streams)
    }

    static func complete(contentsOf url: URL) -> RecordedRunCost? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return complete(from: data)
    }
}

// #1616: whether a check that has just settled is allowed to teach the estimate anything.
//
// Its own type, and pure, because the alternative is this decision living inside a SwiftUI view where
// nothing can reach it (#863). The view is left with one line: hand over what the run recorded, and let
// this say whether it counts.
enum ProbeRunPaceRecording {

    /// - Parameters:
    ///   - lookups: how many lookups the run was launched with, from the check's own marker. nil when the
    ///     marker predates that field, and a run whose size is unknown cannot say how many rounds its wall
    ///     clock covered.
    ///   - cost: what the runner recorded, or nil when it recorded nothing usable.
    ///   - cancelled: Dan stopped this check. Its wall clock is the time up to the stop, not the time the
    ///     work takes. Checked separately from `cost` even though a cancel usually leaves no complete
    ///     record either: two facts, and neither is allowed to stand in for the other.
    static func sample(lookups: Int?, cost: RecordedRunCost?, cancelled: Bool) -> ProbeDurationHistory.Run? {
        guard !cancelled, let lookups, let cost else { return nil }
        guard ProbeDurationHistory.isComparable(lookups: lookups, streams: cost.streams,
                                                seconds: cost.seconds) else { return nil }
        return ProbeDurationHistory.Run(lookups: lookups, streams: cost.streams, seconds: cost.seconds)
    }
}
