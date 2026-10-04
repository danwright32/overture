import Testing
import Foundation
import SwiftData

// #4339 (A11): the FIRST main thread hold of every landing entry point, measured as the product holds it.
//
// MEASUREMENT ONLY. It reads a throwaway `LiveStoreClone` copy of the live store and the fourfold corpus built
// from it (`Phase0.scaledCopy`), never the live store, and lands COPIES of the handoff inputs (the scout extract
// results, Downbeat's export, the imported history) from a sandbox. Nothing reaches the network: `runScout` is
// given a stub fetch and a stub extractor, and nothing is handed off or launched. Opt in, and says it did not
// run otherwise (L98):
//
//   TEST_RUNNER_MEASURE_4339=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/LandingFirstHoldProbeTests
//
// WHAT IT MEASURES. Each window starts at the entry point, the way RootView calls it:
//   - the calendar ingest: `LandingInputs.readResultsFile` and `LandingInputs.read`, then
//     `ScoutExtractLanding.land`, which is `RootView.ingestScoutExtract`'s whole body;
//   - `runScout`, from its first line;
//   - the lead paste, `LeadPasteLanding.landPastedLead` (what `LeadIntakeModel.importAll` awaits), with ONE event
//     and with the events of the largest single source in the results file, the two sizes the plan names.
// The FIRST HOLD is the time from the call until the main thread is first given up: a block queued on the main
// queue just before the call runs at the first suspension that actually yields it. The WORST TURN is the
// longest main thread turn over the whole call, from the same one-millisecond ping `Phase0bMainTurnMonitor`
// takes. Both are read against the 100 ms bar; neither claims the bar is met (Phase E says when it is).
//
// PRIVACY. Counts and milliseconds only: never a show name, a venue, an address or a URL (L222).
@MainActor
@Suite("#4339 the first main thread hold of every landing entry point (opt in, live store clone)", .serialized)
final class LandingFirstHoldProbeTests {

    private let sandboxes = TemporarySandboxes()

    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["MEASURE_4339"] != nil }

    nonisolated static func say(_ line: String) {
        print("hold4339 " + line)
        fflush(stdout)
    }

    struct Hold {
        let first: Double
        let worst: Double
        let wall: Double
        let over100: Int
        var text: String {
            String(format: "first hold %.1f ms, worst turn %.1f ms (%d over 100 ms), wall %.1f ms",
                   first, worst, over100, wall)
        }
    }

    private final class Stamp: @unchecked Sendable {
        private let lock = NSLock()
        private var at: UInt64 = 0
        func set() { lock.withLock { if at == 0 { at = Phase0.now() } } }
        var value: UInt64 { lock.withLock { at } }
    }

    // One call, measured. The stamp is queued on the main queue before the call starts, so it runs at the
    // call's first real yield of the main thread (or after it, if it never yields).
    private func measure<T>(_ work: () async throws -> T) async throws -> (T, Hold) {
        let stamp = Stamp()
        let monitor = Phase0bMainTurnMonitor()
        let start = Phase0.now()
        DispatchQueue.main.async { stamp.set() }
        monitor.start()
        let result = try await work()
        let wall = Phase0.ms(since: start)
        // Let the main queue drain first: a ping that waited behind the call's LAST hold runs only once the
        // main thread is free, which is after this function resumes, so stopping here would drop that hold.
        // The control above measured exactly that (a 500 ms block read as 0.0 ms) before this drain.
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
        let turns = monitor.stop()
        let stamped = await waitUntil("the first hold's stamp runs", timeout: .seconds(60)) { stamp.value != 0 }
        #expect(stamped, "the main queue never ran the stamp, so the first hold was not measured")
        let first = Double(stamp.value &- start) / 1_000_000
        return (result, Hold(first: first, worst: turns.worst, wall: wall, over100: turns.over100))
    }

    private struct Inputs {
        let dir: URL
        let resultsURL: URL
        let exportURL: URL
        let historyURL: URL
        let results: ScoutExtractResults
    }

    // COPIES of the Release handoff folder's inputs, never the files themselves.
    private func inputs() throws -> Inputs? {
        let handoff = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
        let dir = try sandboxes.make(named: "hold4339-inputs")
        func copied(_ name: String) -> URL {
            let to = dir.appendingPathComponent(name)
            try? FileManager.default.copyItem(at: handoff.appendingPathComponent(name), to: to)
            return to
        }
        let resultsURL = copied("overture-scout-extract-results.json")
        let exportURL = copied("downbeat-export.json")
        let historyURL = copied("overture-history.json")
        guard let data = try? Data(contentsOf: resultsURL),
              let results = try? ScoutExtractResultsDecoder.decode(data) else { return nil }
        return Inputs(dir: dir, resultsURL: resultsURL, exportURL: exportURL, historyURL: historyURL,
                      results: results)
    }

    // Whole table reads inside a run, from whatever thread they run on.
    private final class TableReadLog: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [(onMain: Bool, from: UInt64, to: UInt64)] = []
        func note(onMain: Bool, from: UInt64, to: UInt64) { lock.withLock { all.append((onMain, from, to)) } }
        func text(since start: UInt64) -> String {
            lock.withLock {
                all.isEmpty ? "none" : all.map {
                    String(format: "%@ %.1f to %.1f ms", $0.onMain ? "main" : "off main",
                           Double($0.from &- start) / 1_000_000, Double($0.to &- start) / 1_000_000)
                }.joined(separator: ", ")
            }
        }
    }

    private struct NoFeed: SourceExtractor {
        func extract() async throws -> ExtractedListing { ExtractedListing(events: [], verdict: .noDatedContent) }
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func measureTheFirstHoldOfEveryEntryPoint() async throws {
        guard Self.enabled else {
            print("hold4339: not measured. Set TEST_RUNNER_MEASURE_4339=1 to run it.")
            return
        }
        guard let inputs = try inputs() else {
            Self.say("UNMEASURED: no readable scout extract results on this machine")
            return
        }
        let dir = try sandboxes.make(named: "hold4339-stores")
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        // The instrument's own control: a known 500 ms block on the main thread AFTER the first yield must show
        // as a worst turn of about 500 ms, or the worst turn misses later holds and only the first is real.
        let (_, control) = try await measure { () -> Int in
            await Task.yield()
            let until = Phase0.now() + 500_000_000
            while Phase0.now() < until {}
            return 0
        }
        Self.say("control, a 500 ms block after the first yield: " + control.text)
        for factor in [1, 4] {
            let url = factor == 1 ? base : try Phase0.scaledCopy(of: base, factor: factor, in: dir)
            let container = try Phase0.openContainer(at: url)
            defer { withExtendedLifetime(container) {} }
            let ctx = container.mainContext
            let shows = try ctx.fetchCount(FetchDescriptor<Prospect>())
            let results = Phase0.scaledResults(inputs.results, factor: factor)
            let resultsURL = inputs.dir.appendingPathComponent("results-x\(factor).json")
            try JSONEncoder().encode(results).write(to: resultsURL)
            Self.say("x\(factor): \(shows) shows, \(results.results.count) sources, "
                     + "\(results.results.reduce(0) { $0 + $1.events.count }) events, " + Phase0.load())

            // 0. The members of the first holds, each timed alone on the main thread (median of three), so a
            //    first hold can be attributed and a member under 10 ms can be left where it is.
            func member(_ name: String, _ work: () throws -> Void) rethrows {
                var runs: [Double] = []
                for _ in 0..<3 {
                    let t0 = Phase0.now()
                    try work()
                    runs.append(Phase0.ms(since: t0))
                }
                Self.say(String(format: "x\(factor) member %@: %.1f ms (runs %@)", name, runs.sorted()[1],
                                runs.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
            }
            member("results file read and decode") { _ = LandingInputs.readResultsFile(at: resultsURL) }
            member("Downbeat export load") { _ = DownbeatBridge.loadWithHealth(from: inputs.exportURL, now: Date()) }
            try member("show table read") { _ = try ScoutService.readProspectTable(ctx) }
            let rows = try ScoutService.readProspectTable(ctx)
            member("history from rows and the imported file") {
                _ = LocalHistory.forMatching(existing: rows, importedFrom: inputs.historyURL)
            }
            let export = DownbeatBridge.loadWithHealth(from: inputs.exportURL, now: Date())
            member("blocked calendar") {
                _ = ScoutService.blockedCalendar(export: (export.bookings, export.blockedDates, export.health),
                                                 context: ctx)
            }
            try member("watchlist fetch") { _ = try ctx.fetch(FetchDescriptor<WatchedSource>()) }
            let watchlist = try ctx.fetch(FetchDescriptor<WatchedSource>())
            member("source schedule plan") {
                _ = SourceSchedule.plan(sources: watchlist, depth: .watchOnly, only: nil,
                                        budget: SourceSchedule.unlimitedBudget, now: Date())
            }
            member("landing record sequence read") { _ = try? LandingRun.highestSequence(in: ctx) }

            // 1. The calendar ingest, as RootView.ingestScoutExtract runs it.
            let pending = PendingScoutIngests(directory: try sandboxes.make(named: "hold4339-pending-x\(factor)"))
            let (ingested, ingestHold) = try await measure {
                guard let file = LandingInputs.readResultsFile(at: resultsURL) else { return -1 }
                let read = await LandingInputs.read(exportURL: inputs.exportURL, historyURL: inputs.historyURL,
                                                    into: ctx)
                let landed = await ScoutExtractLanding.land(
                    file.data, file.results, clients: read.clients, history: read.history, blocked: read.blocked,
                    landings: LandingSingleFlight(), pending: pending,
                    // These bytes landed in the live store already, so the clone would refuse them as landed.
                    alreadyLanded: .bypassedForMeasurement, into: ctx)
                return landed.outcome.inserted + landed.outcome.updated
            }
            Self.say("x\(factor) ingest (\(ingested) shows landed): " + ingestHold.text)

            // What the ingest left pending, which runScout's entry flush then saves inside its first hold.
            Self.say("x\(factor) after the ingest: \(ctx.insertedModelsArray.count) inserted, "
                     + "\(ctx.changedModelsArray.count) changed, \(ctx.deletedModelsArray.count) deleted pending")

            // 2. runScout from its first line, with nothing reaching the network.
            // Twice: the second run finds the store as the first left it, so a cost the first run pays once
            // (its flush of what the ingest left, a first use of something) shows as the difference.
            // The scratch defaults the runs are handed are made HERE, outside every measured window, and timed. The
            // first `ScratchDefaults.make` in a test process sweeps `~/Library/Preferences` for files a dead test
            // process left (#3774), and that folder held 72,881 files on 2026-10-04: made inside pass 1's window,
            // as it used to be, that sweep WAS the "first run in a process" cost, about 2.2 s at 1x, and it is the
            // test's own, never the product's (runScout is handed `.standard` by RootView).
            let t00 = Phase0.now()
            let scratchDefaults = ScratchDefaults.make("LandingFirstHoldProbeTests")
            Self.say(String(format: "x\(factor) the test's own scratch defaults made: %.1f ms", Phase0.ms(since: t00)))
            // A suspect for the cost runScout's FIRST run in a process pays: its `session` default argument,
            // `URLSession.shared`, is evaluated on every call and first touched here. Timed once, alone.
            if factor == 1 {
                let t0 = Phase0.now()
                _ = URLSession.shared.configuration
                Self.say(String(format: "x1 first touch of URLSession.shared: %.1f ms", Phase0.ms(since: t0)))
                // The rest of what runScout does on the main thread before its first await, each touched once
                // here first: the LIVE Downbeat export (runScout reads the real one, the members above a copy), and
                // the context's pending state. If one of them is the one-time cost, it shows here and leaves pass 1.
                let t1 = Phase0.now()
                _ = DownbeatBridge.loadWithHealth(now: Date())
                Self.say(String(format: "x1 first live Downbeat export load: %.1f ms", Phase0.ms(since: t1)))
                let t2 = Phase0.now()
                _ = ctx.hasChanges
                Self.say(String(format: "x1 first pending check: %.1f ms", Phase0.ms(since: t2)))
                // `TEST_RUNNER_MEASURE_4339_SETTLE=<seconds>`: leave the main thread idle that long before pass 1, so a
                // cost the ingest leaves running in the background (not runScout's own) finishes before it starts.
                if let settle = ProcessInfo.processInfo.environment["MEASURE_4339_SETTLE"].flatMap(Double.init) {
                    try? await Task.sleep(for: .seconds(settle))
                    Self.say("x1 settled \(settle) s before pass 1")
                }
            }
            // The history read alone, measured as runScout's first hold is, before runScout's first run: if the
            // one-time cost is this read's (its flush, or the first background context's), it shows here and leaves
            // pass 1 below.
            if factor == 1 && ProcessInfo.processInfo.environment["MEASURE_4339_HISTORY_FIRST"] != nil {
                Self.say("x1 before the history read: context has changes \(ctx.hasChanges)")
                let (_, historyHold) = try await measure { await LandingInputs.history(into: ctx) }
                Self.say("x1 history read alone: " + historyHold.text)
            }
            // `TEST_RUNNER_MEASURE_4339_SAMPLE=<dir outside any checkout>`: the first run in this process at 1x is
            // sampled with /usr/bin/sample for twenty seconds (attached five seconds early), so its one-time cost can be read from its stacks.
            var sampler: Process?
            if factor == 1, let out = ProcessInfo.processInfo.environment["MEASURE_4339_SAMPLE"] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                process.arguments = ["\(getpid())", "20", "1", "-mayDie", "-file", out + "/runscout-first-run.sample.txt"]
                try process.run()
                sampler = process
                try? await Task.sleep(for: .seconds(5))   // sample attaches slowly; the run starts once it has
            }
            for pass in 1...2 {
                // Where the run spent its time: a stamp at each tail step, so the tail's own fetches are timed
                // inside the run rather than only alone, and what the run reported about itself.
                var steps: [(String, UInt64)] = []
                // The timeline inside the first hold: every whole table read (which thread, when it started and
                // ended) and each source as the sweep reaches it, so the first hold can be attributed to a step.
                let reads = TableReadLog()
                let pendingBefore = ctx.hasChanges
                let stepStart = Phase0.now()
                let (facts, sweepHold) = try await measure { () -> String in
                    let outcome = try await ScoutService.runScout(
                        into: ctx, depth: .watchOnly, extractor: NoFeed(), extractorRegistry: { _ in nil },
                        fetch: { url, _, _ in
                            FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "hold4339")
                        },
                        pin: { _, id in URL(fileURLWithPath: "/dev/null/hold4339-\(id).html") }, launch: { _ in },
                        defaults: scratchDefaults,
                        onNativeProgress: { _, done, _ in steps.append(("source \(done)", Phase0.now())) },
                        onNativeStep: { steps.append(($0.rawValue, Phase0.now())) },
                        readProspectTable: { context in
                            let t0 = Phase0.now()
                            defer { reads.note(onMain: Thread.isMainThread, from: t0, to: Phase0.now()) }
                            return try ScoutService.readProspectTable(context)
                        },
                        landings: LandingSingleFlight())
                    return "\(outcome.sources.count) sources reported, save failed \(outcome.saveFailed), "
                        + "stop \(outcome.landingStop.map { "\($0)" } ?? "none"), "
                        + "client warning \(outcome.clientListWarning == nil ? "none" : "set")"
                }
                let end = Phase0.now()
                // Every source reached is a mark; only the first, the last and the steps are printed.
                let sourceMarks = steps.filter { $0.0.hasPrefix("source ") }
                let kept = steps.filter { !$0.0.hasPrefix("source ") }
                    + [sourceMarks.first, sourceMarks.last].compactMap { $0 }.map { ("sweep " + $0.0, $0.1) }
                var marks = kept.sorted { $0.1 < $1.1 }.map { ($0.0, Double($0.1 &- stepStart) / 1_000_000) }
                marks.append(("returned", Double(end &- stepStart) / 1_000_000))
                Self.say("x\(factor) runScout pass \(pass): pending before \(pendingBefore); table reads "
                         + reads.text(since: stepStart))
                Self.say("x\(factor) runScout pass \(pass) (\(facts)): " + sweepHold.text + "; steps at "
                         + marks.map { String(format: "%@ %.1f", $0.0, $0.1) }.joined(separator: ", ") + " ms")
            }
            if let sampler {
                sampler.waitUntilExit()
                Self.say("x1 first run sampled (exit \(sampler.terminationStatus)) to MEASURE_4339_SAMPLE")
            }
            // 4. The lead paste, from its entry point, after the runs above: one event, then the largest single
            //    source's events in the results file (a page's size does not grow with the store, so the same
            //    events at both factors). They are already in the clone, so the paste re-lands them, as a paste
            //    of a page Overture already watches does.
            if let largest = inputs.results.results.max(by: { $0.events.count < $1.events.count }) {
                let pageEvents = inputs.results.events(for: largest.sourceId)
                for (label, events) in [("one event", Array(pageEvents.prefix(1))),
                                        ("largest single source", pageEvents)] where !events.isEmpty {
                    let (said, pasteHold) = try await measure { () -> String in
                        let result = await LeadPasteLanding.landPastedLead(
                            events, today: EasternDate.today(Date()), now: Date(), landings: LandingSingleFlight(),
                            loadExport: { DownbeatBridge.loadWithHealth(from: inputs.exportURL, now: Date()) },
                            importedHistory: inputs.historyURL, into: ctx)
                        switch result {
                        case .landed(let outcome):
                            return "landed, \(outcome.inserted) inserted, \(outcome.updated) updated"
                        case .refused: return "REFUSED"
                        }
                    }
                    Self.say("x\(factor) lead paste, \(label) (\(events.count) events, \(said)): " + pasteHold.text)
                }
            } else {
                Self.say("x\(factor) lead paste: UNMEASURED, the results file holds no source")
            }
            // 5. #4512: the landing's `poisonedTokens` term, apart. A sample put most of runScout's landing block
            //    there; this times each part alone on a fresh working set, as a landing meets them: the working set
            //    read, the FIRST call (which builds the batch tables over every stored show), a later call, and
            //    the folds of every show alone. Three fresh working sets, each part's median.
            do {
                var parts: [String: [Double]] = [:]
                var builds = 0
                for _ in 0..<3 {
                    let landing = ScoutLandingStore(context: ctx)
                    var t = Phase0.now()
                    let rows = try landing.rows()
                    parts["working set read", default: []].append(Phase0.ms(since: t))
                    t = Phase0.now()
                    _ = try landing.poisonedTokens(adding: [])
                    parts["first poisonedTokens (builds the tables)", default: []].append(Phase0.ms(since: t))
                    t = Phase0.now()
                    _ = try landing.poisonedTokens(adding: [])
                    parts["a later poisonedTokens", default: []].append(Phase0.ms(since: t))
                    builds = landing.counters.tableBuilds
                    t = Phase0.now()
                    for p in rows { _ = ScoutLandingStore.Fold(p) }
                    parts["the folds of every show alone", default: []].append(Phase0.ms(since: t))
                }
                for (name, runs) in parts.sorted(by: { $0.key < $1.key }) {
                    Self.say(String(format: "x\(factor) poison term, %@: %.1f ms (runs %@)", name, runs.sorted()[1],
                                    runs.map { String(format: "%.1f", $0) }.joined(separator: ", ")))
                }
                Self.say("x\(factor) poison term: \(builds) table build per working set")
            }
            // 3. runScout's tail, its two whole table fetches timed alone on the main thread as the tail meets
            //    them: after a landing, with the store's rows already registered in the context.
            member("tail: booking entities fetch") { _ = DownbeatBooking.bookingEntities(in: ctx) }
            member("tail: blocked town retirement") { _ = ExcludedTownRetirement.run(in: ctx) }
        }
    }
}
