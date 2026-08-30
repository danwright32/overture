import Testing
import Foundation

// #3234: the four suites that drive the network through `PageStubURLProtocol` share ONE bag of state.
//
// That stub is a `URLProtocol` subclass, and everything a test sets on it (the status, the body, the
// per-URL tables, the record of what was requested) lives in `static var`s on the class. There is one
// of each, per process. Each test resets them and then sets its own, which is correct while exactly one
// test is running and wrong the instant two are: measured 2026-08-30 on the first parallel run of this
// suite, 11 of the 15 failures were these four suites overwriting each other's stub.
//
// `.serialized` does not close it. It orders the tests WITHIN one suite, and these are four suites, so
// they still run beside each other. `SourceFetcherTests` already carries `.serialized` and still failed.
//
// The remedy is a lock the four of them share, which is the same shape `RealStoreTestLock` already uses
// here for the suites that touch the real store, and it is applied as a TRAIT rather than by wrapping
// every test body: one line on each suite declaration, against about thirty tests across four files
// where an acquire and release written by hand is thirty chances to forget the release on a throwing
// path.
//
// What it costs is that these four suites run one at a time. They are about four seconds together, so
// the trade is the whole point: the expensive suites still run in parallel, and the ones that cannot
// are named rather than left to fail intermittently.
//
// It is deliberately NOT the isolation #3234 first proposed (a token per session, so the stubs cannot
// see each other). That is the better answer and it stays available, but it means rewriting every one
// of the roughly one hundred places a test sets a field on the stub, and this closes the defect now
// with a change that can be read in one screen.
actor SharedStateTestLock {
    // One lock per NAMED family of shared state, so two families that have nothing to do with each other
    // do not serialise against each other. The registry itself is an actor, so handing out a lock is
    // safe from any thread.
    private static let registry = Registry()

    private actor Registry {
        private var locks: [String: SharedStateTestLock] = [:]
        func lock(named name: String) -> SharedStateTestLock {
            if let existing = locks[name] { return existing }
            let made = SharedStateTestLock()
            locks[name] = made
            return made
        }
    }

    static func named(_ name: String) async -> SharedStateTestLock { await registry.lock(named: name) }

    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !isLocked {
            isLocked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        guard !waiters.isEmpty else {
            isLocked = false
            return
        }
        waiters.removeFirst().resume()
    }
}

// The trait. `isRecursive` so putting it on a suite covers every test in it, and the release happens on
// every exit path including a throw, because a lock left held by a failing test turns one failure into
// a run that never ends.
struct SharesGlobalState: TestTrait, SuiteTrait, TestScoping {
    let name: String
    var isRecursive: Bool { true }

    func provideScope(for test: Test,
                      testCase: Test.Case?,
                      performing function: () async throws -> Void) async throws {
        let lock = await SharedStateTestLock.named(name)
        await lock.acquire()
        do {
            try await function()
        } catch {
            await lock.release()
            throw error
        }
        await lock.release()
    }
}

extension Trait where Self == SharesGlobalState {
    /// The four suites that drive the network through `PageStubURLProtocol`'s process-global statics.
    static var sharesTheNetworkStub: Self { Self(name: "PageStubURLProtocol") }

    /// The three suites that read `QueueRenderCounter`, which is one counter for the whole process:
    /// each of them resets it and reads it back, which is correct only while one of them runs at a time.
    /// Measured 2026-08-30, it went red once in a parallel run and passed in the run before it, which is
    /// the shape that trains people to re-run until green (#3234).
    static var sharesTheRenderCounter: Self { Self(name: "QueueRenderCounter") }
}
