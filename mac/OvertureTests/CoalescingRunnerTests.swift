import Testing
import Foundation

// #4107: the timer, the export watcher and the menu's run each start a reconcile tick, and a tick spends
// most of its life suspended on Gmail. `CoalescingRunner` keeps one in flight and one queued. Held here:
// overlapping requests run the body twice, not once per request; the queued run starts only after the
// running one ends, so it sees what changed meanwhile; and nobody is handed a result from before they asked.
@MainActor
@Suite("Reconcile ticks coalesce without losing a request (#4107)")
struct CoalescingRunnerTests {

    // A body that parks until the test lets it go, and reports what the world looked like when it STARTED.
    @MainActor
    final class Gate {
        var started = 0
        var finished = 0
        var world = 0
        var running = 0
        var mostAtOnce = 0
        private var open = false
        private var parked: [CheckedContinuation<Void, Never>] = []

        func release() {
            open = true
            parked.forEach { $0.resume() }
            parked = []
        }

        func body() async -> Int {
            started += 1
            running += 1
            mostAtOnce = max(mostAtOnce, running)
            let seen = world
            if !open { await withCheckedContinuation { parked.append($0) } }
            running -= 1
            finished += 1
            return seen
        }
    }

    @Test func requestsDuringARunCostOneMoreRunNotOneEach() async {
        let gate = Gate()
        let runner = CoalescingRunner { await gate.body() }

        let first = Task { await runner.request() }
        #expect(await waitUntil("the first run starts") { gate.started == 1 })
        let joiners = (0..<3).map { _ in Task { await runner.request() } }
        #expect(await waitUntil("all four callers are waiting") { runner.waiting == 4 })
        gate.release()
        _ = await first.value
        for j in joiners { _ = await j.value }

        #expect(gate.started == 2, "three requests during a run must share ONE queued run")
        #expect(gate.mostAtOnce == 1, "two ticks ran at once")
    }

    @Test func theQueuedRunSeesAChangeMadeWhileTheFirstWasRunning() async {
        let gate = Gate()
        let runner = CoalescingRunner { await gate.body() }

        let first = Task { await runner.request() }
        #expect(await waitUntil("the first run starts") { gate.started == 1 })
        gate.world = 7                         // the export changes while the first tick is suspended
        let second = Task { await runner.request() }
        #expect(await waitUntil("the second request is waiting") { runner.waiting == 2 })
        gate.release()

        #expect(await first.value == 0)
        #expect(await second.value == 7, "the change made mid run was dropped instead of rerun")
    }

    @Test func aRequestAfterARunFinishesStartsAFreshOne() async {
        let gate = Gate()
        gate.release()
        let runner = CoalescingRunner { await gate.body() }

        _ = await runner.request()
        gate.world = 3
        let later = await runner.request()

        #expect(gate.started == 2)
        #expect(later == 3)
    }

    // The wiring, which the runner's own tests cannot see: every place that STARTS a tick goes through the
    // runner. A caller calling the tick directly would overlap it again. Scoped to each function's own body,
    // so a mention elsewhere in the file cannot answer for it (L135).
    @Test func everyPlaceThatStartsATickGoesThroughTheRunner() throws {
        let source = SourceGuardHelper.source("Overture/App/ReconcileScheduler.swift")
        for name in ["start", "runNow"] {
            let body = try SourceGuard.functionBody(named: name, in: source)
            #expect(body.contains("ticks.request()"), "\(name) does not start its tick through the runner")
            #expect(!body.contains("runSafeReconcilesOnce("), "\(name) starts a tick directly, so ticks can overlap")
        }
    }
}
