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
//   - the lead paste, `LeadIntakeModel.importAll`'s landing, with the largest single source's events from the
//     recorded results and with one event.
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
            for pass in 1...2 {
                let (swept, sweepHold) = try await measure { () -> Int in
                    let outcome = try await ScoutService.runScout(
                        into: ctx, depth: .watchOnly, extractor: NoFeed(), extractorRegistry: { _ in nil },
                        fetch: { url, _, _ in
                            FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString, contentHash: "hold4339")
                        },
                        pin: { _, id in URL(fileURLWithPath: "/dev/null/hold4339-\(id).html") }, launch: { _ in },
                        defaults: ScratchDefaults.make("LandingFirstHoldProbeTests"), landings: LandingSingleFlight())
                    return outcome.sources.count
                }
                Self.say("x\(factor) runScout pass \(pass) (\(swept) sources reported): " + sweepHold.text)
            }
            // 3. runScout's tail, its two whole table fetches timed alone on the main thread as the tail meets
            //    them: after a landing, with the store's rows already registered in the context.
            member("tail: booking entities fetch") { _ = DownbeatBooking.bookingEntities(in: ctx) }
            member("tail: blocked town retirement") { _ = ExcludedTownRetirement.run(in: ctx) }
        }
    }
}
