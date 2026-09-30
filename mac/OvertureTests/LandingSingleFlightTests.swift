import Testing
import Foundation

// #4330 (A13): the queue itself. The integration half (the scout's own entry points going through it) is
// `ScoutLandingsWaitTheirTurnTests`; this pins the rules every caller relies on, with the deadline driven
// by an injected sleep so nothing here waits in real time (L524).
@MainActor
@Suite("A landing holds the store one at a time, and waiters keep their place (#4330)")
struct LandingSingleFlightTests {
    // A sleep that returns only when the test says so, so a deadline passes exactly when the test decides.
    @MainActor
    final class ManualDeadlines {
        private var pending: [CheckedContinuation<Void, Never>] = []
        var count: Int { pending.count }
        func sleep(_ d: Duration) async {
            await withCheckedContinuation { pending.append($0) }
        }
        func passAll() {
            let all = pending
            pending = []
            all.forEach { $0.resume() }
        }
    }

    private func waitFor(_ flight: LandingSingleFlight, queued n: Int) async {
        await waitUntil("\(n) waiters queued") { flight.queue.count == n }
    }

    @Test func aFreeStoreIsGrantedAtOnceAndOnWaitIsNotCalled() async throws {
        let flight = LandingSingleFlight(sleep: { _ in })
        var waited = false
        let token = try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout,
                                           deadline: .seconds(1), onWait: { waited = true })
        #expect(flight.isHeld)
        #expect(!waited, "a caller that did not wait was told it was waiting")
        token.end()
        #expect(!flight.isHeld)
        token.end()   // idempotent
        #expect(!flight.isHeld)
    }

    // L1012: a caller that finds the store held waits for it, and is served when it is free. Never told to
    // go away because somebody was ahead of it.
    @Test func aCallerThatFindsTheStoreHeldWaitsAndIsServedWhenItIsReleased() async throws {
        let deadlines = ManualDeadlines()
        let flight = LandingSingleFlight(sleep: { await deadlines.sleep($0) })
        let first = try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(1))
        var waited = false
        var served = false
        let second = Task { @MainActor in
            let t = try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout,
                                           deadline: .seconds(1), onWait: { waited = true })
            served = true
            return t
        }
        await waitFor(flight, queued: 1)
        #expect(waited)
        #expect(!served, "the second landing was let in while the first still held the store")
        first.end()
        let token = try await second.value
        #expect(served)
        #expect(flight.holder === token)
        token.end()
        deadlines.passAll()
    }

    // FIFO within a priority, and a Dan action ahead of every scout landing that has not started yet.
    @Test func danActionsAreServedAheadOfScoutLandingsAndEachLaneIsFirstInFirstOut() async throws {
        let deadlines = ManualDeadlines()
        let flight = LandingSingleFlight(sleep: { await deadlines.sleep($0) })
        let holder = try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(1))
        var served: [String] = []
        func queue(_ name: String, _ entry: LandingSingleFlight.EntryPoint,
                   _ priority: LandingSingleFlight.Priority) -> Task<Void, Error> {
            Task { @MainActor in
                let t = try await flight.begin(entryPoint: entry, priority: priority, deadline: .seconds(1))
                served.append(name)
                t.end()
            }
        }
        let a = queue("scout 1", .scoutExtractIngest, .scout)
        await waitFor(flight, queued: 1)
        let b = queue("scout 2", .scoutExtractIngest, .scout)
        await waitFor(flight, queued: 2)
        let c = queue("dan 1", .runPress, .danAction)
        await waitFor(flight, queued: 3)
        let d = queue("dan 2", .runScoutLanding, .danAction)
        await waitFor(flight, queued: 4)
        #expect(flight.queue == [.runPress, .runScoutLanding, .scoutExtractIngest, .scoutExtractIngest])

        holder.end()
        for t in [a, b, c, d] { try await t.value }
        #expect(served == ["dan 1", "dan 2", "scout 1", "scout 2"])
        #expect(!flight.isHeld)
        deadlines.passAll()
    }

    // A holder is never preempted: a Dan action arriving while a landing holds the store waits for it.
    @Test func aDanActionDoesNotPreemptTheHolder() async throws {
        let deadlines = ManualDeadlines()
        let flight = LandingSingleFlight(sleep: { await deadlines.sleep($0) })
        let holder = try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(1))
        let press = Task { @MainActor in
            try await flight.begin(entryPoint: .runPress, priority: .danAction, deadline: .seconds(1))
        }
        await waitFor(flight, queued: 1)
        #expect(flight.holder === holder)
        holder.end()
        let t = try await press.value
        #expect(t.entryPoint == .runPress)
        t.end()
        deadlines.passAll()
    }

    // The named deadline: a refusal that says who held the store, and leaves the queue behind it intact.
    @Test func aWaiterPastItsDeadlineIsRefusedByNameAndTheQueueCarriesOn() async throws {
        let deadlines = ManualDeadlines()
        var clock = ContinuousClock.now
        let flight = LandingSingleFlight(sleep: { await deadlines.sleep($0) }, now: { clock })
        let holder = try await flight.begin(entryPoint: .runScoutLanding, priority: .danAction, deadline: .seconds(1))
        let refused = Task { @MainActor in
            try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout,
                                   deadline: LandingSingleFlight.Deadline.scoutExtractIngest)
        }
        await waitFor(flight, queued: 1)
        await waitUntil("the deadline armed") { deadlines.count == 1 }
        clock = clock.advanced(by: .seconds(30 * 60))
        deadlines.passAll()
        do {
            _ = try await refused.value
            Issue.record("a waiter past its deadline was served instead of refused")
        } catch let refusal as LandingSingleFlight.Refusal {
            #expect(refusal.entryPoint == .scoutExtractIngest)
            #expect(refusal.heldBy == .runScoutLanding)
            #expect(refusal.waited == .seconds(30 * 60))
            #expect(refusal.description == LandingWaitCopy.refused(.scoutExtractIngest, waited: .seconds(30 * 60)))
            #expect(refusal.description.contains("30 minutes"))
        }
        #expect(flight.queue.isEmpty)
        #expect(flight.holder === holder, "a refusal released a store it never held")

        // And the next caller is still served normally once the holder finishes.
        let later = Task { @MainActor in
            try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(1))
        }
        await waitFor(flight, queued: 1)
        holder.end()
        let t = try await later.value
        t.end()
        #expect(!flight.isHeld)
        deadlines.passAll()
    }

    // A waiter served before its deadline is never refused afterwards.
    @Test func aServedWaitersDeadlineNeverFires() async throws {
        let deadlines = ManualDeadlines()
        let flight = LandingSingleFlight(sleep: { await deadlines.sleep($0) })
        let holder = try await flight.begin(entryPoint: .runScoutLanding, priority: .scout, deadline: .seconds(1))
        let waiter = Task { @MainActor in
            try await flight.begin(entryPoint: .scoutExtractIngest, priority: .scout, deadline: .seconds(1))
        }
        await waitFor(flight, queued: 1)
        holder.end()
        let token = try await waiter.value
        deadlines.passAll()
        await Task.yield()
        #expect(flight.holder === token, "a deadline that fired after the waiter was served took its place")
        token.end()
    }

    @Test func theSequenceClimbsAboveTheStoreAndAboveEverythingMintedBefore() {
        let flight = LandingSingleFlight(sleep: { _ in })
        #expect(flight.mintSequence(above: 0) == 1)
        #expect(flight.mintSequence(above: 0) == 2, "two read phases in one process were given the same number")
        #expect(flight.mintSequence(above: 40) == 41)
        #expect(flight.mintSequence(above: 3) == 42)
    }

    @Test func everyRefusalSentenceIsDistinctAndNamesTheWait() {
        let all = LandingSingleFlight.EntryPoint.allCases.map { LandingWaitCopy.refused($0, waited: .seconds(600)) }
        #expect(Set(all).count == all.count)
        for sentence in all { #expect(sentence.contains("10 minutes")) }
        #expect(LandingWaitCopy.refused(.runPress, waited: .seconds(50)).contains("a minute"))
    }
}
