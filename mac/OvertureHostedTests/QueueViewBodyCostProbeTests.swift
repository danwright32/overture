import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture

// #4106 Phase 0c.8: what the queue's BODY plus a forced layout and display pass costs, over a SERVED
// RenderData, at Dan's real window size (plan v7, section 11 item 8).
//
// WHY SERVED. Every other queue timing on #4106 is the derivation. This one is the other half of the
// per-change budget: once a change has been patched into a RenderData, what does drawing it cost? Step V
// (#4286) added the seam, `QueueRenderDataProvider`, and `AServedRenderDataIsWhatTheQueueDrawsTests`
// proves a served pass is drawn with ZERO derivations. So the whole-store pass is built once, OUTSIDE
// the clock, and only the view's own work is inside it.
//
// WHY BODY PLUS LAYOUT AND DISPLAY, never the body alone (L472). A body evaluation builds a description;
// the lazy stack realizing rows, each row asking the card store, and the layout of those rows happen in
// the layout pass after it. So each reading runs from the change to the moment the hosting view stops
// asking for layout, display or another body evaluation.
//
// WHAT IS TIMED, two ways, both printed:
//   cpu    the MAIN THREAD's own CPU time over that window (CLOCK_THREAD_CPUTIME_ID), which is what the
//          plan's target counts ("main-thread time per change") and excludes the pump's idle waits.
//   wall   elapsed time to the last iteration that did work. It includes up to a few milliseconds of the
//          pump waiting for SwiftUI's run loop observer, so it is an upper bound on the same thing.
// The stop rule is scored on each, and a disagreement between the two is printed rather than resolved.
//
// WHAT IT CANNOT SEE, said here so nobody reads more into it. The window is borderless and never ordered
// front (#3480), so AppKit lays it out and draws into its backing store, and the WindowServer never
// composites it. A served change carries no animation transaction, so a dismissal's departure animation is
// not in the number. And the view's OWN `focusedStage` state cannot be driven from outside, so a stage
// change here is the served data for another stage drawn under the Scout heading: the rows and cards are
// that stage's, the heading text is not.
//
// OPT IN, like every stopwatch on #4106, for L224's reason: a timing on a shared Mac measures what else
// the machine is doing. Without the variable the probe prints that it was not measured and passes (L98):
//
//   TEST_RUNNER_MEASURE_4106_PHASE0C_VIEW=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureHostedTests/QueueViewBodyCostProbeTests
//
// What rides along on every push is the RIG, asserted without a clock on a synthetic 60 row fixture: a
// served change really does redraw, the drawn rows really are realized, and nothing is derived.
//
// PRIVACY. Counts and durations only, never a show name, venue, address or key (L222).

// A provider whose served pass can be swapped while the queue is on screen. Observable, so the body that
// reads it in `makeRenderData` is invalidated by the swap exactly as it would be by any other dependency.
@MainActor
@Observable
final class Phase0cServedFeed: QueueRenderDataProvider {
    var data: QueueView.RenderData
    init(_ data: QueueView.RenderData) { self.data = data }
    func servedRenderData() -> QueueView.RenderData? { data }
}

enum Phase0cView {
    nonisolated static var enabled: Bool {
        ProcessInfo.processInfo.environment["MEASURE_4106_PHASE0C_VIEW"] != nil
    }

    static let stopMs = 50.0
    static let budgetMs = 30.0

    // Dan's main window frame. NOT read from the app's defaults domain: a test building a defaults suite
    // reaches real shared state (TestsCannotReachSharedStateTests, #3774), so the frame is passed in as
    // `TEST_RUNNER_MEASURE_4106_PHASE0C_VIEW_FRAME=<w>x<h>`, and its default is the one measured from
    // the Release app's saved `NSWindow Frame main` on 2026-09-27 (1728x980). Printed with its source.
    static let measuredFrame = NSSize(width: 1728, height: 980)

    static func windowFrame(_ env: [String: String]) -> (frame: NSSize, source: String) {
        guard let raw = env["MEASURE_4106_PHASE0C_VIEW_FRAME"] else {
            return (measuredFrame, "Dan's saved frame as measured 2026-09-27")
        }
        let parts = raw.lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 100, parts[1] > 100 else {
            return (measuredFrame, "UNREADABLE frame '\(raw)', so Dan's saved frame as measured 2026-09-27")
        }
        return (NSSize(width: parts[0], height: parts[1]), "the frame passed in (\(raw))")
    }

    static func dansWindow() -> (content: NSSize, source: String) {
        let (size, source) = windowFrame(ProcessInfo.processInfo.environment)
        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let content = NSWindow.contentRect(forFrameRect: frame,
                                           styleMask: [.titled, .closable, .miniaturizable, .resizable])
        return (content.size, "frame \(Int(size.width))x\(Int(size.height)) from \(source), "
                + "content \(Int(content.width))x\(Int(content.height)) under a standard title bar "
                + "(the toolbar and RootView's banners are NOT subtracted, so this is an upper bound on "
                + "the queue's height and on the rows it realizes)")
    }

    nonisolated(unsafe) static var sampledOnce = false

    static func threadCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    struct Settled {
        let wallMs: Double
        let cpuMs: Double
        let bodies: Int
        let completed: Bool
        // WHY a reading kept going: how many pump iterations saw each kind of work, and which view classes
        // were dirty. Printed for a reading that never settled, so "never quiet" names its cause (L11).
        var iterations = 0
        var dirtyIterations = 0
        var handledIterations = 0
        var bodyIterations = 0
        var dirtyClasses: [String: Int] = [:]
        // The rig's own bookkeeping CPU inside the reading, already subtracted from `cpuMs`.
        var rigMs = 0.0
        var diagnosis: String {
            let classes = dirtyClasses.sorted { $0.value > $1.value }.prefix(4)
                .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            return "iterations \(iterations), dirty \(dirtyIterations), run loop source \(handledIterations), "
                + "queue body \(bodyIterations), dirty views [\(classes)]"
        }
    }

    // One reading: run `change`, then drive layout, display and the run loop until three consecutive
    // iterations do no work. "Work" is a queue body evaluation, or a view in the window needing layout or
    // display before the pass. The window closes at the last iteration that did work, so the trailing
    // quiet iterations are outside both numbers.
    //
    // A run loop SOURCE is not work, and that was measured rather than assumed: the first version counted
    // one, and on the 4x corpus readings "never settled". A `sample` of the main thread during one showed
    // it idle in `mach_msg` for most of the window, AppKit's update cycle (`UC::DriverCore`, a CA
    // transaction flush) firing a source every iteration whether or not anything changed, and the rest of
    // the busy time in this rig's OWN dirty-view walk. So the heartbeat is only counted, for the diagnosis.
    //
    // The rig's own bookkeeping (that walk and the counter reads) is timed and SUBTRACTED from both
    // numbers, because on the 4x tree it is not small: the same sample put a quarter of the main thread's
    // busy time in it.
    @MainActor
    static func settle(_ window: NSWindow, bodyMustRun: Bool, seconds: Double = 10,
                       change: () -> Void) -> Settled {
        settle(bodyMustRun: bodyMustRun, seconds: seconds) { change(); return window }
    }

    // The same, where the change CREATES the window, so a first draw times the hosting view's own
    // construction too.
    @MainActor
    static func settle(bodyMustRun: Bool, seconds: Double = 10, making: () -> NSWindow) -> Settled {
        let bodies0 = QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface)
        let cpu0 = threadCPU()
        let t0 = Phase0.now()
        let window = making()
        var lastWall = Phase0.now()
        var lastCPU = threadCPU()
        var quiet = 0
        var diag = Settled(wallMs: 0, cpuMs: 0, bodies: 0, completed: false)
        // The rig's own bookkeeping, running totals, and their value at the last iteration that did work.
        var rigWall: UInt64 = 0, rigCPU: UInt64 = 0
        var rigWallAtLast: UInt64 = 0, rigCPUAtLast: UInt64 = 0
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let rw0 = Phase0.now(), rc0 = threadCPU()
            let before = QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface)
            var dirtyViews: [String] = []
            if let root = window.contentView { collectDirty(root, into: &dirtyViews) }
            let dirty = !dirtyViews.isEmpty
            rigWall += Phase0.now() - rw0; rigCPU += threadCPU() - rc0
            window.contentView?.layoutSubtreeIfNeeded()
            window.contentView?.displayIfNeeded()
            let handled = CFRunLoopRunInMode(.defaultMode, 0.002, true) == .handledSource
            let rw1 = Phase0.now(), rc1 = threadCPU()
            let ran = QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface) != before
            diag.iterations += 1
            if dirty { diag.dirtyIterations += 1 }
            if handled { diag.handledIterations += 1 }
            if ran { diag.bodyIterations += 1 }
            for name in Set(dirtyViews) { diag.dirtyClasses[name, default: 0] += 1 }
            // The FIRST reading still busy four seconds in is sampled once, from outside the process, so a
            // reading that never settles can be traced to the frames that kept the main thread working.
            // Stack frames only, written to this Mac's temporary directory and never printed (L222).
            if !sampledOnce, Phase0.now() - t0 > 4_000_000_000 {
                sampledOnce = true
                let out = FileManager.default.temporaryDirectory
                    .appendingPathComponent("phase0c8-unsettled-sample.txt")
                let sampler = Process()
                sampler.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                sampler.arguments = [String(ProcessInfo.processInfo.processIdentifier), "3", "-file", out.path]
                if (try? sampler.run()) != nil { print("0c.8 unsettled reading sampled to \(out.path)") }
            }
            if dirty || ran {
                lastWall = rw1
                lastCPU = rc1
                rigWallAtLast = rigWall; rigCPUAtLast = rigCPU
                quiet = 0
            } else {
                quiet += 1
            }
            rigWall += Phase0.now() - rw1; rigCPU += threadCPU() - rc1
            let bodyRan = QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface) > bodies0
            if quiet >= 3 && (bodyRan || !bodyMustRun) {
                diag.rigMs = Double(rigCPUAtLast) / 1e6
                return finish(diag, wall: lastWall - t0 - min(rigWallAtLast, lastWall - t0),
                              cpu: lastCPU - cpu0 - min(rigCPUAtLast, lastCPU - cpu0),
                              bodies0: bodies0, completed: true)
            }
        }
        diag.rigMs = Double(rigCPUAtLast) / 1e6
        return finish(diag, wall: lastWall - t0 - min(rigWallAtLast, lastWall - t0),
                      cpu: lastCPU - cpu0 - min(rigCPUAtLast, lastCPU - cpu0),
                      bodies0: bodies0, completed: false)
    }

    @MainActor
    private static func finish(_ d: Settled, wall: UInt64, cpu: UInt64, bodies0: Int, completed: Bool) -> Settled {
        var out = Settled(wallMs: Double(wall) / 1e6, cpuMs: Double(cpu) / 1e6,
                          bodies: QueueRenderCounter.renderCount(for: QueueRenderCounter.queueBodySurface) - bodies0,
                          completed: completed)
        out.iterations = d.iterations
        out.dirtyIterations = d.dirtyIterations
        out.handledIterations = d.handledIterations
        out.bodyIterations = d.bodyIterations
        out.dirtyClasses = d.dirtyClasses
        out.rigMs = d.rigMs
        return out
    }

    @MainActor
    static func collectDirty(_ view: NSView, into out: inout [String]) {
        if view.needsLayout { out.append("layout " + String(describing: type(of: view)).prefix(60)) }
        if view.needsDisplay { out.append("display " + String(describing: type(of: view)).prefix(60)) }
        for sub in view.subviews { collectDirty(sub, into: &out) }
    }

    @MainActor
    static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews {
            if let found = firstScrollView(in: sub) { return found }
        }
        return nil
    }

    // A REAL wheel event, delivered to the NSScrollView SwiftUI built, so the scroll takes the path a
    // trackpad does (RealScrollInvalidationTests' driver), in one turn of the requested size.
    @MainActor
    static func wheel(_ scroll: NSScrollView, by pixels: Double) {
        let delta = Int32(max(min(pixels, Double(Int32.max)), Double(Int32.min)))
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                               wheel1: delta, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cg) else { return }
        scroll.scrollWheel(with: event)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return .nan }
        let sorted = values.sorted()
        let rank = Int((p * Double(sorted.count - 1)).rounded(.up))
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    static func f(_ v: Double) -> String { String(format: "%.1f", v) }

    static func verdict(_ maxMs: Double, limit: Double) -> String { maxMs > limit ? "FAIL" : "PASS" }
}

// The rig 0c.8 and the view attribution probe beside it share, declared once (L613): the harness that
// hosts the real QueueView over a served feed, the window it lives in, and the pass's inputs as the app
// builds them.
@MainActor
enum Phase0cViewRig {
    struct Harness: View {
        let rows: [Prospect]
        let feed: Phase0cServedFeed
        @State private var deepLinkedKey: LeadDeepLink?
        @State private var deepLinkedKeys: LeadsDeepLink?
        @State private var feedback = ActionFeedback()
        @State private var dayOff = DayOffOfferRequest()
        @State private var undo = QueueUndoStack()

        var body: some View {
            QueueView(deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys,
                      allProspects: rows, renderDataProvider: feed)
                .environment(feedback)
                .environment(dayOff)
                .environment(undo)
        }
    }

    // Hosts the harness in a borderless window of `size`, never ordered front (#3480).
    static func host(_ container: ModelContainer, rows: [Prospect], feed: Phase0cServedFeed,
                     size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: AnyView(Harness(rows: rows, feed: feed)
            .modelContainer(container)))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        return window
    }

    struct Tables {
        let rows: [Prospect]
        let inquiries: [Inquiry]
        let answers: [OrgReachabilityAnswer]
        let sources: [WatchedSource]
        let refusals: ContactRefusal.Ledger
        let overrides: ProducerOverrides
        let geo: GeoRefusals
        let clients: ClientWindow
    }

    // The pass's inputs as the app builds them, from one context: the same reads probe 0b.2 takes.
    static func tables(_ ctx: ModelContext, export: URL) throws -> Tables {
        let rows = try ctx.fetch(FetchDescriptor<Prospect>())
        for r in rows { _ = r.recipients.count }
        let sources = try ctx.fetch(FetchDescriptor<WatchedSource>())
        let clients = DownbeatBridge.loadWithHealth(from: export, now: Date()).clients
        return Tables(
            rows: rows,
            inquiries: try ctx.fetch(FetchDescriptor<Inquiry>()),
            answers: try ctx.fetch(FetchDescriptor<OrgReachabilityAnswer>()),
            sources: sources,
            refusals: ContactRefusal.ledger(from: try ctx.fetch(FetchDescriptor<RefusedContactAddress>())),
            overrides: ProducerOverrides(promotedRows: try ctx.fetch(FetchDescriptor<PromotedProducer>()),
                                         demotedRows: try ctx.fetch(FetchDescriptor<DemotedHouse>())),
            geo: GeoRefusals(userExcludedTowns: Set(try ctx.fetch(FetchDescriptor<ExcludedTown>()).map(\.town)),
                             allowedSeedTowns: Set(try ctx.fetch(FetchDescriptor<AllowedSeedTown>()).map(\.town))),
            clients: ClientWindow(sources: sources, clients: clients))
    }

    // Every card prebuilt (`requestedCardKeys: nil`) unless `cards` names a narrower set, so a per-change
    // reading is the VIEW's cost and a card build lands in it only where the reading says so.
    static func servedPass(_ t: Tables, now: Date, stage: StageFocus, cards: Set<String>? = nil,
                           registry: QueueModel.CardKeyRegistry) -> QueueView.RenderData {
        QueueRenderPass.make(QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(t.rows), inquiries: t.inquiries, orgAnswers: t.answers,
            sources: t.sources, refusals: t.refusals, overrides: t.overrides,
            context: StageContext(now: now, geo: t.geo, clients: t.clients),
            focusedStage: stage, focusedKeys: nil, requestedCardKeys: cards, cardKeyRegistry: registry))
    }

    // The Downbeat export copied into a sandbox, so the pass reads the clients the app would without the
    // probe ever opening the real file for writing.
    static func scratchExport(_ sandboxes: TemporarySandboxes) throws -> URL {
        let dir = try sandboxes.make(named: "phase0c-view-export")
        let out = dir.appendingPathComponent("downbeat-export.json")
        if FileManager.default.fileExists(atPath: DownbeatBridge.defaultURL.path) {
            try FileManager.default.copyItem(at: DownbeatBridge.defaultURL, to: out)
        }
        return out
    }
}

@MainActor
@Suite("#4106 Phase 0c.8: the queue body plus layout over a served RenderData (opt in)")
struct QueueViewBodyCostProbeTests {
    // The frame parsing, on every push: a passed frame wins, an unreadable one falls back AND says so.
    @Test func theWindowFrameIsPassedInNeverReadFromTheApp() {
        #expect(Phase0cView.windowFrame([:]).frame == Phase0cView.measuredFrame)
        #expect(Phase0cView.windowFrame(["MEASURE_4106_PHASE0C_VIEW_FRAME": "1200x800"]).frame == NSSize(width: 1200, height: 800))
        let bad = Phase0cView.windowFrame(["MEASURE_4106_PHASE0C_VIEW_FRAME": "wide"])
        #expect(bad.frame == Phase0cView.measuredFrame)
        #expect(bad.source.contains("UNREADABLE"))
    }


    private let sandboxes = TemporarySandboxes()

    // MARK: - The rig, on every push, no clock

    private static func night(_ n: Int) -> String {
        let day = Calendar(identifier: .gregorian).date(byAdding: .day, value: 20 + n, to: Date())!
        return EasternDate.dayString(from: day)
    }

    // Sixty invented shows, three a night, dated from the clock so they stay inside the queue's lead-time
    // window whatever year this runs in (L130).
    private func seedSixty(_ ctx: ModelContext) throws -> [Prospect] {
        for n in 0..<60 {
            let p = Prospect(naturalKey: "view-probe-\(n)", groupName: "Ensemble \(n)", discipline: "music",
                             venue: "Venue \(n % 7) Hall", performanceDate: Self.night(n / 3),
                             sourceListingURL: nil, priorRelationship: "none",
                             production: "self", profile: "strong",
                             coverage: "likely_uncovered", fitScore: 4 + (n % 5), tier: "mid",
                             fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                             possibleMatchName: nil, status: .new)
            p.presenter = "Ensemble \(n) Presents"
            p.location = "New York, NY"
            ctx.insert(p)
        }
        try ctx.save()
        return try ctx.fetch(FetchDescriptor<Prospect>())
    }

    private func pass(_ rows: [Prospect], stage: StageFocus = .scout,
                      registry: QueueModel.CardKeyRegistry?) -> QueueView.RenderData {
        QueueRenderPass.make(QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(rows), inquiries: [], orgAnswers: [],
            context: StageContext(now: Date(), geo: .none, clients: .none),
            focusedStage: stage, cardKeyRegistry: registry))
    }

    // The claim every timing below rests on: a served change is REDRAWN, the rows drawn are really
    // realized, and the queue derives nothing while it happens. A rig that drew nothing would time an
    // empty list, and a fast empty list reads exactly like a fast queue (L472, L98, L159).
    @Test func aServedChangeReallyRedrawsTheRealizedRows() throws {
        let c = try TestModelContainer.inMemory(AppSchema.models)
        c.mainContext.autosaveEnabled = false
        let rows = try seedSixty(c.mainContext)
        let registry = QueueModel.CardKeyRegistry()
        let before = pass(rows, registry: registry)
        #expect(before.focusedRows.count > 10, "the fixture puts too few rows on the Scout stage to draw")

        let feed = Phase0cServedFeed(before)
        // Counted across the two DRAWS only: the served passes are built by `QueueRenderPass.make`, which
        // this counter also counts, and those builds are outside the clock by design.
        var derivedWhileDrawing = 0
        var derivations0 = QueueRenderCounter.derivations
        let window = Phase0cViewRig.host(c, rows: rows, feed: feed, size: NSSize(width: 1000, height: 800))
        defer { window.close() }
        let first = Phase0cView.settle(window, bodyMustRun: true) {}
        let drawnFirst = registry.takeKeys()
        derivedWhileDrawing += QueueRenderCounter.derivations - derivations0

        #expect(first.completed, "the first draw never settled")
        #expect(first.bodies >= 1, "the queue's body never ran")
        #expect(!drawnFirst.isEmpty, Comment(rawValue:
            "the first draw realized NO rows, so any timing on this rig is of an empty list (L472)"))

        // Dismiss one drawn row in a served pass and swap it in.
        let target = try #require(before.focusedRows.map(\.id).first { drawnFirst.contains($0) })
        let show = try #require(rows.first { $0.naturalKey == target })
        show.status = .dismissed
        let after = pass(rows, registry: registry)
        show.status = .new
        _ = registry.takeKeys()

        derivations0 = QueueRenderCounter.derivations
        let change = Phase0cView.settle(window, bodyMustRun: true) { feed.data = after }
        let drawnAfter = registry.takeKeys()
        derivedWhileDrawing += QueueRenderCounter.derivations - derivations0

        #expect(change.completed, "the served change never settled")
        #expect(change.bodies >= 1, "swapping the served pass did not re-evaluate the queue's body")
        #expect(!drawnAfter.isEmpty, "the redraw realized no rows")
        #expect(!drawnAfter.contains(target), Comment(rawValue:
            "the row dismissed in the served pass was still drawn, so the view drew the OLD pass and a "
            + "timing of this change would be of nothing"))
        #expect(derivedWhileDrawing == 0, Comment(rawValue:
            "the queue derived its own RenderData \(derivedWhileDrawing) "
            + "time(s) while one was served, so the probe would time the derivation too (L472)"))
    }

    // MARK: - The probe, opt in

    private struct Kind {
        let name: String
        var perKeyMedianCPU: [Double] = []
        var perKeyMedianWall: [Double] = []
        var allCPU: [Double] = []
        var allWall: [Double] = []
        var unsettled = 0
        var unsettledCPU: [Double] = []
        var firstUnsettled = ""
        var rig: [Double] = []

        // A reading that never went quiet is kept OUT of the medians, because its number is the cap
        // rather than a cost, and reported on its own with what kept it going. Never dropped silently:
        // a reading that never settles is itself the finding (L98).
        mutating func take(_ s: Phase0cView.Settled, cpu: inout [Double], wall: inout [Double]) {
            rig.append(s.rigMs)
            if s.completed {
                cpu.append(s.cpuMs); wall.append(s.wallMs)
            } else {
                unsettled += 1
                unsettledCPU.append(s.cpuMs)
                if firstUnsettled.isEmpty { firstUnsettled = s.diagnosis }
            }
        }

        mutating func close(cpu: [Double], wall: [Double]) {
            guard !cpu.isEmpty else { return }
            perKeyMedianCPU.append(cpu.sorted()[cpu.count / 2])
            perKeyMedianWall.append(wall.sorted()[wall.count / 2])
            allCPU += cpu; allWall += wall
        }
        var note = ""
    }

    private func line(_ k: Kind, label: String) -> String {
        let never = k.unsettled == 0 ? "" : " | NEVER SETTLED \(k.unsettled) (cpu before the 10 s cap "
            + k.unsettledCPU.map { Phase0cView.f($0) }.joined(separator: ", ") + " ms; first: \(k.firstUnsettled))"
        guard !k.perKeyMedianCPU.isEmpty else {
            return "0c.8 \(label) \(k.name): no settled reading. \(k.note)" + never
        }
        let cpuMax = k.perKeyMedianCPU.max()!, wallMax = k.perKeyMedianWall.max()!
        return "0c.8 \(label) \(k.name): keys \(k.perKeyMedianCPU.count), settled samples \(k.allCPU.count)"
            + " | cpu per-key-median max \(Phase0cView.f(cpuMax)) p99 "
            + "\(Phase0cView.f(Phase0cView.percentile(k.perKeyMedianCPU, 0.99))) median "
            + "\(Phase0cView.f(Phase0cView.percentile(k.perKeyMedianCPU, 0.5))) worst sample "
            + "\(Phase0cView.f(k.allCPU.max()!)) ms"
            + " | wall per-key-median max \(Phase0cView.f(wallMax)) p99 "
            + "\(Phase0cView.f(Phase0cView.percentile(k.perKeyMedianWall, 0.99))) median "
            + "\(Phase0cView.f(Phase0cView.percentile(k.perKeyMedianWall, 0.5))) worst sample "
            + "\(Phase0cView.f(k.allWall.max()!)) ms"
            + " | rig bookkeeping subtracted, median \(Phase0cView.f(Phase0cView.percentile(k.rig, 0.5))) ms"
            + (k.note.isEmpty ? "" : " | \(k.note)") + never
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func probe0c8BodyPlusLayoutOverAServedPass() throws {
        guard Phase0cView.enabled else {
            print("0c.8: not measured. Set TEST_RUNNER_MEASURE_4106_PHASE0C_VIEW=1 to run it.")
            return
        }
        let (size, source) = Phase0cView.dansWindow()
        print("0c.8 window: \(source)")
        print("0c.8 build: Debug (the test runner's build); every number below is Debug, not Release")

        let dir = try sandboxes.make(named: "phase0c-view")
        guard let base = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let big = try Phase0.scaledCopy(of: base, factor: 4, in: dir)
        let export = try Phase0cViewRig.scratchExport(sandboxes)

        var verdicts: [String] = []
        for (label, url) in [("live clone", base), ("4x", big)] {
            let container = try Phase0.openContainer(at: url)
            container.mainContext.autosaveEnabled = false
            let t = try Phase0cViewRig.tables(container.mainContext, export: export)
            let now = Date()
            print("0c.8 \(label) corpus: \(Phase0.shape(t.rows)) | \(Phase0.load())")

            let registry = QueueModel.CardKeyRegistry()
            let a = Phase0cViewRig.servedPass(t, now: now, stage: .scout, registry: registry)
            print("0c.8 \(label) served Scout pass: \(a.focusedRows.count) rows on the stage, "
                  + "\(a.dateGroups.count) date groups, \(a.cards.builtCount) cards prebuilt")

            // MARK: first draw, cards prebuilt: a fresh window each sample.
            var firstPre = Kind(name: "first draw, cards prebuilt")
            var realized: [Int] = []
            let floorWindow = Phase0cViewRig.host(container, rows: t.rows, feed: Phase0cServedFeed(a), size: size)
            _ = Phase0cView.settle(floorWindow, bodyMustRun: true) {}   // warm the host once, untimed
            floorWindow.close()
            _ = registry.takeKeys()
            var cpus: [Double] = [], walls: [Double] = []
            for _ in 0..<5 {
                var w: NSWindow?
                let s = Phase0cView.settle(bodyMustRun: true) {
                    let made = Phase0cViewRig.host(container, rows: t.rows, feed: Phase0cServedFeed(a), size: size)
                    w = made
                    return made
                }
                firstPre.take(s, cpu: &cpus, wall: &walls)
                let keys = registry.takeKeys()
                realized.append(keys.count)
                w?.close()
            }
            firstPre.close(cpu: cpus, wall: walls)
            firstPre.note = "five fresh windows, hosting view built inside the clock, \(Phase0.load())"
            print("0c.8 \(label) viewport: \(realized.map(String.init).joined(separator: ", ")) rows realized "
                  + "per first draw at \(Int(size.width))x\(Int(size.height)) (the card store's own count of "
                  + "rows that asked for a card)")

            // MARK: first draw, cards NOT prebuilt: the app's genuine first frame, every realized card
            // built inside the body. A fresh pass per sample, because the card store keeps what it built.
            var firstCold = Kind(name: "first draw, cards built in the body")
            cpus = []; walls = []
            for _ in 0..<5 {
                let cold = Phase0cViewRig.servedPass(t, now: now, stage: .scout, cards: [], registry: registry)
                _ = registry.takeKeys()
                let w = Phase0cViewRig.host(container, rows: t.rows, feed: Phase0cServedFeed(cold), size: size)
                let s = Phase0cView.settle(w, bodyMustRun: true) {}
                firstCold.take(s, cpu: &cpus, wall: &walls)
                _ = registry.takeKeys()
                w.close()
            }
            firstCold.close(cpu: cpus, wall: walls)
            firstCold.note = "hosting view built outside the clock here, \(Phase0.load())"

            // One window for every per-change kind, drawn once and settled before anything is timed.
            let feed = Phase0cServedFeed(a)
            let window = Phase0cViewRig.host(container, rows: t.rows, feed: feed, size: size)
            defer { window.close() }
            _ = Phase0cView.settle(window, bodyMustRun: true) {}
            let drawnOnA = registry.takeKeys()

            // MARK: the noise floor: the rig's own cost with nothing changed.
            var floor = Kind(name: "no change (rig floor)")
            cpus = []; walls = []
            for _ in 0..<5 {
                let s = Phase0cView.settle(window, bodyMustRun: false) {}
                floor.take(s, cpu: &cpus, wall: &walls)
            }
            floor.close(cpu: cpus, wall: walls)
            floor.note = Phase0.load()

            // MARK: one row dismissed, for EVERY row the viewport draws: the served pass differs by that
            // one row. Each key is dismissed and restored five times; both directions are one-row changes.
            var dismiss = Kind(name: "one row dismissed (and its undo)")
            let drawnOrdered = a.focusedRows.map(\.id).filter { drawnOnA.contains($0) }
            let byKey = Dictionary(t.rows.map { ($0.naturalKey, $0) }, uniquingKeysWith: { x, _ in x })
            for key in drawnOrdered {
                guard let show = byKey[key] else { continue }
                let was = show.status
                show.status = .dismissed
                let b = Phase0cViewRig.servedPass(t, now: now, stage: .scout, registry: registry)
                show.status = was
                var kc: [Double] = [], kw: [Double] = []
                for _ in 0..<5 {
                    for next in [b, a] {
                        let s = Phase0cView.settle(window, bodyMustRun: true) { feed.data = next }
                        dismiss.take(s, cpu: &kc, wall: &kw)
                    }
                }
                _ = registry.takeKeys()
                dismiss.close(cpu: kc, wall: kw)
            }
            dismiss.note = "every drawn row of the Scout stage, \(Phase0.load())"

            // MARK: a stage focus change, to EVERY stage the queue list draws with rows on it.
            var stageKind = Kind(name: "stage focus change (Scout and back)")
            var stagesDone: [String] = []
            for stage in StageFocus.allCases where stage != .scout && stage != .followUps
                && stage != .reachedOut {
                let s = Phase0cViewRig.servedPass(t, now: now, stage: stage, registry: registry)
                stagesDone.append("\(stage.rawValue) \(s.focusedRows.count)")
                var kc: [Double] = [], kw: [Double] = []
                for _ in 0..<5 {
                    for next in [s, a] {
                        let r = Phase0cView.settle(window, bodyMustRun: true) { feed.data = next }
                        stageKind.take(r, cpu: &kc, wall: &kw)
                    }
                }
                _ = registry.takeKeys()
                stageKind.close(cpu: kc, wall: kw)
            }
            stageKind.note = "every served stage with its row count: \(stagesDone.joined(separator: ", ")); followUps and "
                + "reachedOut draw other lists and are not served here, \(Phase0.load())"

            // MARK: a scroll to the middle of the Scout list and back, by a real wheel event.
            var scrollKind = Kind(name: "scroll to the middle (and back)")
            if ScreenSession.isLocked {
                ScreenSession.reportUnmeasured("QueueViewBodyCostProbeTests.scroll")
                scrollKind.note = "screen locked, the WindowServer lays nothing out"
            } else if let scroll = Phase0cView.firstScrollView(in: window.contentView!),
                      let doc = scroll.documentView {
                var kc: [Double] = [], kw: [Double] = []
                var moved: [Int] = []
                for _ in 0..<5 {
                    let visible = scroll.contentView.bounds.height
                    let target = max(0, (doc.frame.height - visible) / 2)
                    let y0 = scroll.contentView.bounds.origin.y
                    let down = Phase0cView.settle(window, bodyMustRun: false) {
                        Phase0cView.wheel(scroll, by: -(target - y0))
                    }
                    let y1 = scroll.contentView.bounds.origin.y
                    moved.append(Int(y1 - y0))
                    let up = Phase0cView.settle(window, bodyMustRun: false) {
                        Phase0cView.wheel(scroll, by: y1)
                    }
                    for s in [down, up] {
                        scrollKind.take(s, cpu: &kc, wall: &kw)
                    }
                }
                let drawnWhileScrolling = registry.takeKeys().subtracting(drawnOnA).count
                scrollKind.close(cpu: kc, wall: kw)
                scrollKind.note = "document \(Int(doc.frame.height)) pt, moved "
                    + "\(moved.map(String.init).joined(separator: ", ")) pt per turn, "
                    + "\(drawnWhileScrolling) rows drawn that the top had not, \(Phase0.load())"
                if moved.allSatisfy({ $0 == 0 }) {
                    scrollKind.perKeyMedianCPU = []; scrollKind.perKeyMedianWall = []
                    scrollKind.note = "UNMEASURED: the wheel turn did not move the content. " + scrollKind.note
                }
            } else {
                scrollKind.note = "no NSScrollView found in the hosted queue"
            }

            for k in [floor, firstPre, firstCold, dismiss, stageKind, scrollKind] {
                print(line(k, label: label))
            }
            if label == "4x" {
                for k in [dismiss, stageKind, scrollKind, firstPre, firstCold] {
                    // A reading that never settled is a FAIL on its own: the main thread was still working
                    // when the cap ended it, whatever the settled medians say.
                    let neverNote = k.unsettled == 0 ? "" : "; \(k.unsettled) reading(s) NEVER SETTLED, FAIL"
                    guard let cpu = k.perKeyMedianCPU.max(), let wall = k.perKeyMedianWall.max() else {
                        verdicts.append("0c.8 stop (\(k.name)): "
                            + (k.unsettled > 0 ? "FAIL, no reading settled" : "UNMEASURED, \(k.note)"))
                        continue
                    }
                    verdicts.append("0c.8 stop (\(k.name)) at 5,376: cpu \(Phase0cView.f(cpu)) ms "
                        + "\(Phase0cView.verdict(cpu, limit: Phase0cView.stopMs)) against 50, "
                        + "\(Phase0cView.verdict(cpu, limit: Phase0cView.budgetMs)) against the 30 budget; "
                        + "wall \(Phase0cView.f(wall)) ms "
                        + "\(Phase0cView.verdict(wall, limit: Phase0cView.stopMs)) against 50, "
                        + "\(Phase0cView.verdict(wall, limit: Phase0cView.budgetMs)) against 30" + neverNote)
                }
            }
        }
        for v in verdicts { print(v) }
    }
}
