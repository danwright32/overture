import Testing
import Foundation
import AppKit
import SwiftUI
import SwiftData
@testable import Overture
import ViewInspector

// #4358 slice E4d (plan item 21, and item 20's screenshots): what the switch costs and what it puts on screen, over a
// throwaway clone of the live store (`LiveStoreClone`, never the store itself, L2) and its fourfold copy.
//
// MEASUREMENT ONLY, OPT IN, and each test says it did not run rather than passing (L98):
//
//   TEST_RUNNER_MEASURE_4358_SWITCH=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureHostedTests/QueueEngineSwitchProbeTests
//
// adding TEST_RUNNER_MEASURE_4358_SWITCH_SHOTS=<folder outside any checkout> for the screenshots. Everything is
// drawn OFFSCREEN, in borderless windows never ordered front (#3480), so nothing takes focus on the machine it runs
// on. Counts and milliseconds only in the output, never a name (L222); the screenshots hold real show names and stay
// in the folder they were written to.
//
// THE TWO READINGS, per store size, each the median of five with the load beside it (L395, L356):
//   * the first draw after the fill: the engine started and its launch fill finished, then the queue mounted and
//     drawn until it goes quiet (`Phase0cView.settle`, the same rule #4106's body probe uses);
//   * one action: one drawn Scout card dismissed and saved, timed in two parts, the save to the engine's publish
//     (its turn, waited for, since the engine's turns run as main actor tasks a nested run loop never reaches), and
//     the redraw that publish causes.
// Main's arm is the same harness over main's `QueueView`, which reads the shows through a query of its own: run on a
// worktree of main (the PR pastes both), because main has no engine to start.
@MainActor
@Suite("#4358 E4d the switch, measured and drawn over the live clone (opt in)", .serialized)
final class QueueEngineSwitchProbeTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["MEASURE_4358_SWITCH"] != nil }
    nonisolated static var shots: String? { ProcessInfo.processInfo.environment["MEASURE_4358_SWITCH_SHOTS"] }

    private struct Harness: View {
        let engine: QueueEngineHost.Engine
        @State private var deepLinkedKey: LeadDeepLink?
        @State private var deepLinkedKeys: LeadsDeepLink?
        @State private var feedback = ActionFeedback()
        @State private var dayOff = DayOffOfferRequest()
        @State private var undo = QueueUndoStack()

        var body: some View {
            QueueView(engine: engine, deepLinkedKey: $deepLinkedKey, deepLinkedKeys: $deepLinkedKeys)
                .environment(feedback)
                .environment(dayOff)
                .environment(undo)
        }
    }

    private static let size = NSSize(width: 1400, height: 900)

    private func host(_ container: ModelContainer, _ engine: QueueEngineHost.Engine,
                      scheme: ColorScheme? = nil) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let scheme { window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua) }
        let hosting = NSHostingView(rootView: AnyView(Harness(engine: engine).modelContainer(container)))
        hosting.frame = window.contentLayoutRect
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        return window
    }

    private func stores() throws -> [(label: String, url: URL)] {
        let dir = try sandboxes.make(named: "switch-4358")
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        return [("live clone", clone), ("4x", try Phase0.scaledCopy(of: clone, factor: 4, in: dir))]
    }

    // #4617: every reading through `Phase0.reading`, so each prints the `probe reading:` line the before and after
    // comparison reads, under a metric naming the reading and the store size.
    private func reading(_ metric: String, _ label: String, _ runs: [Double]) -> String {
        let r = Phase0.reading("switch-\(metric)-\(label)", runs: runs)
        return runs.isEmpty ? "UNMEASURED: nothing ran" : r.text + " (n \(runs.count))"
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func theFirstDrawAfterTheFillAndOneActionAtOneAndFourTimesTheStore() async throws {
        guard Self.enabled else {
            print("switch-4358: not measured. Set TEST_RUNNER_MEASURE_4358_SWITCH=1 to run it.")
            return
        }
        for (label, url) in try stores() {
            let container = try Phase0.openContainer(at: url)
            container.mainContext.autosaveEnabled = false
            let context = container.mainContext
            let fillStart = Phase0.now()
            let engine = try await HostedQueueEngine.started(context: context)
            let fillMs = Phase0.ms(since: fillStart)
            let pass = try #require(engine.output?.value)
            var draws: [Double] = [], drawCPU: [Double] = [], unsettled = 0
            for _ in 0..<6 {
                var window: NSWindow?
                let settled = Phase0cView.settle(bodyMustRun: true, seconds: 60) {
                    let made = host(container, engine)
                    window = made
                    return made
                }
                if !settled.completed { unsettled += 1 }
                draws.append(settled.wallMs)
                drawCPU.append(settled.cpuMs)
                HostedPassCounting.unmountAndClose(window)
                await Task.yield()
            }
            // The first is the warm up (fonts, the view graph's first build), kept out of the median and printed.
            let warmUp = draws.removeFirst()
            drawCPU.removeFirst()

            // One action, on a card the queue draws: a Scout row's show dismissed and saved, then put back.
            let window = host(container, engine)
            defer { HostedPassCounting.unmountAndClose(window) }
            _ = Phase0cView.settle(window, bodyMustRun: false, seconds: 60) {}
            let targets = pass.data.focusedRows.prefix(5).map(\.id)
            let shows = try context.fetch(FetchDescriptor<Prospect>()).filter { targets.contains($0.naturalKey) }
            var publishes: [Double] = [], redraws: [Double] = [], missed = 0
            for show in shows {
                let before = engine.output?.generation
                let saved = Phase0.now()
                show.status = .dismissed
                try Phase0.save(context, step: "switch-4358 dismiss")
                let published = await waitUntil("the dismiss is published", timeout: .seconds(60)) {
                    engine.output?.generation != before
                }
                if !published { missed += 1; continue }
                publishes.append(Phase0.ms(since: saved))
                redraws.append(Phase0cView.settle(window, bodyMustRun: false, seconds: 60) {}.wallMs)
                let after = engine.output?.generation
                show.status = .new
                try Phase0.save(context, step: "switch-4358 restore")
                _ = await waitUntil("the restore is published", timeout: .seconds(60)) {
                    engine.output?.generation != after
                }
                _ = Phase0cView.settle(window, bodyMustRun: false, seconds: 60) {}
            }
            print("""
                switch-4358 [\(label)] \(Phase0.load())
                  shows held by the engine                    \(engine.everyShow.count), rows in its pass \(pass.data.rows.count)
                  start to the launch fill done               \(String(format: "%.1f ms", fillMs))
                  first draw after the fill (wall)            \(reading("firstDrawWall", label, draws))  warm up \(String(format: "%.1f", warmUp)) ms, \(unsettled) never settled
                  first draw after the fill (main thread CPU) \(reading("firstDrawCPU", label, drawCPU))
                  one dismiss: save to the engine's publish   \(reading("dismissToPublish", label, publishes))
                  one dismiss: the redraw it causes           \(reading("dismissRedraw", label, redraws))  \(missed) of \(shows.count) never published
                """)
            #expect(missed == 0, "\(missed) of \(shows.count) dismisses were never published")
            #expect(!shows.isEmpty, "no drawn Scout card to act on, so the action was not measured")
        }
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func theQueueTheLaunchNoticeAndTheOutOfStepRowLightAndDark() async throws {
        guard Self.enabled, let folder = Self.shots else {
            print("switch-4358 shots: not drawn. Set TEST_RUNNER_MEASURE_4358_SWITCH=1 and "
                  + "TEST_RUNNER_MEASURE_4358_SWITCH_SHOTS=<folder outside any checkout>.")
            return
        }
        let out = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let clone = try #require(try stores().first?.url)
        let container = try Phase0.openContainer(at: clone)
        container.mainContext.autosaveEnabled = false
        let engine = try await HostedQueueEngine.started(context: container.mainContext)
        var written: [String] = []
        func capture(_ window: NSWindow, _ name: String) {
            _ = Phase0cView.settle(window, bodyMustRun: false, seconds: 30) {}
            guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]),
               (try? png.write(to: out.appendingPathComponent("\(name).png"))) != nil {
                written.append(name)
            }
        }
        func small(_ view: some View, _ scheme: ColorScheme, height: CGFloat) -> NSWindow {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            // #4626: drawn as the KEY window's controls are. This window is never ordered front (it must not take
            // Dan's focus), so AppKit draws every control in it as inactive, which greys a prominent button and
            // shows a picture of a state Dan never sees on the screen he is using.
            let hosting = NSHostingView(rootView: AnyView(view.padding(24).frame(maxWidth: .infinity,
                                                                                    maxHeight: .infinity)
                .background(OVColor.canvas)
                .environment(\.controlActiveState, .key)))
            hosting.frame = window.contentLayoutRect
            window.contentView?.addSubview(hosting)
            return window
        }
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .dark ? "dark" : "light"
            let queue = host(container, engine, scheme: scheme)
            capture(queue, "queue-\(name)")
            HostedPassCounting.unmountAndClose(queue)
            var loading = QueueEngineLaunchState()
            loading.firstPaint = .loading(since: Date().addingTimeInterval(-2), attempt: 1)
            let l = small(QueueLaunchView(launch: loading, retry: {}), scheme, height: 220)
            capture(l, "launch-loading-\(name)")
            HostedPassCounting.unmountAndClose(l)
            var failed = QueueEngineLaunchState()
            failed.firstPaint = .failed(.readFailed, attempts: 1, at: Date())
            let f = small(QueueLaunchView(launch: failed, retry: {}), scheme, height: 220)
            capture(f, "launch-failed-\(name)")
            HostedPassCounting.unmountAndClose(f)
            let o = small(OutOfStepRow(onReload: {}), scheme, height: 120)
            capture(o, "out-of-step-\(name)")
            HostedPassCounting.unmountAndClose(o)
        }
        print("switch-4358 shots: \(engine.everyShow.count) shows held, wrote \(written.count) of 8")
        #expect(written.count == 8, "only \(written) were written")
    }
}

// #4626: the one control on the screen shown when the queue engine cannot start wears the design system's primary
// action, the queue's own: `.borderedProminent` tinted forest, as the Prep button on the queue heading is. It was a
// default system button, against the nothing native rule (L607), and it is rare enough to be missed in review.
@MainActor
@Suite("The queue launch screen's Try again is the queue's primary action (#4626)")
struct QueueLaunchRetryStyleTests {
    @Test func tryAgainWearsTheQueuesPrimaryActionStyle() throws {
        var failed = QueueEngineLaunchState()
        failed.firstPaint = .failed(.readFailed, attempts: 1, at: Date())
        let button = try QueueLaunchView(launch: failed, retry: {}).inspect().find(button: QueueLaunchCopy.retry)
        let style = try button.buttonStyle()
        #expect(style is BorderedProminentButtonStyle, Comment(rawValue:
            "Try again is styled \(type(of: style)), not the queue's primary action (#4626, L607)"))
        #expect(try button.tint() == OVColor.forestText,
                "Try again is not tinted forest, so it does not match the queue's Prep button (#4626)")
    }
}
