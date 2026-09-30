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
// TEST_RUNNER_MEASURE_4275_ARMS=noview,queue (add `fields` for #4106 Phase 1a's per field write count,
// or `carry,carrysaved` for #4327 step 0.5's pending writes between rounds, with autosave off). A 4x run holds one test for over 20 minutes, so give it
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
// its settle, and the main thread's call tree is written to `<dir>`. The landing starts only once sampling has
// really begun (#4307), never on the sampler's attach line, which can come well before the first sample; each
// round's line says how long after the attach line sampling began. The classifier that reads those files
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
        // #4106 Phase 1a: the Prospect rows the landing's saves carried as UPDATED, counted by identifier.
        var rowsWritten = 0
    }

    private func land(_ inputs: Inputs, into ctx: ModelContext, hosting: NSView?, saves: Phase0SaveLog,
                      sampleSeconds: Int?, sampleFile: URL?, settleDeadline: Int) async throws -> Landing {
        var sampler: LandingSelfSampler?
        if let sampleSeconds, let sampleFile {
            let s = LandingSelfSampler(seconds: sampleSeconds, file: sampleFile)
            // Returns only once the sampler is really SAMPLING, not merely attached (#4307), so the landing
            // below cannot begin in the unsampled gap between the two.
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
        let taken = saves.take()
        let saveCount = taken.count
        var written = Set<PersistentIdentifier>()
        for entry in taken where entry.fromMain {
            for (key, ids) in entry.identifiers where key.lowercased().contains("update") {
                written.formUnion(ids.filter { $0.entityName == "Prospect" })
            }
        }
        var sampled = "not sampled"
        if let sampler {
            // #4307: how long after the attach line sampling really began, which is the head this probe left
            // unsampled while it started the landing on that line.
            let began = sampler.attachToBeganMs.map { "sampling began \(LandingProbe.f1($0)) ms after the attach line" }
                ?? "sampling start UNMEASURED"
            sampled = await sampler.finish()
                ? "sampled for \(sampler.seconds) s to \(sampler.file.lastPathComponent), \(began)"
                : "SAMPLER FAILED: \(sampler.output.prefix(200))"
        }
        var landed = Landing(ingestMs: ingestMs, settleMs: settleMs, derivations: derivations,
                             worst: turns.worst, stalls: turns.stalls, summedStall: turns.summed, outcome: outcome,
                             saves: saveCount, sampled: sampled)
        landed.rowsWritten = written.count
        return landed
    }

    private func describe(_ l: Landing) -> String {
        "ingest \(LandingProbe.f1(l.ingestMs)) ms, settle \(LandingProbe.f1(l.settleMs)) ms, "
            + "largest main wait \(LandingProbe.f1(l.worst)) ms, \(l.stalls) waits of 100 ms or more summing "
            + "\(LandingProbe.f1(l.summedStall)) ms, queue derivations \(l.derivations), saves \(l.saves), "
            + "rows written \(l.rowsWritten), "
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
                if arm == "fields" {
                    try await fieldsArm(inputs, into: ctx, saves: saves, factor: factor,
                                        settleDeadline: settleDeadline)
                    continue
                }
                if arm == "carry" || arm == "carrysaved" {
                    try await carryArm(inputs, into: ctx, saves: saves, factor: factor,
                                       saveBetweenRounds: arm == "carrysaved", settleDeadline: settleDeadline)
                    continue
                }
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
    // #4327 step 0.5: why identical 4x re-lands wrote 819 rows on some rounds and 214 on others. The
    // hypothesis (c) is that the landing's closing FeedReconcile writes (#4325) are left unsaved, so the next
    // round's first save carries them INSIDE its window unless an autosave flushed them between rounds. With
    // autosave OFF the carry cannot be flushed by chance, so it is read directly: whether the context holds
    // changes, and how many Prospect rows are pending, at each round's end and at the next round's start.
    // `carrysaved` is the control the plan names: an explicit save OUTSIDE the window after each round, which
    // must make the carry vanish if (c) is the cause. Counts only (L222).
    private func carryArm(_ inputs: Inputs, into ctx: ModelContext, saves: Phase0SaveLog, factor: Int,
                          saveBetweenRounds: Bool, settleDeadline: Int) async throws {
        let arm = saveBetweenRounds ? "carrysaved" : "carry"
        let wasAutosaving = ctx.autosaveEnabled
        ctx.autosaveEnabled = false
        defer { ctx.autosaveEnabled = wasAutosaving }
        func pending() -> String {
            let prospects = ctx.changedModelsArray.filter { $0 is Prospect }.count
            let sources = ctx.changedModelsArray.filter { $0 is WatchedSource }.count
            return "hasChanges \(ctx.hasChanges), pending Prospect rows \(prospects), pending WatchedSource rows "
                + "\(sources), pending inserts \(ctx.insertedModelsArray.count)"
        }
        for round in 0...LandingProbe.rounds {
            let name = round == 0 ? "warm up" : "round \(round)"
            LandingProbe.say("x\(factor) \(arm) \(name) start: " + pending())
            let l = try await land(inputs, into: ctx, hosting: nil, saves: saves, sampleSeconds: nil,
                                   sampleFile: nil, settleDeadline: settleDeadline)
            LandingProbe.say("x\(factor) \(arm) \(name): saves \(l.saves), rows written \(l.rowsWritten), "
                             + "saveFailed \(l.outcome.saveFailed); end: " + pending())
            if saveBetweenRounds && ctx.hasChanges {
                try ctx.save()
                LandingProbe.say("x\(factor) \(arm) \(name) saved outside the window: " + pending())
            }
        }
    }

    // #4106 Phase 1a: which STORED FIELDS a re-land writes, and which it really changes. Observation is armed
    // on every stored property of every show (`ScopeFields`, held to the schema), one tracking per field so a
    // fire names its field, and a value snapshot before and after says which fires changed anything. Its own
    // arm (`TEST_RUNNER_MEASURE_4275_ARMS=...,fields`) because the observers would perturb the timed arms.
    // Field names and counts only, never a value (L222).
    private func fieldsArm(_ inputs: Inputs, into ctx: ModelContext, saves: Phase0SaveLog, factor: Int,
                           settleDeadline: Int) async throws {
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        let before = Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, phase0Values($0)) })
        let fires = ScoutReLandWritesNothingTests.Fires()
        var seen = Set<ObjectIdentifier>()
        for p in rows {
            ScoutReLandWritesNothingTests.arm(p, label: "\(p.persistentModelID.hashValue)", into: fires,
                                              seen: &seen)
        }
        let l = try await land(inputs, into: ctx, hosting: nil, saves: saves, sampleSeconds: nil, sampleFile: nil,
                               settleDeadline: settleDeadline)
        var byField: [String: Int] = [:]
        for fields in fires.byRow.values { for f in fields { byField[f, default: 0] += 1 } }
        // The same order `phase0Values` lists them in, so a changed position names its field.
        let names = Prospect.scopeFields.map(\.keyPath).filter { $0 != \Prospect.recipients as AnyKeyPath }
            .map(ScoutReLandWritesNothingTests.fieldName)
        var changedByField: [String: Int] = [:]
        var changed = 0
        for p in rows {
            let now = phase0Values(p)
            guard let was = before[p.persistentModelID], was != now else { continue }
            changed += 1
            for (i, name) in names.enumerated() where i < was.count && i < now.count && was[i] != now[i] {
                changedByField[name, default: 0] += 1
            }
        }
        func list(_ d: [String: Int]) -> String { d.keys.sorted().map { "\($0) \(d[$0]!)" }.joined(separator: ", ") }
        LandingProbe.say("x\(factor) fields: " + describe(l) + "; rows firing \(fires.byRow.count), rows really "
                         + "changed \(changed); fired by field: " + list(byField)
                         + "; changed by field: " + list(changedByField) + ", " + Phase0.load())
        withExtendedLifetime(rows) {}
    }

    // #4327 step 0.7 (RC4): the working set's counters PER SOURCE, on a pure re-land and on a landing that
    // INSERTS, so A4 is sized from counts rather than from a reading of `ScoutLandingStore`. OPT IN, with its
    // own switch because it takes no samples and holds no view:
    //
    //   TEST_RUNNER_MEASURE_4275=1 TEST_RUNNER_MEASURE_4327_COUNTERS=1 TEST_RUNNER_MEASURE_4275_SIZES=1,4 \
    //     mac/scripts/run-tests-locked.sh -only-testing:OvertureTests/ScoutLandingAttributionProbeTests
    //
    // Optional: TEST_RUNNER_MEASURE_4327_NEW_SHARE=0.1 (the share of each source's events added as NEW shows).
    //
    // The inserting variant is built HERE, in memory, and never written anywhere: for each source, a stated
    // share of its own events is copied with a synthetic title and a synthetic link, keeping the event's real
    // venue, night and presenter, so every new show lands at a real venue in a real listing. The titles and
    // links carry the round, so a second round inserts again rather than re-landing the first round's rows.
    // Sources are named by their position in the results file, never by id (L222).
    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func workingSetCountersPerSource() async throws {
        guard LandingProbe.enabled, LandingProbe.env["MEASURE_4327_COUNTERS"] != nil else {
            print("probe4327: not measured. Set TEST_RUNNER_MEASURE_4275=1 TEST_RUNNER_MEASURE_4327_COUNTERS=1.")
            return
        }
        let share = Double(LandingProbe.env["MEASURE_4327_NEW_SHARE"] ?? "") ?? 0.1
        let handoff = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
        let inputsDir = try sandboxes.make(named: "probe4327-inputs")
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
            LandingProbe.say("counters UNMEASURED: no readable scout extract results on this machine")
            return
        }
        let dir = try sandboxes.make(named: "probe4327-stores")
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let position = Dictionary(uniqueKeysWithValues: results.results.enumerated().map { ($1.sourceId, $0 + 1) })
        let eventsBySource = Dictionary(uniqueKeysWithValues: results.results.map { ($0.sourceId, $0.events.count) })

        for factor in LandingProbe.sizes {
            let url = factor == 1 ? base : try Phase0.scaledCopy(of: base, factor: factor, in: dir)
            let container = try Phase0.openContainer(at: url)
            defer { withExtendedLifetime(container) {} }
            let ctx = container.mainContext
            let existing = try ctx.fetch(FetchDescriptor<Prospect>())
            let loaded = DownbeatBridge.loadWithHealth(from: exportCopy, now: Date())
            let inputs = Inputs(
                results: results, clients: loaded.clients,
                history: LocalHistory.forMatching(existing: existing, importedFrom: historyCopy),
                blocked: ScoutService.blockedCalendar(export: (loaded.bookings, loaded.blockedDates, loaded.health),
                                                      context: ctx))
            LandingProbe.say("counters x\(factor): \(existing.count) shows, \(results.results.count) sources, "
                             + Phase0.load())
            // Warm up, unreported: the recorded results were already landed once into the live store, and this
            // makes every landing below a RE-LAND of the same file, as the attribution arms are.
            _ = await ScoutExtractIngest.ingest(results, clients: inputs.clients, history: inputs.history,
                                                blocked: inputs.blocked, into: ctx)
            try? ctx.save()

            for (variant, landed) in [("reland", results), ("inserting", Self.inserting(results, share: share,
                                                                                         round: factor))] {
                let wait = Phase0.waitForLoad(below: 8, deadline: 1800, poll: 5)
                var steps: [(String, ScoutLandingStore.Counters, Double)] = []
                let t0 = Phase0.now()
                let outcome = await ScoutExtractIngest.ingest(
                    landed, clients: inputs.clients, history: inputs.history, blocked: inputs.blocked,
                    onLandingStep: { steps.append(($0, $1, Phase0.ms(since: t0))) }, into: ctx)
                let total = Phase0.ms(since: t0)
                try? ctx.save()
                let added = landed.results.reduce(0) { $0 + $1.events.count }
                    - results.results.reduce(0) { $0 + $1.events.count }
                LandingProbe.say("counters x\(factor) \(variant): \(landed.results.count) sources, \(added) synthetic "
                                 + "new-show events added, outcome inserted \(outcome.inserted) updated "
                                 + "\(outcome.updated) skipped \(outcome.skipped), ingest \(LandingProbe.f1(total)) ms; "
                                 + wait.text + ", " + Phase0.load())
                var previous = ScoutLandingStore.Counters()
                var previousMs = 0.0
                // The landing loop begins after the read phase; the first step's time includes that read.
                for (label, counters, ms) in steps {
                    let d = counters - previous
                    let name = label == ScoutLandingStore.Counters.afterReconcile
                        ? "after the reconcile" : "source \(position[label] ?? 0), \(eventsBySource[label] ?? 0) recorded events"
                    LandingProbe.say("counters x\(factor) \(variant) \(name): +\(LandingProbe.f1(ms - previousMs)) ms; "
                                     + d.description)
                    previous = counters
                    previousMs = ms
                }
                LandingProbe.say("counters x\(factor) \(variant) TOTAL: " + previous.description)
            }
        }
    }

    // The inserting variant of a results file: per source, `share` of its events (rounded, at least one where
    // the source has any) copied as new shows at the same venue, night and presenter, with a title and a link
    // no stored show carries. In memory only.
    static func inserting(_ results: ScoutExtractResults, share: Double, round: Int) -> ScoutExtractResults {
        var out = results
        for (s, result) in results.results.enumerated() where !result.events.isEmpty {
            let n = max(1, Int((Double(result.events.count) * share).rounded()))
            let stride = max(1, result.events.count / n)
            var added: [ScoutExtractEvent] = []
            for i in 0..<n {
                var e = result.events[(i * stride) % result.events.count]
                let tag = "\(round)s\(s)e\(i)"
                e.title = "Probe Synthetic Recital \(tag)"
                e.sourceUrl = e.sourceUrl.map { $0 + ($0.hasSuffix("/") ? "" : "/") + "probe4327-\(tag)" }
                e.seriesId = nil
                added.append(e)
            }
            out.results[s].events += added
        }
        return out
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
