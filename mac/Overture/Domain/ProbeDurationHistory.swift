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

        // #2762: was another RUN SLOT alive while this one was being measured.
        //
        // Deliberately NOT "was the machine busy". A scout extract (up to four claudes, fired hourly by
        // `autoScoutIfDue`) or a reply classify can be going too, and folding those in would give one
        // field two meanings depending on which version wrote the row (L118). Those are counted directly
        // by #2762's measurement session instead.
        //
        // Observed by the RUNNER, which is the only thing alive for the whole span, and carried in
        // `runCost` beside the wall clock it qualifies, so one observer answers for both facts about one
        // run rather than two that can disagree exactly when it matters (L70).
        var contended: Bool

        // No default on the property above: a construction site that forgot it would file a co-run sample
        // as solo, which is the one mislabel this whole field exists to prevent (L168). The DECODER
        // supplies one, and that is a different question, answered below.
        private enum CodingKeys: String, CodingKey { case lookups, streams, seconds, contended }

        init(lookups: Int, streams: Int, seconds: Double, contended: Bool) {
            self.lookups = lookups
            self.streams = streams
            self.seconds = seconds
            self.contended = contended
        }

        // A row with NO `contended` key was written before #2762, and every one of those ran while the
        // prep/check exclusion was still in force (#2760 kept it deliberately; #2765 is what lifts it), so
        // no other slot could have been beside it. Reading such a row as SOLO is therefore a fact about
        // the code that wrote it rather than an assumption about the data, which is the only ground on
        // which a new field's emptiness is allowed to speak for old rows (L90).
        //
        // What makes that safe is the other half: every row THIS version writes carries the key, and a
        // run whose contention is UNKNOWN is refused by `ProbeRunPaceRecording.sample` rather than stored
        // flagless. So a flagless row can only ever be one written before the flag existed.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            lookups = try container.decode(Int.self, forKey: .lookups)
            streams = try container.decode(Int.self, forKey: .streams)
            seconds = try container.decode(Double.self, forKey: .seconds)
            contended = try container.decodeIfPresent(Bool.self, forKey: .contended) ?? false
        }
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
    func recording(lookups: Int, streams: Int, seconds: Double, contended: Bool) -> ProbeDurationHistory {
        guard Self.isComparable(lookups: lookups, streams: streams, seconds: seconds) else { return self }
        var next = runs
        next.append(Run(lookups: lookups, streams: streams, seconds: seconds, contended: contended))
        // #2762: the last ten OF EACH CLASS, not the last ten overall. Capped across both, a stretch of
        // co-runs would evict every solo sample, and the next check with the machine to itself would be
        // quoted the hand-set constant with a full history sitting beside it. That is the same failure
        // this cap already refuses to cause for uncomparable runs, arriving through the new field.
        //
        // Trimmed by dropping the oldest of the OVERFULL class only, so the file stays in the order the
        // runs happened rather than being regrouped by class.
        let overfull = next.filter { $0.contended == contended }.count - Self.maxEntries
        if overfull > 0 {
            var toDrop = overfull
            next = next.filter { run in
                guard toDrop > 0, run.contended == contended else { return true }
                toDrop -= 1
                return false
            }
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
    //
    // #2762: pooled WITHIN one contention class and never across it. A check that shared the machine with
    // a Prep run and a check that had it to itself are measuring two different things, and the estimate
    // exists to be read before Dan spends, so three contended samples pooled in would retrain the figure
    // he decides on (L37). A class with fewer than a handful of its own answers nil and the caller falls
    // back to the constant, rather than borrowing the other class's pace, which would be pooling across by
    // another route.
    func learnedSecondsPerRound(contended: Bool) -> Double? {
        let usable = runs.filter {
            $0.contended == contended
                && Self.isComparable(lookups: $0.lookups, streams: $0.streams, seconds: $0.seconds)
        }
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
        read(from: url).value ?? ProbeDurationHistory()
    }

    // #2879: as RunDurationHistoryStore. `load` is right to flatten both empty answers for a reader; the
    // writer must not, or it erases the file it could not read.
    private static func read(from url: URL) -> HandoffRead<ProbeDurationHistory> {
        HandoffFile.read(at: url) { try JSONDecoder().decode(ProbeDurationHistory.self, from: $0) }
    }

    // Takes an optional so the one call site can hand over whatever the finished run produced without a
    // decision of its own: nothing to record is a no-op here, and never a zero written into the file.
    @discardableResult
    static func record(_ run: ProbeDurationHistory.Run?, at url: URL = defaultURL) -> ProbeDurationHistory {
        let read = read(from: url)
        let existing = read.value ?? ProbeDurationHistory()
        guard let run else { return existing }
        // #2879: never write over a file that could not be read (L105). See RunDurationHistoryStore.
        if case .unreadable = read { return ProbeDurationHistory() }
        let updated = existing.recording(lookups: run.lookups, streams: run.streams, seconds: run.seconds,
                                         contended: run.contended)
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

    // #2762: whether another run slot was alive during this run, as the runner observed it.
    //
    // nil is a THIRD state and not a defensive one: the runner script does not ship inside the app bundle,
    // it is resolved from a UserDefaults path into the git checkout, and `update-overture.sh`
    // fast-forwards that checkout BEFORE the rebuild. So a new app meets a script that predates this flag
    // for a couple of minutes on every update, and permanently for anyone who only pulls. Read as solo,
    // that window would file exactly the co-run this issue measures as evidence about a solo one.
    let contended: Bool?

    // #3004: what KIND of run wrote the file this reading came out of, as the runner stamped it.
    //
    // nil is a third state for the same reason `contended`'s is (the runner script is fast-forwarded out
    // of the git checkout before the app is rebuilt, so a new app meets an older script on every update),
    // and additionally for a value this app does not recognise. Both mean "this file does not say", and
    // neither may be read as a kind.
    let kind: RunKind?

    // Decoded, never subscripted. `JSONSerialization` hands back an NSNumber for both `true` and `1`, so a
    // hand-written `as? Double` would read `"recorded": true` as a duration of one millisecond; Codable
    // refuses the type outright, which is the behaviour this needs.
    private struct Envelope: Decodable {
        struct Cost: Decodable {
            var recorded: Bool?
            var durationMs: Double?
            var streams: Int?
            var contended: Bool?
        }
        var runCost: Cost?
        // #3004: at the TOP LEVEL, beside `version`, not inside `runCost`. It is true of the file whether
        // or not the cost reading completed, and a fact filed under a key that can go absent is a fact
        // that disappears exactly when the run went wrong.
        var runKind: String?
    }

    // nil for anything that is not a complete, usable reading: not JSON, no `runCost`, a run that reported
    // partially, a duration that is missing or not a number or not positive, a missing stream count.
    //
    // The one rule the whole type exists for (L50): a value parsed from stored data never reaches a
    // comparison or an average. It arrives as a number or it does not arrive, and the caller falls back to
    // the hand-set constant rather than to whichever side a failed parse happens to land on.
    static func complete(from data: Data) -> RecordedRunCost? {
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        return complete(envelope: envelope)
    }

    // #2879: the same rule with the JSON already decoded, so `complete(contentsOf:)` can tell malformed
    // JSON (which it must report) apart from a well-formed file that simply recorded no cost (which is
    // normal and silent). Split out rather than duplicated, so there is one definition of a usable
    // reading rather than two that can drift.
    private static func complete(envelope: Envelope) -> RecordedRunCost? {
        guard let cost = envelope.runCost,
              cost.recorded == true,
              let durationMs = cost.durationMs, durationMs.isFinite, durationMs > 0,
              let streams = cost.streams, streams >= 1
        else { return nil }
        // `contended` is passed through as it arrives, INCLUDING absent. It is deliberately not part of
        // the guard above: a run that measured itself perfectly well and simply predates the flag has a
        // complete cost reading, and whether that reading may be POOLED is a separate decision belonging
        // to `ProbeRunPaceRecording`.
        return RecordedRunCost(seconds: durationMs / 1000, streams: streams, contended: cost.contended,
                               kind: envelope.runKind.flatMap(RunKind.init(resultsFileValue:)))
    }

    static func complete(contentsOf url: URL) -> RecordedRunCost? {
        // #2879: the DECODE runs inside the shared reader, not after it. Read as two steps, a malformed
        // results file came back as "no cost recorded", which is a legitimate documented state of a
        // perfectly good file (a chunked run that could not measure itself writes `recorded: false`), so
        // a broken file taught the estimate nothing and said nothing.
        HandoffFile.read(at: url) { data -> RecordedRunCost? in
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
                throw CocoaError(.propertyListReadCorrupt)
            }
            return complete(envelope: envelope)
        }.value ?? nil
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
        // #2762: a run that did not say whether it was contended is not stored at all. It cannot be filed
        // as solo without mislabelling the co-run this issue exists to measure, and it cannot be filed as
        // contended either, so it is evidence about neither class. The cost is one lost sample inside the
        // update window described on `RecordedRunCost.contended`, and the gain is that a flagless row in
        // the history can only ever mean "written before the flag existed", which is what lets the decoder
        // read those as solo on the strength of the exclusion that was in force.
        guard let contended = cost.contended else { return nil }
        // #3004: a run that SAYS it was not a check teaches the check estimate nothing. #2978 fixed which
        // FILE is read; this is the other half, and it holds even when the file read is the right one,
        // because a check running in the prep slot reads the prep slot's file and what sits in it may be
        // an actual Prep run from an hour ago.
        //
        // A file that does not say keeps today's behaviour and is pooled on the slot's trust, rather than
        // ending the pace learning for everyone during the update window. The slot was the only evidence
        // there has ever been and it is right for a check's own file; the stamp only ever adds a way to
        // be sure (L90).
        if let kind = cost.kind, kind != .reachabilityCheck { return nil }
        guard ProbeDurationHistory.isComparable(lookups: lookups, streams: cost.streams,
                                                seconds: cost.seconds) else { return nil }
        return ProbeDurationHistory.Run(lookups: lookups, streams: cost.streams, seconds: cost.seconds,
                                        contended: contended)
    }
}
