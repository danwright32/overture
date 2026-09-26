import Testing
import Foundation
import SwiftData
import SwiftUI
import AppKit

// #4275: where does the main thread's time go while a scout lands?
//
// MEASUREMENT ONLY, on the same contract as #4106's probes beside it (`QueueEnginePhase0bProbeTests`): every
// landing runs against a throwaway `LiveStoreClone` copy of the live store or a `Phase0.scaledCopy` of it,
// and every input file (the scout extract results, the Downbeat export, the imported history) is read from a
// COPY in a sandbox. Nothing in the app changes. OPT IN, and it says it did not run rather than passing:
//
//   TEST_RUNNER_MEASURE_4275=1 TEST_RUNNER_MEASURE_4275_OUT=<dir> mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/ScoutLandingAttributionProbeTests
//
// Optional: TEST_RUNNER_MEASURE_4275_SIZES=1,2,4 (store multiples), TEST_RUNNER_MEASURE_4275_ROUNDS=3,
// TEST_RUNNER_MEASURE_4275_ARMS=noview,queue. A 4x run holds one test for over 20 minutes, so give it
// OVERTURE_TEST_STALL_END_SECONDS=3300 or the runner's stall guard ends it as hung (measured, #4275).
//
// WHAT IT DOES. At each store size it lands the recorded scout extract results through the app's own
// `ScoutExtractIngest.ingest`, with the clients, history and blocked calendar the app builds, in two arms:
//
//   no view        the landing alone, on the main context, nothing observing the store
//   queue hosted   the same landing with a stand-in for RootView (its six `@Query` declarations, verbatim)
//                  presenting the real `QueueView` in an offscreen window, pumped until the queue's
//                  derivation count goes quiet, as the app's run loop would draw it
//
// Each measured landing is SAMPLED: `/usr/bin/sample` is pointed at this test process for the landing and
// its settle, and the main thread's call tree is written to `<dir>`. The classifier that reads those files
// (which app frame owns each sample) is posted on #4275 with the results, not kept in the repository.
// A counter only sees the sites somebody instrumented; a sampler sees every frame the main thread was in.
//
// A warm up landing precedes each arm and is not sampled: the recorded results were already landed into the
// live store once, so every landing here is a RE-LAND, which is what the live free feed sweeps were too (a
// later sweep restamps the same roughly 400 rows).
//
// PRIVACY. Counts, durations and code symbols only: never a show name, a presenter, a venue or a URL (L222).

enum LandingProbe {
    nonisolated static var env: [String: String] { ProcessInfo.processInfo.environment }
    nonisolated static var enabled: Bool { env["MEASURE_4275"] != nil }
    nonisolated static var outDir: URL? { env["MEASURE_4275_OUT"].map { URL(fileURLWithPath: $0) } }
    nonisolated static var sizes: [Int] {
        (env["MEASURE_4275_SIZES"] ?? "1,2,4").split(separator: ",").compactMap { Int($0) }
    }
    nonisolated static var rounds: Int { Int(env["MEASURE_4275_ROUNDS"] ?? "") ?? 3 }
    nonisolated static var arms: [String] {
        (env["MEASURE_4275_ARMS"] ?? "noview,queue").split(separator: ",").map(String.init)
    }
    // Printed AND appended to `<dir>/probe.log`, so a run the stall guard ends still leaves every line it said.
    nonisolated static func say(_ line: String) {
        print("probe4275 " + line)
        guard let dir = outDir else { return }
        let file = dir.appendingPathComponent("probe.log")
        let data = Data(("probe4275 " + line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: file)
        }
    }
    nonisolated static func f1(_ v: Double) -> String { String(format: "%.1f", v) }
}

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

/// Main thread waits measured from off the main thread, as `Phase0bMainTurnMonitor` does, keeping every wait
/// so the stalls can be summed the way the freeze log sums them (every wait of 100 ms or more).
final class LandingStallMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var waits: [Double] = []

    func start() {
        let thread = Thread { [self] in
            while self.isRunning {
                let sem = DispatchSemaphore(value: 0)
                let t0 = Phase0.now()
                DispatchQueue.main.async {
                    self.record(Phase0.ms(since: t0))
                    sem.signal()
                }
                _ = sem.wait(timeout: .now() + 900)
                usleep(1000)
            }
        }
        thread.name = "probe4275-stall-monitor"
        thread.start()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    private func record(_ ms: Double) { lock.lock(); waits.append(ms); lock.unlock() }

    func stop() -> (worst: Double, stalls: Int, summed: Double) {
        lock.lock(); defer { lock.unlock() }
        running = false
        let stalls = waits.filter { $0 >= 100 }
        return (waits.max() ?? 0, stalls.count, stalls.reduce(0, +))
    }
}

// RootView's six `@Query` declarations, verbatim, presenting the real QueueView the way RootView does. A
// STAND IN: RootView's own body derives more than this (the Due counts, the masthead), so the queue hosted
// arm is a floor on what the app's views cost, never a ceiling.
private struct RootQueriesStandIn: View {
    @Query(filter: PrepQueueBuilder.needsPrepPredicate) private var toPrepByStatus: [Prospect]
    @Query private var allProspects: [Prospect]
    @Query private var allInquiries: [Inquiry]
    @Query private var watchedSources: [WatchedSource]
    @Query private var excludedTownRows: [ExcludedTown]
    @Query private var allowedSeedTownRows: [AllowedSeedTown]
    @State private var deepLinkedKey: LeadDeepLink?
    @State private var deepLinkedKeys: LeadsDeepLink?

    var body: some View {
        VStack(spacing: 0) {
            Text("\(toPrepByStatus.count) \(allInquiries.count) \(watchedSources.count) "
                 + "\(excludedTownRows.count) \(allowedSeedTownRows.count)")
            QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys,
                      allProspects: allProspects, onConnectGmail: { })
        }
    }
}

@MainActor
@Suite("Where the main thread goes while a scout lands (#4275)", .serialized, .sharesTheRenderCounter)
struct ScoutLandingAttributionProbeTests {

    private let sandboxes = TemporarySandboxes()

    private struct Inputs {
        let results: ScoutExtractResults
        let clients: [DownbeatClient]
        let history: [HistoryRecord]
        let blocked: BlockedCalendar
    }

    private func host(_ c: ModelContainer) -> (NSWindow, NSHostingView<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(
            RootQueriesStandIn()
                .modelContainer(c)
                .environment(ActionFeedback())
                .environment(DayOffOfferRequest())
                .environment(QueueUndoStack())))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    // Draws until the queue's derivation count has gone quiet (40 polls of 10 ms with nothing new), bounded.
    private func settle(_ hosting: NSView, deadlineSeconds: Int) async -> Int {
        var seen = QueueRenderCounter.derivations
        let start = seen
        var quiet = 0
        let deadline = ContinuousClock.now + .seconds(deadlineSeconds)
        while ContinuousClock.now < deadline {
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            if QueueRenderCounter.derivations > seen {
                seen = QueueRenderCounter.derivations
                quiet = 0
            } else {
                quiet += 1
            }
            if quiet >= 40 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return seen - start
    }

    private struct Landing {
        let ingestMs: Double
        let settleMs: Double
        let derivations: Int
        let worst: Double
        let stalls: Int
        let summedStall: Double
        let outcome: ScoutService.Outcome
        let saves: Int
        let sampled: String
    }

    private func land(_ inputs: Inputs, into ctx: ModelContext, hosting: NSView?, saves: Phase0SaveLog,
                      sampleSeconds: Int?, sampleFile: URL?, settleDeadline: Int) async throws -> Landing {
        var sampler: LandingSelfSampler?
        if let sampleSeconds, let sampleFile {
            let s = LandingSelfSampler(seconds: sampleSeconds, file: sampleFile)
            try await s.start()
            sampler = s
        }
        _ = saves.take()
        let monitor = LandingStallMonitor()
        monitor.start()
        let t0 = Phase0.now()
        let outcome = await ScoutExtractIngest.ingest(inputs.results, clients: inputs.clients,
                                                      history: inputs.history, blocked: inputs.blocked,
                                                      into: ctx)
        let ingestMs = Phase0.ms(since: t0)
        let t1 = Phase0.now()
        var derivations = 0
        if let hosting {
            derivations = await settle(hosting, deadlineSeconds: settleDeadline)
        } else {
            try? await Task.sleep(for: .milliseconds(400))
        }
        let settleMs = Phase0.ms(since: t1)
        let turns = monitor.stop()
        let saveCount = saves.take().count
        var sampled = "not sampled"
        if let sampler {
            sampled = await sampler.finish() ? "sampled for \(sampler.seconds) s to \(sampler.file.lastPathComponent)"
                : "SAMPLER FAILED: \(sampler.output.prefix(200))"
        }
        return Landing(ingestMs: ingestMs, settleMs: settleMs, derivations: derivations, worst: turns.worst,
                       stalls: turns.stalls, summedStall: turns.summed, outcome: outcome, saves: saveCount,
                       sampled: sampled)
    }

    private func describe(_ l: Landing) -> String {
        "ingest \(LandingProbe.f1(l.ingestMs)) ms, settle \(LandingProbe.f1(l.settleMs)) ms, "
            + "largest main wait \(LandingProbe.f1(l.worst)) ms, \(l.stalls) waits of 100 ms or more summing "
            + "\(LandingProbe.f1(l.summedStall)) ms, queue derivations \(l.derivations), saves \(l.saves), "
            + "outcome inserted \(l.outcome.inserted) updated \(l.outcome.updated) skipped \(l.outcome.skipped); "
            + l.sampled
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func scoutLandingMainThreadAttribution() async throws {
        guard LandingProbe.enabled else {
            print("probe4275: not measured. Set TEST_RUNNER_MEASURE_4275=1 to run it.")
            return
        }
        guard let out = LandingProbe.outDir else {
            LandingProbe.say("UNMEASURED: TEST_RUNNER_MEASURE_4275_OUT names no directory for the samples")
            return
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        // Inputs, from COPIES of the Release handoff folder's files, never the files themselves.
        let handoff = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
        let inputsDir = try sandboxes.make(named: "probe4275-inputs")
        func copied(_ name: String) -> URL {
            let to = inputsDir.appendingPathComponent(name)
            try? FileManager.default.copyItem(at: handoff.appendingPathComponent(name), to: to)
            return to
        }
        let resultsCopy = copied("overture-scout-extract-results.json")
        let exportCopy = copied("downbeat-export.json")
        let historyCopy = copied("overture-history.json")
        guard let data = try? Data(contentsOf: resultsCopy),
              let results = try? ScoutExtractResultsDecoder.decode(data) else {
            LandingProbe.say("UNMEASURED: no readable scout extract results on this machine")
            return
        }
        let events = results.results.reduce(0) { $0 + $1.events.count }

        let dir = try sandboxes.make(named: "probe4275-stores")
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        for factor in LandingProbe.sizes {
            let url = factor == 1 ? base : try Phase0.scaledCopy(of: base, factor: factor, in: dir)
            let container = try Phase0.openContainer(at: url)
            defer { withExtendedLifetime(container) {} }
            let ctx = container.mainContext
            let saves = Phase0SaveLog(main: ctx)
            let existing = try ctx.fetch(FetchDescriptor<Prospect>())
            let loaded = DownbeatBridge.loadWithHealth(from: exportCopy, now: Date())
            let inputs = Inputs(
                results: results, clients: loaded.clients,
                history: LocalHistory.forMatching(existing: existing, importedFrom: historyCopy),
                blocked: ScoutService.blockedCalendar(export: (loaded.bookings, loaded.blockedDates, loaded.health),
                                                      context: ctx))
            LandingProbe.say("x\(factor): \(existing.count) shows, \(events) events over \(results.results.count) "
                             + "sources, \(inputs.clients.count) clients, \(inputs.history.count) history records, "
                             + Phase0.load())
            let settleDeadline = 60 * factor + 60

            for arm in LandingProbe.arms {
                var window: NSWindow?
                var hosting: NSView?
                if arm == "queue" {
                    let before = QueueRenderCounter.derivations
                    let (w, h) = host(container)
                    window = w
                    hosting = h
                    _ = await settle(h, deadlineSeconds: settleDeadline)
                    let appeared = QueueRenderCounter.derivations - before
                    LandingProbe.say("x\(factor) queue: appeared with \(appeared) derivations")
                    if appeared == 0 {
                        LandingProbe.say("x\(factor) queue: UNMEASURED, the queue never derived while appearing (L98)")
                    }
                }
                let warm = try await land(inputs, into: ctx, hosting: hosting, saves: saves, sampleSeconds: nil,
                                          sampleFile: nil, settleDeadline: settleDeadline)
                LandingProbe.say("x\(factor) \(arm) warm up: " + describe(warm))
                let seconds = Int(((warm.ingestMs + warm.settleMs) / 1000 * 1.3).rounded(.up)) + 4
                for round in 1...LandingProbe.rounds {
                    let file = out.appendingPathComponent("x\(factor)-\(arm)-r\(round).sample.txt")
                    try? FileManager.default.removeItem(at: file)
                    let l = try await land(inputs, into: ctx, hosting: hosting, saves: saves,
                                           sampleSeconds: seconds, sampleFile: file, settleDeadline: settleDeadline)
                    LandingProbe.say("x\(factor) \(arm) round \(round): " + describe(l) + ", " + Phase0.load())
                }
                window?.close()
                withExtendedLifetime(window) {}
            }
        }
    }
    // The unit the landing's samples are dominated by, timed on its own: one whole-store Prospect fetch on a
    // main context that already holds every row registered (as the landing's context does by then), and the
    // two folds `poisonedTokensForBatch` and `ambiguousURLsForBatch` apply to every stored row. Medians of
    // five, so the sampled share can be checked against fetches times their count.
    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func wholeStoreFetchUnitCost() async throws {
        guard LandingProbe.enabled else {
            print("probe4275: not measured. Set TEST_RUNNER_MEASURE_4275=1 to run it.")
            return
        }
        let dir = try sandboxes.make(named: "probe4275-fetch")
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        for factor in LandingProbe.sizes {
            let url = factor == 1 ? base : try Phase0.scaledCopy(of: base, factor: factor, in: dir)
            let container = try Phase0.openContainer(at: url)
            defer { withExtendedLifetime(container) {} }
            let ctx = container.mainContext
            var rows = try ctx.fetch(FetchDescriptor<Prospect>())
            for r in rows { _ = r.runSourceURLs; _ = r.groupName; _ = r.venue }
            let fetch = Phase0.median5 { rows = (try? ctx.fetch(FetchDescriptor<Prospect>())) ?? [] }
            let folds = Phase0.median5 {
                for p in rows {
                    _ = ShowLink.foldedTitle(p.groupName)
                    _ = ShowLink.foldedVenue(p.venue)
                    _ = ListingURL.foldedSet((p.sourceListingURL.map { [$0] } ?? []) + p.runSourceURLs)
                }
            }
            LandingProbe.say("x\(factor) unit: \(rows.count) shows; one whole-store fetch on a warm main context "
                             + "\(fetch.text); folding title, venue and URLs of every stored row \(folds.text), "
                             + Phase0.load())
        }
    }
}
