import Testing
import Foundation
import Network

// Regression guard for #51: the OAuth loopback listener must report the OS-assigned
// port only after it is actually bound. Reading it too early returned 0, which made
// the redirect_uri http://127.0.0.1:0 — an un-connectable address that left Google's
// consent page hanging forever.
//
// Coverage note (#88): these assert the listener reaches `.ready` and hands back a real,
// non-zero port bound to the 127.0.0.1 (IPv4) endpoint it was pinned to — which is exactly
// what #51 needs (a connectable IPv4 redirect address, never :0). An earlier test opened a
// live TCP round-trip to that port; on this loopback setup the client routinely never reached
// `.ready` (it sat retrying), which froze the whole `xcodebuild test` run for minutes. A live
// socket round-trip is the wrong thing to assert in a unit test, so it was removed in favor of
// these fast, deterministic bind checks.
@Suite("Loopback OAuth listener")
struct LoopbackListenerTests {

    // #3266: every bound in this file has to survive a SATURATED machine, and both halves of that are
    // measured rather than guessed.
    //
    // These are the only tests in the tree that bound a real network operation by the wall clock, so
    // they are the only ones whose verdict moves with what else the machine is running (L290, L224).
    // Under `-parallel-testing-enabled YES` Swift Testing runs the tests of one process concurrently and
    // this suite's thousands of synchronous source scans and SQLite clones keep the thread pool busy, so
    // a callback that arrives in milliseconds on an idle Mac can arrive tens of seconds later.
    // Measured 2026-08-30: `LoopbackListener.start(timeout: 5)` reported `failed (45.464 seconds)`,
    // which is not a bind that was refused but a listener whose readiness was not scheduled.
    //
    // Two changes, and the first is the one that addresses the CAUSE. The queue is now a dedicated
    // serial one, which is what GmailAuthManager actually passes
    // (`DispatchQueue(label: "com.danwright.overture.gmail-loopback")`). These tests used `.global()`,
    // the shared concurrent queue every other piece of background work on the machine is also queued
    // on, so the one thing separating them from the shipped path was the thing making them flaky (L52).
    //
    // The ceiling is the second half, and it is deliberately far above any real bind rather than near
    // one. What it exists for is a WEDGED listener, so that a hang becomes a failure (L110); it is not a
    // performance assertion, and setting it anywhere near a healthy bind's real duration would make it
    // one. Nothing here waits for it on the happy path.
    private static let wedgedCeiling: TimeInterval = 90

    /// A dedicated serial queue, the shape production uses, rather than the shared `.global()` one.
    private func listenerQueue(_ label: String) -> DispatchQueue {
        DispatchQueue(label: "overture-test-loopback-\(label)")
    }

    // The shipped default has a reader, which it would otherwise lose the moment these tests stopped
    // running at it. It is short because a person is waiting on it, and the tests are long because a
    // saturated machine is not a person: those are different numbers for different reasons, and the one
    // that ships is this one.
    @Test func thebindGivesUpQuicklyEnoughForSomebodyWaitingOnIt() {
        #expect(LoopbackListener.defaultTimeout <= 15,
                "Connect Gmail waits \(LoopbackListener.defaultTimeout)s on a wedged bind before saying so, which is a person watching a control that did nothing (#54)")
        #expect(LoopbackListener.defaultTimeout > 0,
                "a zero timeout would refuse every bind before it could report ready")
        #expect(Self.wedgedCeiling > LoopbackListener.defaultTimeout,
                "the tests' ceiling must be looser than the shipped one, or they measure the machine rather than the listener")
    }

    @Test func bindsToARealNonZeroPort() async throws {
        let (listener, port) = try await LoopbackListener.start(queue: listenerQueue("non-zero-port"),
                                                                timeout: Self.wedgedCeiling) { conn in
            conn.cancel()
        }
        defer { listener.cancel() }
        #expect(port != 0)
    }

    @Test func bindsSuccessfullyWithinAnExplicitTimeout() async throws {
        // The bind timeout (#54) must not interfere with the normal, fast happy path.
        let (listener, port) = try await LoopbackListener.start(queue: listenerQueue("explicit-timeout"),
                                                                timeout: Self.wedgedCeiling) { $0.cancel() }
        defer { listener.cancel() }
        #expect(port != 0)
    }

    // --- #3409: a bind that is refused at one instant and granted at the next ---------------------
    //
    // A full parallel run on 2026-08-31 went red with three failures, all in this suite, all
    // `POSIXErrorCode(rawValue: 49): Can't assign requested address`, and the very next run of the same
    // tree passed all three. EADDRNOTAVAIL is not a port collision (that is 48) and 127.0.0.1 does not
    // stop being a local address, so the reading that fits is a bind refused at that instant.
    //
    // Neither of the two causes #3409 offered turned out to be it, and that was MEASURED rather than
    // reasoned: `scripts/../loopback-probe` bound 400 listeners at once with the shipped parameters, and
    // then 400 more with `allowLocalEndpointReuse` off, and every one of the 800 reached `.ready`. So the
    // parameters are not the cause and neither is the number of listeners. What is left is a transient
    // condition, and what a transient condition wants is not a different address but another attempt.
    //
    // The retry is bounded, shares the caller's own deadline rather than extending it, and fires only on
    // the failures that can plausibly clear. A permanent one (no permission, no route) must still fail at
    // once: retrying that spends a person's whole timeout to reach the same answer more slowly.
    @Test func aBindRefusedAtThisInstantIsWorthAnotherAttempt() {
        #expect(LoopbackListener.isTransientBindFailure(
            "POSIXErrorCode(rawValue: 49): Can't assign requested address"))
        #expect(LoopbackListener.isTransientBindFailure(
            "POSIXErrorCode(rawValue: 48): Address already in use"))
    }

    @Test func aPermanentBindFailureIsNotRetried() {
        #expect(!LoopbackListener.isTransientBindFailure(
            "POSIXErrorCode(rawValue: 1): Operation not permitted"))
        #expect(!LoopbackListener.isTransientBindFailure(
            "POSIXErrorCode(rawValue: 65): No route to host"))
        #expect(!LoopbackListener.isTransientBindFailure(""))
        // The numbers are read as whole numbers, not as digits inside a longer one: 490 is not 49.
        #expect(!LoopbackListener.isTransientBindFailure(
            "POSIXErrorCode(rawValue: 490): Something else entirely"))
    }

    // The retry may not buy itself more time than the caller allowed. A person pressing Connect Gmail
    // waits `defaultTimeout` once, not once per attempt, which is the difference between a retry and a
    // hang wearing a retry's name (L110).
    @Test func theRetriesShareTheCallersDeadlineRatherThanExtendingIt() {
        #expect(LoopbackListener.remainingBudget(deadline: 100, now: 90) == 10)
        #expect(LoopbackListener.remainingBudget(deadline: 100, now: 100) == 0)
        #expect(LoopbackListener.remainingBudget(deadline: 100, now: 130) == 0,
                "a budget past its deadline must never come back negative and be read as forever")
    }

    @Test func theBindIsAttemptedMoreThanOnceAndABoundedNumberOfTimes() {
        #expect(LoopbackListener.bindAttempts > 1, "one attempt is no retry at all")
        #expect(LoopbackListener.bindAttempts <= 4,
                "an unbounded retry spends the whole timeout on a failure that was never going to clear")
    }

    // A one-shot latch so a connection's state handler resolves the round-trip exactly once.
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    // The live round-trip the header notes was removed for "routinely never reaching .ready": that WAS
    // the bug. The bind-timeout task did `try? await Task.sleep` then `listener.cancel()`; when .ready
    // fired and cancelled that task, the swallowed cancellation fell through to cancel the just-ready
    // listener, so a client could never connect (and Google's redirect hit a dead port). With the sleep's
    // cancellation propagated, a ready listener stays alive and accepts. A 3s ceiling keeps this from ever
    // freezing the suite the way the old version did.
    @Test func aReadyListenerStaysAliveAndAcceptsAConnection() async throws {
        let queue = listenerQueue("roundtrip")
        let (listener, port) = try await LoopbackListener.start(queue: queue) { conn in
            conn.start(queue: queue)
            conn.send(content: Data("hi".utf8), completion: .contentProcessed { _ in conn.cancel() })
        }
        defer { listener.cancel() }

        let connected: Bool = await withCheckedContinuation { cont in
            let once = Once()
            let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            client.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.fire() { cont.resume(returning: true) }; client.cancel()
                case .failed, .cancelled: if once.fire() { cont.resume(returning: false) }
                default: break
                }
            }
            client.start(queue: queue)
            // The same ceiling and for the same reason: it is what turns a connection that never
            // resolves into a failure rather than a hang, not a budget for how fast a loopback connect
            // ought to be. At three seconds this was the tightest bound in the file and the one a loaded
            // machine reached first.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.wedgedCeiling * 1_000_000_000))
                if once.fire() { cont.resume(returning: false) }
            }
        }
        #expect(connected)
    }
}
