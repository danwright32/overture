import Testing
import Foundation
import SwiftData
import SwiftUI
import AppKit

// #4343 (E0): the acceptance rig. It measures every scout landing entry point against the 100 ms per main thread
// turn bar Phase E of #4275 judges, and it is the instrument, never the verdict: E0 builds it and proves it
// measures. The bar is NOT claimed here.
//
// MEASUREMENT ONLY, OPT IN, and it says it did not run rather than passing (L98):
//
//   TEST_RUNNER_MEASURE_4343=1 TEST_RUNNER_MEASURE_4343_SIZE=4 OVERTURE_TEST_STALL_END_SECONDS=7200 \
//     mac/scripts/run-tests-locked.sh -only-testing:OvertureTests/LandingAcceptanceRigTests
//
// ONE STORE SIZE PER RUN, and the rig scoped ALONE, both measured rather than chosen. RootView's `@Query`
// observers outlive the view: with a second store opened in the same process the first one's observers were
// still registered, and once that store's sandbox closed it (`FileStores`) the next save ANYWHERE trapped inside
// SwiftData's SwiftUI integration (the #3874 shape, measured 2026-10-06 on this rig's first two runs, which
// ended the test process in the next entry point and in the next suite). So a run mounts ONE RootView on ONE
// store, measures every entry point on it in turn, and nothing that saves may run after it in the process.
// 1x and 4x are two runs.
//
// Optional: TEST_RUNNER_MEASURE_4343_SIZE=1 (the store multiple, 1 by default), TEST_RUNNER_MEASURE_4343_ENTRIES=
// runScout,calendarIngest,offerPending,recovery,leadPaste (all by default), TEST_RUNNER_MEASURE_4343_SAMPLES=5,
// TEST_RUNNER_MEASURE_4343_VARIANTS=reland,inserting, TEST_RUNNER_MEASURE_4343_LOAD_WAIT=60 (seconds a sample
// waits for the one minute load to fall under 8 before it is taken anyway and judged), and
// TEST_RUNNER_MEASURE_4343_OUT=<dir outside any checkout>, where every line is also appended to rig.log, so a run
// the stall guard ends still leaves what it said.
// Release-like (Release's optimiser, DEBUG compiled out): OVERTURE_TEST_RELEASE_LIKE=1 on the same command.
//
// WHAT IT MEASURES, per entry point, per store size, per variant: the LARGEST SINGLE MAIN THREAD HOLD over the
// whole landing window, from the entry point's own first line through its first hold (A11), the landing's turns,
// its tail and closing save, and the end publish and the redraw it causes in RootView's REAL body, mounted on the
// same container in an offscreen window and drawn until it goes quiet (L63). A hold is the time a ping posted to
// the main queue from another thread waited for it (`HoldTimeline`), so every turn is seen whoever runs it. Each
// hold is attributed to a TERM by when its ping was posted: before the main thread first yielded (the first
// hold), before the entry point returned (the landing: its turns, its tail and its saves together; separating
// those needs a marker inside the landing, which is the landing split's, #4341), or after (the redraw).
//
// The entry points are the ones `LandingEntryPointsAreDerivedTests` derives from the source, and each is driven
// the way its view caller drives it (`carried`). Five samples each after an unmeasured warm up, the median of
// those taken with the one minute load under 8; a sample above it is kept in the report as a raw reading and
// never counted, and a cell with none under it is UNMEASURED, never red (L224, L411). Load is printed beside
// every sample (L356). Between rounds anything the landing left pending is saved outside the window (0.5).
//
// INPUTS. A throwaway `LiveStoreClone` copy of the live store and its fourfold copy (`Phase0.scaledCopy`), never
// the live store, and COPIES of the handoff inputs. `pure re-land` lands the recorded scout extract results the
// clone already holds; `inserting` adds a tenth of each source's events as new shows (`Phase0.insertingResults`).
// The A7 check would refuse the same results every round after the first, so the entry points that make it are
// handed the measurement seam (`AlreadyLandedCheck.bypassedForMeasurement`, the 2026-09-29 decision on #4343),
// after a POSITIVE CONTROL with the real check refusing a second landing of the same file (L159). Every report
// says the seam was used. Nothing reaches the network: runScout's pages, feeds, pins and launch are stubs.
//
// PRIVACY. Counts and milliseconds only, never a show, a venue, a person or a URL (L222).

enum LandingAcceptanceRig {

    // Every entry point into a scout landing the source has, with the function the rig drives and the view
    // functions that drive it in the app. `LandingEntryPointsAreDerivedTests` fails when this differs from the
    // derivation either way, so a new way into a landing cannot go unmeasured.
    enum Entry: String, CaseIterable, Sendable {
        case runScout, calendarIngest, offerPending, recovery, leadPaste
    }

    struct Carried {
        let entry: Entry
        let top: String
        let viewCallers: Set<String>
        // Whether the landing makes the A7 already-landed check, and so needs the seam to re-land one file.
        let usesTheCheck: Bool
    }

    static let carried: [Carried] = [
        Carried(entry: .runScout, top: "ScoutService.runScout", viewCallers: ["RootView.runScout"],
                usesTheCheck: false),
        Carried(entry: .calendarIngest, top: "ScoutExtractLanding.land", viewCallers: ["RootView.ingestScoutExtract"],
                usesTheCheck: true),
        Carried(entry: .offerPending, top: "ScoutExtractLanding.offerPending",
                viewCallers: ["RootView.offerPendingScoutIngests"], usesTheCheck: true),
        Carried(entry: .recovery, top: "LandingRecovery.recoverNext",
                viewCallers: ["RootView.recoverAnInterruptedLandingIfIdle"], usesTheCheck: true),
        Carried(entry: .leadPaste, top: "LeadPasteLanding.landPastedLead", viewCallers: ["LeadIntakeModel.importAll"],
                usesTheCheck: false),
    ]

    enum Variant: String, CaseIterable, Sendable {
        case reland, inserting
        var label: String { self == .reland ? "pure re-land" : "inserting" }
    }

    static let bar = 100.0
    // The share of each source's events an inserting round adds as new shows, and the tag its links carry, for
    // both inserting paths (the results file and the native feeds), which share `Phase0.insertedCopies`.
    static let insertedShare = 0.1
    static let linkTag = "rig4343"
    static let loadCeiling = 8.0

    // MARK: - Options

    nonisolated static var env: [String: String] { ProcessInfo.processInfo.environment }
    nonisolated static var enabled: Bool { env["MEASURE_4343"] != nil }
    nonisolated static var size: Int { max(1, Int(env["MEASURE_4343_SIZE"] ?? "") ?? 1) }
    nonisolated static var entries: [Entry] {
        guard let named = env["MEASURE_4343_ENTRIES"] else { return Entry.allCases }
        return named.split(separator: ",").compactMap { Entry(rawValue: String($0)) }
    }
    nonisolated static var samples: Int { max(1, Int(env["MEASURE_4343_SAMPLES"] ?? "") ?? 5) }
    nonisolated static var variants: [Variant] {
        (env["MEASURE_4343_VARIANTS"] ?? "reland,inserting").split(separator: ",").compactMap { Variant(rawValue: String($0)) }
    }
    nonisolated static var loadWait: Double { Double(env["MEASURE_4343_LOAD_WAIT"] ?? "") ?? 60 }
    nonisolated static var outDir: URL? { env["MEASURE_4343_OUT"].map { URL(fileURLWithPath: $0) } }

    nonisolated static func say(_ line: String) {
        print("rig4343 " + line)
        fflush(stdout)
        guard let dir = outDir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("rig.log")
        let data = Data(("rig4343 " + line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: file) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            try? data.write(to: file)
        }
    }

    nonisolated static func f1(_ v: Double) -> String { String(format: "%.1f", v) }

    // MARK: - The build this reading is from

    nonisolated static var debugCompiledIn: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    nonisolated static var releaseLikeMarkerCompiledIn: Bool {
        #if OVERTURE_RELEASE_LIKE
        return true
        #else
        return false
        #endif
    }

    // What the build says about itself, from inside the compiled code (L416), and a refusal when the run was
    // ASKED to be release-like (the runner says so, L319) and the code it finds itself in is not.
    nonisolated static func build(askedFor mode: String?, debugCompiledIn: Bool, optimised: Bool,
                                  markerCompiledIn: Bool) -> (line: String, refusal: String?) {
        let line = "build: DEBUG compiled out: \(debugCompiledIn ? "no" : "yes"), optimised: \(optimised ? "yes" : "no"), "
            + "release-like marker: \(markerCompiledIn ? "yes" : "no"), asked for: \(mode ?? "an ordinary Debug run")"
        guard mode == "release-like" else { return (line, nil) }
        if debugCompiledIn || !optimised || !markerCompiledIn {
            return (line, "UNMEASURED: this run was asked to be release-like and the code it is running is not "
                    + "(DEBUG compiled in \(debugCompiledIn), optimised \(optimised), marker \(markerCompiledIn)), so no "
                    + "reading from it is a release-like one")
        }
        return (line, nil)
    }

    // MARK: - Samples and their summary

    enum Term: String, Sendable { case firstHold = "first hold", landing = "landing", redraw = "redraw" }

    struct Ping: Sendable {
        let posted: UInt64
        let ran: UInt64
    }

    struct Window: Sendable {
        let start: UInt64
        let firstYield: UInt64
        let returned: UInt64
        let end: UInt64
    }

    struct Holds: Equatable, Sendable {
        var worst = 0.0
        var worstTerm = Term.firstHold
        var firstHold = 0.0
        var landing = 0.0
        var redraw = 0.0
        var over100 = 0
    }

    // Every hold inside the window, by the term its ping was posted in. A ping posted before the window opened
    // and run inside it counts from the window's start, so the window measures only itself.
    nonisolated static func holds(_ pings: [Ping], in w: Window) -> Holds {
        var out = Holds()
        out.firstHold = Double(w.firstYield &- w.start) / 1_000_000
        out.worst = out.firstHold
        out.worstTerm = .firstHold
        if out.firstHold > bar { out.over100 += 1 }
        for p in pings where p.ran >= w.start && p.ran <= w.end {
            let ms = Double(p.ran &- max(p.posted, w.start)) / 1_000_000
            let term: Term = p.posted < w.firstYield ? .firstHold : p.posted < w.returned ? .landing : .redraw
            switch term {
            case .firstHold: out.firstHold = max(out.firstHold, ms)
            case .landing: out.landing = max(out.landing, ms)
            case .redraw: out.redraw = max(out.redraw, ms)
            }
            // The first hold is counted once, above, from the stamp; a ping inside it repeats it.
            if term != .firstHold, ms > bar { out.over100 += 1 }
            if ms > out.worst {
                out.worst = ms
                out.worstTerm = term
            }
        }
        return out
    }

    struct Sample: Sendable {
        let holds: Holds
        let wallMs: Double
        let settleMs: Double
        let settled: Bool
        let loadStart: Double
        let loadEnd: Double
        let said: String
        var load: Double { max(loadStart, loadEnd) }
        var kept: Bool { load < LandingAcceptanceRig.loadCeiling }
    }

    struct Cell: Sendable {
        let kept: [Sample]
        let discarded: [Sample]
        var medianWorst: Double? {
            guard !kept.isEmpty else { return nil }
            let sorted = kept.map(\.holds.worst).sorted()
            return sorted[sorted.count / 2]
        }
        // The term of the sample with the largest hold, among those counted, or among all when none were.
        var worstTerm: Term? { (kept.isEmpty ? discarded : kept).max { $0.holds.worst < $1.holds.worst }?.holds.worstTerm }
    }

    nonisolated static func cell(_ samples: [Sample]) -> Cell {
        Cell(kept: samples.filter(\.kept), discarded: samples.filter { !$0.kept })
    }

    nonisolated static func describe(_ s: Sample) -> String {
        "worst \(f1(s.holds.worst)) ms (\(s.holds.worstTerm.rawValue)); first hold \(f1(s.holds.firstHold)), landing "
            + "\(f1(s.holds.landing)), redraw \(f1(s.holds.redraw)) ms; \(s.holds.over100) over 100 ms; wall "
            + "\(f1(s.wallMs)) ms; redraw settled \(s.settled ? "in" : "NOT in") \(f1(s.settleMs)) ms; load "
            + String(format: "%.2f to %.2f", s.loadStart, s.loadEnd) + (s.kept ? "" : " DISCARDED (load 8 or over)")
            + "; \(s.said)"
    }

    // One table row: entry, size, variant, then the verdict on this cell.
    nonisolated static func row(_ entry: Entry, _ factor: Int, _ variant: Variant, _ c: Cell) -> String {
        let reading: String
        if let median = c.medianWorst {
            let all = c.kept.map(\.holds.worst).sorted()
            reading = "\(f1(median)) ms median of \(c.kept.count) (\(f1(all.first!)) to \(f1(all.last!))), worst term "
                + (c.worstTerm?.rawValue ?? "none") + (median >= bar ? ", OVER the bar by \(f1(median - bar)) ms" : ", under the bar")
        } else {
            reading = "UNMEASURED, no sample under load 8"
        }
        let raw = c.discarded.isEmpty ? "none" : c.discarded.map { "\(f1($0.holds.worst)) ms at load " + String(format: "%.1f", $0.load) }
            .joined(separator: ", ")
        return "| \(entry.rawValue) | \(factor)x | \(variant.label) | \(reading) | discarded: \(raw) |"
    }
}

// Main thread holds, timed from OFF the main thread: a dedicated thread posts a block to the main queue, waits for
// it to run (bounded, L110), and keeps when it was posted and when it ran.
final class HoldTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var pings: [LandingAcceptanceRig.Ping] = []
    private var abandoned = 0

    func start() {
        let thread = Thread { [self] in
            while self.isRunning {
                let sem = DispatchSemaphore(value: 0)
                let posted = Phase0.now()
                DispatchQueue.main.async {
                    self.record(LandingAcceptanceRig.Ping(posted: posted, ran: Phase0.now()))
                    sem.signal()
                }
                if sem.wait(timeout: .now() + 600) == .timedOut { self.markAbandoned() }
                usleep(1000)
            }
        }
        thread.name = "rig4343-hold-timeline"
        thread.start()
    }

    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    private func record(_ p: LandingAcceptanceRig.Ping) { lock.lock(); pings.append(p); lock.unlock() }
    private func markAbandoned() { lock.lock(); abandoned += 1; lock.unlock() }

    // The longest hold among pings that ran at or after `since`, in milliseconds.
    func longest(since: UInt64) -> Double {
        lock.lock(); defer { lock.unlock() }
        return pings.reversed().prefix { $0.ran >= since }.map { Double($0.ran &- $0.posted) / 1_000_000 }.max() ?? 0
    }

    func stop() -> (pings: [LandingAcceptanceRig.Ping], abandoned: Int) {
        lock.lock(); defer { lock.unlock() }
        running = false
        return (pings, abandoned)
    }
}

private final class FirstYield: @unchecked Sendable {
    private let lock = NSLock()
    private var at: UInt64 = 0
    func set() { lock.withLock { if at == 0 { at = Phase0.now() } } }
    var value: UInt64 { lock.withLock { at } }
}

// A native feed that lists what it is handed, as runScout's stub for a source with its own extractor.
private struct ReplayFeed: SourceExtractor {
    let events: [ExtractedEvent]
    func extract() async throws -> ExtractedListing {
        ExtractedListing(events: events, verdict: events.isEmpty ? .noDatedContent : .upcomingListings)
    }
}

@MainActor
@Suite("#4343 E0 the scout landing acceptance rig (opt in, live store clone)", .serialized, .sharesTheRenderCounter)
final class LandingAcceptanceRigTests {

    private let sandboxes = TemporarySandboxes()
    private typealias Rig = LandingAcceptanceRig

    // One store size's world: the clone, RootView mounted on it, the inputs, and the landing's own folders.
    @MainActor
    private final class World {
        let factor: Int
        let container: ModelContainer
        let ctx: ModelContext
        let dir: URL
        let exportURL: URL
        let historyURL: URL
        let scaled: ScoutExtractResults
        let relandData: Data
        let flight = LandingSingleFlight()
        let pending: PendingScoutIngests
        let journals: LandingJournals
        let window: NSWindow
        let hosting: NSHostingView<AnyView>?
        var round = 0
        init(factor: Int, container: ModelContainer, dir: URL, exportURL: URL, historyURL: URL,
             scaled: ScoutExtractResults, relandData: Data, pending: PendingScoutIngests, journals: LandingJournals,
             window: NSWindow, hosting: NSHostingView<AnyView>?) {
            self.factor = factor
            self.container = container
            self.ctx = container.mainContext
            self.dir = dir
            self.exportURL = exportURL
            self.historyURL = historyURL
            self.scaled = scaled
            self.relandData = relandData
            self.pending = pending
            self.journals = journals
            self.window = window
            self.hosting = hosting
        }
    }

    // MARK: - Drawing

    // Draws until 40 polls of 10 ms in a row each found nothing to lay out or display (a pump under 2 ms) and saw
    // no main thread hold of 16 ms or more, bounded. No render counter: it is Debug only, and the settle has to be
    // the same rule in both builds or their readings are not comparable.
    private func settle(_ world: World, timeline: HoldTimeline?, deadline: Duration) async -> (ms: Double, settled: Bool) {
        let start = Phase0.now()
        guard let hosting = world.hosting else { return (0, true) }
        var quiet = 0
        var lastPoll = Phase0.now()
        let end = ContinuousClock.now + deadline
        while ContinuousClock.now < end {
            let t0 = Phase0.now()
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            let pump = Phase0.ms(since: t0)
            let held = timeline?.longest(since: lastPoll) ?? 0
            lastPoll = Phase0.now()
            quiet = pump < 2 && held < 16 ? quiet + 1 : 0
            if quiet >= 40 { return (Phase0.ms(since: start), true) }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return (Phase0.ms(since: start), false)
    }

    private func drainMain() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { done.resume() }
        }
    }

    // MARK: - One sample

    private func measure(_ world: World, _ work: () async throws -> String) async throws -> Rig.Sample {
        _ = Phase0.waitForLoad(below: Rig.loadCeiling, deadline: Rig.loadWait, poll: 5)
        let loadStart = Phase0.oneMinuteLoad()
        let timeline = HoldTimeline()
        timeline.start()
        await drainMain()
        let stamp = FirstYield()
        let start = Phase0.now()
        DispatchQueue.main.async { stamp.set() }
        let said = try await work()
        let returned = Phase0.now()
        let drawn = await settle(world, timeline: timeline, deadline: .seconds(60 * world.factor + 60))
        // A ping that waited behind the last hold runs only once the main thread is free, after this resumes, so
        // stopping before the drain would drop that hold (A11 measured exactly that).
        await drainMain()
        let end = Phase0.now()
        let (pings, _) = timeline.stop()
        let stamped = await waitUntil("the first yield's stamp runs", timeout: .seconds(60)) { stamp.value != 0 }
        #expect(stamped, "the main queue never ran the stamp, so the first hold was not measured")
        let firstYield = stamped ? stamp.value : returned
        let holds = Rig.holds(pings, in: Rig.Window(start: start, firstYield: firstYield, returned: returned, end: end))
        return Rig.Sample(holds: holds, wallMs: Double(returned &- start) / 1_000_000, settleMs: drawn.ms,
                          settled: drawn.settled, loadStart: loadStart, loadEnd: Phase0.oneMinuteLoad(), said: said)
    }

    // Saves, OUTSIDE every window, whatever a landing left pending, so no round inherits another's (0.5).
    private func flush(_ world: World) throws -> String {
        guard world.ctx.hasChanges else { return "nothing pending" }
        let n = world.ctx.insertedModelsArray.count + world.ctx.changedModelsArray.count + world.ctx.deletedModelsArray.count
        try Phase0.save(world.ctx, step: "rig4343 between rounds")
        return "\(n) pending rows saved outside the window"
    }

    // The shows an inserting round added, removed again OUTSIDE the window, so every round and every entry point
    // lands on the store size it is reported at (0.5's reset). Measured before this existed (2026-10-06, 1x): the
    // inserting rounds of the earlier entry points had grown the store from 1,385 shows to 2,144 by the lead paste.
    // Found by the title every inserting round gives them (`Phase0.syntheticTitle`, written by
    // `Phase0.insertedCopies`, the one rule both inserting paths use), which no real show carries.
    private func removeInserted(_ world: World) async throws -> String {
        let synthetic = try world.ctx.fetch(FetchDescriptor<Prospect>()).filter {
            $0.groupName.contains(Phase0.syntheticTitle)
        }
        guard !synthetic.isEmpty else { return "no inserted shows to remove" }
        for p in synthetic { world.ctx.delete(p) }
        try Phase0.save(world.ctx, step: "rig4343 removing an inserting round's shows")
        _ = await settle(world, timeline: nil, deadline: .seconds(60 * world.factor + 60))
        return "\(synthetic.count) inserted shows removed outside the window"
    }

    // MARK: - The world

    private func makeWorld(factor: Int, base: URL, storesDir: URL, inputs: (dir: URL, results: ScoutExtractResults,
                           exportURL: URL, historyURL: URL)) async throws -> World {
        let url = factor == 1 ? base : try Phase0.scaledCopy(of: base, factor: factor, in: storesDir)
        let container = try Phase0.openContainer(at: url)
        let scaled = Phase0.scaledResults(inputs.results, factor: factor)
        let folders = try sandboxes.make(named: "rig4343-folders-x\(factor)")
        let pending = PendingScoutIngests(directory: folders.appendingPathComponent("pending"),
                                          readFailures: HandoffReadFailures())
        let journals = LandingJournals(directory: folders.appendingPathComponent("journals"),
                                       readFailures: HandoffReadFailures())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        // #3480: AppKit's default releases a window this scope still holds.
        window.isReleasedWhenClosed = false
        var hosting: NSHostingView<AnyView>?
        if ScreenSession.isLocked {
            ScreenSession.reportUnmeasured("LandingAcceptanceRigTests redraw term at \(factor)x")
        } else {
            // Behind `AnyView` only so `close` can unmount it (below); the view drawn is RootView's real body.
            let view = NSHostingView(rootView: AnyView(RootHarness(container: container)))
            view.frame = window.contentLayoutRect
            view.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(view)
            window.layoutIfNeeded()
            hosting = view
        }
        let relandData = try JSONEncoder().encode(scaled)
        let world = World(factor: factor, container: container, dir: inputs.dir, exportURL: inputs.exportURL,
                          historyURL: inputs.historyURL, scaled: scaled, relandData: relandData,
                          pending: pending, journals: journals, window: window, hosting: hosting)
        let appeared = await settle(world, timeline: nil, deadline: .seconds(120 * factor))
        #if DEBUG
        let rendered = QueueRenderCounter.renderCount(for: QueueRenderCounter.rootSurface)
        Rig.say("x\(factor): RootView mounted, \(rendered) root renders so far, settled \(appeared.settled) in "
                + "\(Rig.f1(appeared.ms)) ms")
        #expect(hosting == nil || rendered > 0, "RootView never rendered, so the redraw term would measure nothing")
        #else
        Rig.say("x\(factor): RootView mounted, settled \(appeared.settled) in \(Rig.f1(appeared.ms)) ms (no render "
                + "counter in this build to confirm it drew)")
        #endif
        return world
    }

    // RootView is UNMOUNTED before its container can go, and given turns to finish going. Measured on the first
    // smoke run (2026-10-05): with the window merely closed, the next test's RootView wrote its due counts to
    // UserDefaults, the closed one's `@AppStorage` re-evaluated its body over shows whose container had been
    // released, and SwiftData ended the process ("This model instance was destroyed by calling
    // ModelContext.reset"). A RootView left mounted would also redraw on the next world's changes and be
    // counted in its redraw term.
    private func close(_ world: World) async {
        // Off, and nothing left pending, BEFORE the window goes: the #3874 crash is an autosave firing into a
        // SwiftUI observer after the test that armed it has ended.
        world.ctx.autosaveEnabled = false
        if world.ctx.hasChanges { try? Phase0.save(world.ctx, step: "rig4343 close") }
        if let hosting = world.hosting {
            hosting.rootView = AnyView(EmptyView())
            hosting.layoutSubtreeIfNeeded()
            hosting.displayIfNeeded()
            hosting.removeFromSuperview()
        }
        world.window.close()
        // Its tasks are cancelled and its observers removed on turns after the unmount, so they get those turns.
        for _ in 0..<10 {
            await drainMain()
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - Inputs

    private func copiedInputs() throws -> (dir: URL, results: ScoutExtractResults, exportURL: URL, historyURL: URL)? {
        let handoff = StoreLocation.handoffDirectory(appSupport: StoreLocation.appSupport, isDebugBuild: false)
        let dir = try sandboxes.make(named: "rig4343-inputs")
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
        return (dir, results, exportURL, historyURL)
    }

    // MARK: - Describing what a landing did (counts only)

    private static func said(_ o: ScoutService.Outcome) -> String {
        var parts = ["inserted \(o.inserted)", "updated \(o.updated)", "skipped \(o.skipped)"]
        if o.saveFailed { parts.append("SAVE FAILED") }
        if let stop = o.landingStop { parts.append("STOPPED \(stop)") }
        if o.alreadyLandedAt != nil { parts.append("ALREADY LANDED") }
        if o.notLandedYet != nil { parts.append("NOT LANDED YET") }
        return parts.joined(separator: ", ")
    }

    // MARK: - The entry points, each driven the way its view caller drives it

    // The sequence a kept copy or an interrupted landing is recorded under: above everything this store, its
    // folders and its queue have handed out, as a real one would be.
    private func nextSequence(_ world: World) throws -> Int {
        let sources = try world.ctx.fetch(FetchDescriptor<WatchedSource>())
        return world.flight.mintSequence(above: max((try? LandingRun.highestSequence(in: world.ctx)) ?? 0,
                                                    sources.map(\.lastTouchedSequence).max() ?? 0,
                                                    world.pending.highestSequence, world.journals.highestSequence))
    }

    private func results(_ variant: Rig.Variant, _ world: World) -> (data: Data, results: ScoutExtractResults)? {
        switch variant {
        case .reland: return (world.relandData, world.scaled)
        case .inserting:
            world.round += 1
            let inserting = Phase0.insertingResults(world.scaled, share: Rig.insertedShare,
                                                    round: world.factor * 10_000 + world.round, linkTag: Rig.linkTag)
            guard let data = try? JSONEncoder().encode(inserting) else { return nil }
            return (data, inserting)
        }
    }

    // RootView.ingestScoutExtract's body: the read phase, the landing, and the sweep of kept copies it ends with,
    // which on the ordinary day lists an empty folder.
    private func ingest(_ world: World, file url: URL, alreadyLanded: AlreadyLandedCheck) async -> String {
        guard let file = LandingInputs.readResultsFile(at: url) else { return "results file UNREADABLE" }
        let read = await LandingInputs.read(exportURL: world.exportURL, historyURL: world.historyURL, into: world.ctx)
        let landed = await ScoutExtractLanding.land(
            file.data, file.results, clients: read.clients, history: read.history, blocked: read.blocked,
            landings: world.flight, pending: world.pending, alreadyLanded: alreadyLanded, journals: world.journals,
            into: world.ctx)
        var out = Self.said(landed.outcome)
        if !((try? world.pending.list()) ?? []).isEmpty {
            out += "; then " + (await offer(world, alreadyLanded: alreadyLanded))
        }
        return out
    }

    // RootView.offerPendingScoutIngests' body.
    private func offer(_ world: World, alreadyLanded: AlreadyLandedCheck) async -> String {
        guard !((try? world.pending.list()) ?? []).isEmpty else { return "nothing kept" }
        let read = await LandingInputs.read(exportURL: world.exportURL, historyURL: world.historyURL, into: world.ctx)
        let offered = await ScoutExtractLanding.offerPending(
            clients: read.clients, history: read.history, blocked: read.blocked, landings: world.flight,
            pending: world.pending, alreadyLanded: alreadyLanded, journals: world.journals, into: world.ctx)
        return "kept copies landed \(offered.landed.count) (" + offered.landed.map(Self.said).joined(separator: "; ")
            + "), already landed \(offered.alreadyLanded.count), waiting \(offered.stillWaiting), stuck \(offered.stuck)"
    }

    // RootView.recoverAnInterruptedLandingIfIdle's body, from the survey on (the idle judgement is the caller's).
    private func recover(_ world: World) async throws -> String {
        let ctx = world.ctx
        let found = try LandingRecovery.survey(journals: world.journals, pending: world.pending, in: ctx)
        let actionable = found.filter { if case .stoppedRetrying = $0.finding { return false }; return true }
        guard !actionable.isEmpty else { return "nothing to recover" }
        let replays = actionable.contains { $0.finding == .replay }
        let loaded = replays ? DownbeatBridge.loadWithHealth(from: world.exportURL, now: Date()) : nil
        var existing: [Prospect] = []
        if replays, let waiting = actionable.first(where: { $0.finding == .replay }) {
            switch LandingRecovery.showsForReplay(waiting, fetch: { try ctx.fetch(FetchDescriptor<Prospect>()) }) {
            case .read(let shows): existing = shows
            case .refused: return "the show table could not be read"
            }
        }
        let recovered = await LandingRecovery.recoverNext(
            journals: world.journals, pending: world.pending, clients: loaded?.clients ?? [],
            history: replays ? LocalHistory.forMatching(existing: existing, importedFrom: world.historyURL) : [],
            blocked: loaded.map { ScoutService.blockedCalendar(export: ($0.bookings, $0.blockedDates, $0.health),
                                                               context: ctx) } ?? .empty,
            landings: world.flight, sweep: { false }, alreadyLanded: .bypassedForMeasurement, surveyed: found,
            into: ctx)
        return recovered.map { "\($0)" } ?? "nothing pending"
    }

    // The work one round measures, prepared outside the window. nil when the round cannot be prepared.
    private func prepare(_ entry: Rig.Entry, _ variant: Rig.Variant, _ world: World,
                         runScoutStubs: RunScoutStubs?) throws -> (() async throws -> String)? {
        switch entry {
        case .calendarIngest:
            guard let r = results(variant, world) else { return nil }
            let url = world.dir.appendingPathComponent("rig4343-x\(world.factor)-\(variant.rawValue)-\(world.round).json")
            try r.data.write(to: url)
            return { await self.ingest(world, file: url, alreadyLanded: .bypassedForMeasurement) }
        case .offerPending:
            guard let r = results(variant, world) else { return nil }
            _ = try world.pending.record(r.data, sequence: try nextSequence(world), now: Date())
            return { await self.offer(world, alreadyLanded: .bypassedForMeasurement) }
        case .recovery:
            guard let r = results(variant, world) else { return nil }
            let hash = PendingScoutIngests.contentHash(of: r.data)
            let sequence = try nextSequence(world)
            _ = try world.pending.record(r.data, sequence: sequence, now: Date())
            _ = try world.journals.start(LandingJournal(
                runIdentity: hash, sequence: sequence, entryPoint: .scoutExtractIngest,
                sources: r.results.results.map { .init(sourceId: $0.sourceId, pageHash: nil) }, now: Date(),
                resultsCopy: hash))
            return { try await self.recover(world) }
        case .leadPaste:
            guard let r = results(variant, world),
                  let largest = r.results.results.max(by: { $0.events.count < $1.events.count }) else { return nil }
            let events = r.results.events(for: largest.sourceId)
            let exportURL = world.exportURL
            return {
                let result = await LeadPasteLanding.landPastedLead(
                    events, today: EasternDate.today(Date()), now: Date(), landings: world.flight,
                    loadExport: { DownbeatBridge.loadWithHealth(from: exportURL, now: Date()) },
                    importedHistory: world.historyURL, into: world.ctx)
                switch result {
                case .landed(let outcome): return "\(events.count) events pasted, " + Self.said(outcome)
                case .refused: return "REFUSED"
                }
            }
        case .runScout:
            guard let stubs = runScoutStubs else { return nil }
            var round = stubs.feeds
            if variant == .inserting {
                world.round += 1
                round = stubs.inserting(round: world.factor * 10_000 + world.round)
            }
            let feeds = round
            let hashes = stubs.hashes
            let defaults = stubs.defaults
            return {
                let outcome = try await ScoutService.runScout(
                    into: world.ctx, depth: .readChanged, extractor: ReplayFeed(events: []),
                    extractorRegistry: { source -> (any SourceExtractor)? in
                        guard let source, let feed = feeds[source.sourceId] else { return nil }
                        return feed
                    },
                    fetch: { url, _, _ in
                        FetchedPage(normalizedHTML: "<p/>", finalURL: url.absoluteString,
                                    contentHash: hashes[url.absoluteString] ?? "rig4343")
                    },
                    pin: { _, id in URL(fileURLWithPath: "/dev/null/rig4343-\(id).html") }, launch: { _ in },
                    defaults: defaults, landings: world.flight, sequenceFloor: { world.pending.highestSequence },
                    squarespaceProbe: { _ in nil }, journals: world.journals)
                return "\(outcome.sources.count) sources, " + Self.said(outcome)
            }
        }
    }

    // runScout's stubs: every html page reads as unchanged (its stored hash), and every source with its own
    // extractor lists the upcoming shows the store already holds for it, so the sweep is a pure re-land; the
    // inserting variant adds a tenth of each as new shows by the results file's own rule (`Phase0.insertedCopies`).
    private struct RunScoutStubs {
        let hashes: [String: String]
        let feeds: [String: ReplayFeed]
        let defaults: UserDefaults
        let nativeSources: Int
        let nativeEvents: Int

        func inserting(round: Int) -> [String: ReplayFeed] {
            var out: [String: ReplayFeed] = [:]
            // The results file's own rule (`Phase0.insertedCopies`, L370), over each feed's events.
            for (s, (id, feed)) in feeds.sorted(by: { $0.key < $1.key }).enumerated() {
                let added = Phase0.insertedCopies(of: feed.events, share: LandingAcceptanceRig.insertedShare,
                                                  tag: { "\(round)n\(s)e\($0)" }, linkTag: LandingAcceptanceRig.linkTag)
                out[id] = ReplayFeed(events: feed.events + added)
            }
            return out
        }
    }

    private func runScoutStubs(_ world: World, defaults: UserDefaults) throws -> RunScoutStubs {
        let sources = try world.ctx.fetch(FetchDescriptor<WatchedSource>())
        var hashes: [String: String] = [:]
        for s in sources {
            if let listings = s.listingsURL, let url = URL(string: listings), let hash = s.lastContentHash {
                hashes[url.absoluteString] = hash
            }
        }
        let today = EasternDate.today(Date())
        let native = sources.filter(\.usesNativeExtractor)
        let ids = Set(native.map(\.sourceId))
        var events: [String: [ExtractedEvent]] = [:]
        for p in try world.ctx.fetch(FetchDescriptor<Prospect>()) where (p.performanceDate ?? "") >= today {
            for id in p.sourceIds where ids.contains(id) {
                events[id, default: []].append(ExtractedEvent(title: p.groupName, presenter: p.presenter, venue: p.venue,
                                                              performanceDate: p.performanceDate,
                                                              sourceUrl: p.sourceListingURL))
            }
        }
        var feeds: [String: ReplayFeed] = [:]
        for id in ids { feeds[id] = ReplayFeed(events: events[id] ?? []) }
        return RunScoutStubs(hashes: hashes, feeds: feeds, defaults: defaults, nativeSources: native.count,
                             nativeEvents: events.values.reduce(0) { $0 + $1.count })
    }

    // MARK: - One entry point, every size and variant

    private func measureEveryEntryPoint() async throws {
        guard Rig.enabled else {
            print("rig4343: not measured. Set TEST_RUNNER_MEASURE_4343=1 to run it.")
            return
        }
        let build = Rig.build(askedFor: Rig.env["OVERTURE_BUILD_MODE"], debugCompiledIn: Rig.debugCompiledIn,
                              optimised: !_isDebugAssertConfiguration(),
                              markerCompiledIn: Rig.releaseLikeMarkerCompiledIn)
        Rig.say(build.line)
        if let refusal = build.refusal {
            Rig.say(refusal)
            Issue.record(Comment(rawValue: refusal))
            return
        }
        guard let inputs = try copiedInputs() else {
            Rig.say("UNMEASURED, no readable scout extract results on this machine")
            return
        }
        let storesDir = try sandboxes.make(named: "rig4343-stores")
        guard let base = try LiveStoreClone.makeClone(in: storesDir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        // The test's own scratch defaults, made outside every window: the first in a process sweeps
        // ~/Library/Preferences, which A11 measured at 2.2 s and which the product never pays (#4510).
        let defaults = ScratchDefaults.make("LandingAcceptanceRigTests")
        let world = try await makeWorld(factor: Rig.size, base: base, storesDir: storesDir, inputs: inputs)
        var rows: [String] = []
        var failures: [String] = []
        for entry in Rig.entries {
            guard let carried = Rig.carried.first(where: { $0.entry == entry }) else { continue }
            Rig.say("\(entry.rawValue): drives \(carried.top), as \(carried.viewCallers.sorted().joined(separator: ", ")) "
                    + "does; " + (carried.usesTheCheck
                        ? "A7 BYPASSED by the measurement seam (AlreadyLandedCheck.bypassedForMeasurement) after its "
                            + "positive control"
                        : "A7 does not apply (no results file identity)"))
            // One entry point that throws is said and the next still measured, on the same RootView.
            do {
                rows += try await measureSize(entry, carried, world: world, defaults: defaults)
            } catch {
                failures.append("\(entry.rawValue): \(error)")
                Rig.say("\(entry.rawValue): FAILED, \(error)")
            }
        }
        await close(world)
        Rig.say("table | entry | size | variant | largest single main thread hold | above load 8, not counted |")
        for row in rows { Rig.say("table " + row) }
        Rig.say("the 100 ms bar is judged by Phase E of #4275, not by this run")
        #expect(failures.isEmpty, Comment(rawValue: "entry points that could not be measured: \(failures)"))
    }

    // One store size of one entry point: the positive control where the entry makes the A7 check, then each
    // variant's warm up and samples. Answers the table rows.
    private func measureSize(_ entry: Rig.Entry, _ carried: Rig.Carried, world: World,
                             defaults: UserDefaults) async throws -> [String] {
        let factor = world.factor
        var rows: [String] = []
        do {
            let shows = try world.ctx.fetchCount(FetchDescriptor<Prospect>())
            Rig.say("\(entry.rawValue) x\(factor): \(shows) shows, \(world.scaled.results.count) sources, "
                    + "\(world.scaled.results.reduce(0) { $0 + $1.events.count }) events, " + Phase0.load())
            if carried.usesTheCheck {
                // The POSITIVE CONTROL (L159): the same file landed twice with the REAL check; the second must be
                // refused as already landed, or the seam below could be hiding a broken A7. The first is this
                // size's warm up.
                let url = world.dir.appendingPathComponent("rig4343-x\(factor)-control.json")
                try world.relandData.write(to: url)
                let first = await ingest(world, file: url, alreadyLanded: .lookUp)
                _ = await settle(world, timeline: nil, deadline: .seconds(60 * factor + 60))
                _ = try flush(world)
                let second = await ingest(world, file: url, alreadyLanded: .lookUp)
                let refused = second.contains("ALREADY LANDED")
                Rig.say("\(entry.rawValue) x\(factor) positive control, the real check: first landing \(first); second "
                        + "landing \(second): " + (refused ? "refused as already landed, as it must be" : "NOT REFUSED"))
                #expect(refused, Comment(rawValue: "the real already-landed check let a second landing of the same "
                                         + "file through, so the seam cannot be trusted to hide only itself"))
                guard refused else { return rows }
            }
            var stubs: RunScoutStubs?
            if entry == .runScout {
                stubs = try runScoutStubs(world, defaults: defaults)
                Rig.say("runScout x\(factor): \(stubs!.nativeSources) sources with their own extractor, listing "
                        + "\(stubs!.nativeEvents) upcoming shows; \(stubs!.hashes.count) pages read as unchanged")
            }
            for variant in Rig.variants {
                var taken: [Rig.Sample] = []
                for round in 0...Rig.samples {
                    // A round that cannot be prepared (a kept copy the folder refuses, say) is said with why and
                    // skipped, never measured as something it is not.
                    let prepared: (() async throws -> String)?
                    do {
                        prepared = try prepare(entry, variant, world, runScoutStubs: stubs)
                    } catch {
                        Rig.say("\(entry.rawValue) x\(factor) \(variant.label) round \(round): UNMEASURED, could not be "
                                + "prepared: \(error)")
                        continue
                    }
                    guard let work = prepared else {
                        Rig.say("\(entry.rawValue) x\(factor) \(variant.label) round \(round): UNMEASURED, could not be prepared")
                        continue
                    }
                    if round == 0 {
                        // The warm up, unmeasured, so every measured round starts from the same state.
                        let said = try await work()
                        _ = await settle(world, timeline: nil, deadline: .seconds(60 * factor + 60))
                        let flushed = try flush(world)
                        let removed = try await removeInserted(world)
                        Rig.say("\(entry.rawValue) x\(factor) \(variant.label) warm up: \(said); \(flushed); \(removed)")
                        continue
                    }
                    let sample = try await measure(world, work)
                    let flushed = try flush(world)
                    let removed = try await removeInserted(world)
                    taken.append(sample)
                    Rig.say("\(entry.rawValue) x\(factor) \(variant.label) round \(round): " + Rig.describe(sample)
                            + "; then \(flushed); \(removed)")
                }
                rows.append(Rig.row(entry, factor, variant, Rig.cell(taken)))
            }
        }
        return rows
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func measureEveryEntryPointOnOneStore() async throws { try await measureEveryEntryPoint() }
}

// The rig's own arithmetic, in every run: which term a hold belongs to, which samples count, and what a cell with
// none says. Cheap and pure, so a rig that miscounts is caught without the hour a measurement takes.
@Suite("#4343 E0 the acceptance rig's arithmetic")
struct LandingAcceptanceRigArithmeticTests {
    private typealias Rig = LandingAcceptanceRig
    private static func t(_ ms: Double) -> UInt64 { UInt64(ms * 1_000_000) }

    @Test func eachHoldIsChargedToTheTermItsPingWasPostedIn() {
        let w = Rig.Window(start: Self.t(1_000), firstYield: Self.t(1_005), returned: Self.t(1_500), end: Self.t(2_000))
        let pings = [
            Rig.Ping(posted: Self.t(990), ran: Self.t(1_004)),     // waited out the first hold: 4 ms from the start
            Rig.Ping(posted: Self.t(1_010), ran: Self.t(1_250)),   // a 240 ms landing turn
            Rig.Ping(posted: Self.t(1_600), ran: Self.t(1_640)),   // a 40 ms redraw
            Rig.Ping(posted: Self.t(2_100), ran: Self.t(2_400)),   // after the window: not counted
        ]
        let h = Rig.holds(pings, in: w)
        #expect(h.firstHold == 5)
        #expect(h.landing == 240)
        #expect(h.redraw == 40)
        #expect(h.worst == 240)
        #expect(h.worstTerm == .landing)
        #expect(h.over100 == 1)
    }

    // A ping posted during the first hold that runs only after the turn queued behind the stamp is charged to
    // the first hold, the term it was posted in, never to the landing it finished inside.
    @Test func aPingPostedInTheFirstHoldStaysWithTheFirstHoldWhereverItRuns() {
        let w = Rig.Window(start: 0, firstYield: Self.t(100), returned: Self.t(500), end: Self.t(1_000))
        let h = Rig.holds([Rig.Ping(posted: Self.t(50), ran: Self.t(160))], in: w)
        #expect(h.firstHold == 110)
        #expect(h.landing == 0)
        #expect(h.worstTerm == .firstHold)
    }

    @Test func aFirstHoldOverTheBarIsTheWorstAndCountedOnce() {
        let w = Rig.Window(start: 0, firstYield: Self.t(150), returned: Self.t(200), end: Self.t(300))
        let h = Rig.holds([Rig.Ping(posted: Self.t(10), ran: Self.t(150))], in: w)
        #expect(h.worst == 150)
        #expect(h.worstTerm == .firstHold)
        #expect(h.over100 == 1)
    }

    private static func sample(_ worst: Double, load: Double) -> Rig.Sample {
        var holds = Rig.Holds()
        holds.worst = worst
        holds.worstTerm = .landing
        return Rig.Sample(holds: holds, wallMs: 0, settleMs: 0, settled: true, loadStart: load, loadEnd: load, said: "")
    }

    @Test func samplesAtLoadEightOrOverAreReportedAndNeverCounted() {
        let c = Rig.cell([Self.sample(300, load: 2), Self.sample(900, load: 8), Self.sample(100, load: 3),
                          Self.sample(200, load: 7.9)])
        #expect(c.kept.count == 3)
        #expect(c.medianWorst == 200)
        let row = Rig.row(.calendarIngest, 4, .reland, c)
        #expect(row.contains("200.0 ms median of 3 (100.0 to 300.0)"))
        #expect(row.contains("OVER the bar by 100.0 ms"))
        #expect(row.contains("discarded: 900.0 ms at load 8.0"))
    }

    @Test func aCellWithNothingUnderLoadEightIsUnmeasuredNeverRed() {
        let c = Rig.cell([Self.sample(50, load: 12), Self.sample(60, load: 640)])
        #expect(c.medianWorst == nil)
        let row = Rig.row(.leadPaste, 1, .inserting, c)
        #expect(row.contains("UNMEASURED, no sample under load 8"))
        #expect(!row.contains("under the bar"))
        #expect(c.worstTerm == .landing, "the raw readings still name their worst term")
    }

    // The results file's inserting round and the native feeds' one are ONE rule (`Phase0.insertedCopies`, L370): over
    // the same events, with the same tag and link tag, the two event types come out as the same shows.
    @Test func bothInsertingPathsAddTheSameShowsByOneRule() {
        let scout = (0..<10).map { i in
            ScoutExtractEvent(title: "Show \(i)", presenter: "Presenter \(i)", venue: "Hall", performanceDate: "2027-01-1\(i)",
                              sourceUrl: "https://example.test/show-\(i)")
        }
        let feed = scout.map { ExtractedEvent(title: $0.title, presenter: $0.presenter, venue: $0.venue,
                                              performanceDate: $0.performanceDate, sourceUrl: $0.sourceUrl) }
        let results = ScoutExtractResults(version: 1, generatedAt: "2027-01-01T00:00:00Z", results: [
            ScoutExtractResult(sourceId: "only", verdict: .upcomingListings, events: scout, note: nil)])
        let fromFile = Array(Phase0.insertingResults(results, share: Rig.insertedShare, round: 7,
                                                     linkTag: Rig.linkTag).results[0].events.dropFirst(scout.count))
        let fromFeed = Phase0.insertedCopies(of: feed, share: Rig.insertedShare, tag: { "7s0e\($0)" },
                                             linkTag: Rig.linkTag)
        #expect(fromFile.count == 1, "a tenth of ten events, at least one")
        #expect(fromFile.map(\.title) == fromFeed.map(\.title))
        #expect(fromFile.map(\.sourceUrl) == fromFeed.map(\.sourceUrl))
        #expect(fromFeed.allSatisfy { $0.title.hasPrefix(Phase0.syntheticTitle) && $0.seriesId == nil })
        #expect(fromFeed.first?.sourceUrl == "https://example.test/show-0/rig4343-7s0e0")
    }

    @Test func aRunAskedToBeReleaseLikeRefusesCodeThatIsNot() {
        let debug = Rig.build(askedFor: "release-like", debugCompiledIn: true, optimised: true, markerCompiledIn: true)
        #expect(debug.refusal?.hasPrefix("UNMEASURED") == true)
        #expect(debug.line.contains("DEBUG compiled out: no"))
        let unoptimised = Rig.build(askedFor: "release-like", debugCompiledIn: false, optimised: false,
                                    markerCompiledIn: true)
        #expect(unoptimised.refusal != nil)
        let release = Rig.build(askedFor: "release-like", debugCompiledIn: false, optimised: true, markerCompiledIn: true)
        #expect(release.refusal == nil)
        #expect(release.line.contains("DEBUG compiled out: yes"))
        let ordinary = Rig.build(askedFor: nil, debugCompiledIn: true, optimised: false, markerCompiledIn: false)
        #expect(ordinary.refusal == nil, "an ordinary Debug run is read as the Debug reading it is")
    }
}
