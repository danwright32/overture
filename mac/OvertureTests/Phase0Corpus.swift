import Foundation
import SwiftData
#if OVERTURE_HOSTED_TESTS
@testable import Overture
#endif

// #4106: the probe helpers every Phase 0, 0b and 0c probe shares: the opt in, the stopwatch, a median of
// five with its spread, the load average, and the 4x corpus built from a clone of the live store.
//
// Lifted out of QueueEnginePhase0ProbeTests.swift unchanged, so the HOSTED view body probe (0c.8) compiles
// the same helpers rather than a copy of them. Compiled into both test targets: the pure one reaches the
// app by compiling its sources in, the hosted one through the import above, which only the hosted
// target's OVERTURE_HOSTED_TESTS condition switches on (mac/project.yml).
//
// Every timing is a median of five with its spread (L395, L656), taken in the Debug build the test runner
// builds, which is the build every earlier figure on #4106 was taken in too; a Release build is faster and
// none of these numbers describe it. Load average is printed beside each block (L356).

enum Phase0 {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0"] != nil
    }

    nonisolated static var liveStoreExists: Bool { LiveStoreClone.liveStoreURL != nil }

    nonisolated static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    nonisolated static func ms(since start: UInt64) -> Double { Double(now() - start) / 1_000_000 }

    /// #4384: a probe's save that did not reach the store, naming the step it came from. Every probe save goes
    /// through `save`, `saveFailure` or `requireSaved` below rather than `try? context.save()`, which let a
    /// save that never landed read exactly like one that did, so the comparisons and timings after it judged
    /// uncommitted state (L515, L10). Carries the save's own text (L520).
    struct SaveNotLanded: Error, CustomStringConvertible {
        let step: String
        let underlying: String
        var description: String { "the \(step) save did not land: \(underlying)" }
    }

    /// nil when the save landed, otherwise the save's own error text. For a closure that cannot throw: a
    /// stopwatch body, or work run on another thread, whose caller then hands the answer to `requireSaved`.
    nonisolated static func saveFailure(_ context: ModelContext,
                                        save: (ModelContext) throws -> Void = { try $0.save() }) -> String? {
        do {
            try save(context)
            return nil
        } catch {
            return String(describing: error)
        }
    }

    nonisolated static func requireSaved(_ failure: String?, step: String) throws {
        if let failure { throw SaveNotLanded(step: step, underlying: failure) }
    }

    nonisolated static func save(_ context: ModelContext, step: String,
                                 save: (ModelContext) throws -> Void = { try $0.save() }) throws {
        try requireSaved(saveFailure(context, save: save), step: step)
    }

    nonisolated static func time(_ work: () -> Void) -> Double {
        let start = now()
        work()
        return ms(since: start)
    }

    struct Reading: Sendable {
        let runs: [Double]
        var median: Double { runs.sorted()[runs.count / 2] }
        var low: Double { runs.min() ?? 0 }
        var high: Double { runs.max() ?? 0 }
        var text: String { String(format: "%.1f ms (%.1f to %.1f)", median, low, high) }
        /// The line `scripts/compare-before-after.sh` reads out of a run's log (#4615): this reading's median
        /// under `metric`, one word with no spaces. One run is one side; a verdict needs that script's balanced
        /// rounds, because the side run second under the shared test lock reads slower (#4614).
        /// #4617: the metric is made one word here rather than trusted to be one, because most probes name a
        /// reading after a corpus label such as "live clone", and the script drops a line whose metric holds a
        /// space, so that reading would silently never be compared.
        func probeLine(_ metric: String) -> String {
            "probe reading: \(Phase0.metricWord(metric)) " + String(format: "%.3f", median)
        }
    }

    /// `metric` as the one word the comparison script reads: every character outside letters, digits, dot,
    /// underscore and hyphen becomes a hyphen.
    nonisolated static func metricWord(_ metric: String) -> String {
        String(metric.map { c -> Character in
            c.isASCII && (c.isLetter || c.isNumber || c == "." || c == "_" || c == "-") ? c : "-"
        })
    }

    // #4617: the ways a probe gets a reading, `median5`, `reading` and `alternating` below, each print its
    // `probe reading:` line as they make it, so a probe using them cannot report a reading the before and after
    // comparison never sees. Building a `Reading` directly anywhere else in the test targets is refused by
    // `ProbeReadingLineGuardTests`, and so is a median a probe takes of its own. `emit` is the seam the unit
    // tests read the line through.

    /// Times `work` five times and prints the reading's line under `metric` (unique within one run: a metric
    /// read twice in one run is UNMEASURED in the comparison).
    nonisolated static func median5(_ metric: String, emit: (String) -> Void = { print($0) },
                                    _ work: () -> Void) -> Reading {
        reading(metric, runs: (0..<5).map { _ in time(work) }, emit: emit)
    }

    /// A reading of runs the probe timed itself, its line printed under `metric`. An empty sample measured
    /// nothing, so it prints NO line (the comparison then names the metric as missing rather than comparing a
    /// zero, L90) and reads as 0 in the probe's own text, as the probes always showed it.
    nonisolated static func reading(_ metric: String, runs: [Double],
                                    emit: (String) -> Void = { print($0) }) -> Reading {
        guard !runs.isEmpty else { return Reading(runs: [0]) }
        let r = Reading(runs: runs)
        emit(r.probeLine(metric))
        return r
    }

    /// The line naming metrics a probe times inside ONE run as rival ways of doing one thing, and whether
    /// their samples were taken in alternating order or in a fixed one. The before and after comparison is
    /// not biased by either, since both sides run the same order; a comparison BETWEEN them inside a run is,
    /// when the order is fixed: the one timed second carries the order effect (L395, #4614).
    nonisolated static func orderLine(alternated: Bool, _ metrics: [String]) -> String {
        "probe order: " + (alternated ? "alternated " : "fixed ")
            + metrics.map(metricWord).joined(separator: ",")
    }

    /// Times rival `arms` against each other, five samples each, the first arm of sample `i` being arm
    /// `i % arms.count`, so whatever the order does inside the run lands on every arm alike rather than on
    /// whichever is timed second. Prints each arm's reading line and the order line. With five samples and
    /// two arms the first arm goes first three times and the second twice, the nearest five can come.
    nonisolated static func alternating(_ arms: [(metric: String, work: () -> Void)], samples: Int = 5,
                                        emit: (String) -> Void = { print($0) }) -> [Reading] {
        var runs = Array(repeating: [Double](), count: arms.count)
        for i in 0..<samples {
            for k in 0..<arms.count {
                let arm = (i + k) % arms.count
                runs[arm].append(time(arms[arm].work))
            }
        }
        let readings = zip(arms, runs).map { reading($0.0.metric, runs: $0.1, emit: emit) }
        emit(orderLine(alternated: true, arms.map { $0.metric }))
        return readings
    }

    /// Says that rival `metrics` were timed in a FIXED order inside one run, where rewriting the probe to
    /// alternate them is not worth what it would change (the decision is written at each call).
    nonisolated static func fixedOrder(_ metrics: [String], emit: (String) -> Void = { print($0) }) {
        emit(orderLine(alternated: false, metrics))
    }

    /// The median of a COUNT a probe reports beside its timings (keys re-asked, rows rebuilt). Not a duration,
    /// so it prints no reading line: the comparison reads milliseconds.
    nonisolated static func medianCount(_ values: [Int]) -> Int {
        values.isEmpty ? 0 : values.sorted()[values.count / 2]
    }

    // THE load average reader every probe shares (#4315). It used to be three copies, one per probe
    // family, and they disagreed on a failed read: one read it as 0, a quiet Mac, which could let a
    // replay on an unmeasured Mac score a PASS (fixed on #4314). The next probe copies whichever one it
    // finds first (L263, L370), so there is one, and `Phase0LoadReaderTests` fails on a second call to
    // the system reader anywhere in the test targets.

    /// The one, five and fifteen minute averages. `getloadavg` returns how many it filled, -1 on failure,
    /// and leaves the rest at whatever the buffer held, so a reading it did not fill is INFINITE: it can
    /// never pass as quiet, where read as 0 it would (L490).
    nonisolated static func loadReadings(samplesTaken: Int32, averages: [Double]) -> [Double] {
        (0..<3).map { i in i < Int(samplesTaken) && i < averages.count ? averages[i] : .infinity }
    }

    nonisolated static func loadAverages() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        let taken = getloadavg(&l, 3)
        return loadReadings(samplesTaken: taken, averages: l)
    }

    nonisolated static func oneMinuteLoad() -> Double { loadAverages()[0] }

    /// The line printed beside every timed block (L356).
    nonisolated static func loadText(_ readings: [Double]) -> String {
        String(format: "load %.2f %.2f %.2f", readings[0], readings[1], readings[2])
    }

    nonisolated static func load() -> String { loadText(loadAverages()) }

    /// Waits for the one minute load to fall under `below`, bounded by `deadline` seconds (L110), polling
    /// every `poll`. `load` is the last reading; one at or over `below` means the wait ran out, and a load
    /// that could not be read is infinite, so it never ends the wait early as quiet. The reader, the sleep
    /// and the clock are parameters so a test can drive every outcome without waiting (L524).
    nonisolated static func waitForLoad(
        below: Double, deadline seconds: Double, poll: Double,
        read: () -> Double = { Phase0.oneMinuteLoad() },
        sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
        clock: () -> Double = { Double(Phase0.now()) / 1_000_000_000 }
    ) -> (load: Double, waited: Double, text: String) {
        let start = clock()
        var waited = 0.0
        var load = read()
        while load >= below && waited < seconds {
            sleep(poll)
            waited = clock() - start
            load = read()
        }
        let verdict = load < below ? "yes" : "NO"
        return (load, waited, String(format: "one minute load %.2f (under %.0f: ", load, below) + verdict
                    + String(format: ", waited %.0f s)", waited))
    }

    nonisolated static func say(_ line: String) { print("phase0 " + line) }

    nonisolated static func openContainer(at url: URL) throws -> ModelContainer {
        try FileStores.container(for: AppSchema.schema, configurations: [
            ModelConfiguration(schema: AppSchema.schema, url: url, cloudKitDatabase: .none)])
    }

    /// The text glued onto copy `k`'s names and listing addresses ("qa", "qb", ...).
    nonisolated static func glue(forCopy k: Int) -> String { "q" + String(UnicodeScalar(UInt8(96 + k))) }

    /// A copy of `clone` holding `factor` times the shows. The copies scale the clone's DISTRIBUTIONS rather
    /// than duplicating rows (L391): every copy keeps its row's shape (status, dates, fields, contacts) and
    /// gets a new identity (natural key, presenter, venue, title, series, thread ids, contact addresses), so
    /// cross-row clusters keyed on those form their own clusters rather than growing fourfold. Dates are
    /// kept, so a night holds `factor` times the shows it did: pessimistic for any term grouped by night,
    /// and stated beside every reading taken on it.
    ///
    /// Listings are part of that identity too (#4106, found by the #4275 attribution): a copy's
    /// `sourceListingURL` and every one of its `runSourceURLs` carry the copy's glue, so a listing holding N
    /// shows in the clone holds N in each copy rather than 4N in one. `ScaledCorpusKeepsListingsDistinctTests`
    /// holds that.
    ///
    /// And so are sources (#4427): each copy has its own `WatchedSource` rows and its own `sourceIds`, and a
    /// landing on the corpus lands `scaledResults(_:factor:)`, a copy of every result per copy, so a 4x
    /// landing reads like a store four times the size. `ScaledCorpusLandsLikeALargerStoreTests` holds that.
    /// The work is in `ScaledCorpus`, a file of its own so the landing oracle's freeze builds this corpus
    /// rather than 6d3453d8's (the reason is written there).
    ///
    /// `era: .before4288` is the corpus as it stood before #4288 (and so before #4427). Only #4372's
    /// attribution probe asks for it, to reproduce the reading probe 0b.6 took on that corpus; every other
    /// caller takes the default.
    nonisolated static func scaledCopy(of clone: URL, factor: Int, in dir: URL,
                                       era: ScaledCorpus.Era = .current) throws -> URL {
        try ScaledCorpus.build(of: clone, factor: factor, in: dir, era: era)
    }

    /// The scout results to land on a corpus `factor` times the clone (#4427): every result once per copy,
    /// under that copy's own source, its events glued as the copy's rows are. Factor 1 returns them unchanged,
    /// so a probe looping over sizes calls this at every size.
    nonisolated static func scaledResults(_ results: ScoutExtractResults, factor: Int) -> ScoutExtractResults {
        ScaledCorpus.results(results, factor: factor)
    }

    /// #4327 step 0.7: the INSERTING variant of a results file. Per source, `share` of its events copied as new
    /// shows (`insertedCopies`); `round` is in every title and link, so a later round inserts again rather than
    /// re-landing an earlier round's rows. In memory only. Moved here unchanged from
    /// `ScoutLandingAttributionProbeTests` (#4343), so the acceptance rig and that probe land one variant;
    /// `linkTag` names who added the link, and defaults to that probe's own.
    nonisolated static func insertingResults(_ results: ScoutExtractResults, share: Double, round: Int,
                                             linkTag: String = "probe4327") -> ScoutExtractResults {
        var out = results
        for (s, result) in results.results.enumerated() where !result.events.isEmpty {
            out.results[s].events += insertedCopies(of: result.events, share: share,
                                                    tag: { "\(round)s\(s)e\($0)" }, linkTag: linkTag)
        }
        return out
    }

    /// The title every inserted show carries and no real show does, so a probe can find (and remove) what it added.
    nonisolated static let syntheticTitle = "Probe Synthetic Recital"

    /// The one rule for an inserting round, over any list of events: `share` of them (rounded, at least one where
    /// there are any), evenly spaced, copied at the same venue, night and presenter, with a title and a link no
    /// stored show carries. The results file's events (`insertingResults`) and the acceptance rig's native feed
    /// events (#4343) both go through it, so the two variants cannot drift apart (L370).
    nonisolated static func insertedCopies<Event: Phase0InsertableEvent>(of events: [Event], share: Double,
                                                                       tag: (Int) -> String,
                                                                       linkTag: String) -> [Event] {
        guard !events.isEmpty else { return [] }
        let n = max(1, Int((Double(events.count) * share).rounded()))
        let stride = max(1, events.count / n)
        return (0..<n).map { i in
            var e = events[(i * stride) % events.count]
            let t = tag(i)
            e.title = "\(syntheticTitle) \(t)"
            e.sourceUrl = e.sourceUrl.map { $0 + ($0.hasSuffix("/") ? "" : "/") + "\(linkTag)-\(t)" }
            e.seriesId = nil
            return e
        }
    }


    /// The shape a scaled corpus must keep (L48): printed side by side for the clone and the copy.
    static func shape(_ rows: [Prospect]) -> String {
        let contacts = rows.reduce(0) { $0 + $1.recipients.count }
        let dismissed = rows.filter { $0.statusRaw == "dismissed" }.count
        let contacted = rows.filter { $0.sentAt != nil }.count
        var perNight: [String: Int] = [:]
        for r in rows { perNight[r.performanceDate ?? "", default: 0] += 1 }
        let pairs = Set(rows.map { "\($0.presenter ?? "")|\($0.venue ?? "")" }).count
        return "\(rows.count) shows, \(contacts) contacts (\(String(format: "%.3f", Double(contacts) / Double(max(rows.count, 1)))) a show), "
            + "dismissed \(String(format: "%.3f", Double(dismissed) / Double(max(rows.count, 1)))), "
            + "contacted \(String(format: "%.3f", Double(contacted) / Double(max(rows.count, 1)))), "
            + "largest night \(perNight.values.max() ?? 0), presenter-venue pairs \(pairs)"
    }
}

/// What `Phase0.insertedCopies` needs of an event: the scout extract results' events and the native feeds' both have it.
protocol Phase0InsertableEvent {
    var title: String { get set }
    var sourceUrl: String? { get set }
    var seriesId: String? { get set }
}

extension ScoutExtractEvent: Phase0InsertableEvent {}
extension ExtractedEvent: Phase0InsertableEvent {}
