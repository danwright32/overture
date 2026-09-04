import Foundation

// #3419 / #3433: somewhere for a BLOCKING call to run that is neither the main actor nor the shared
// cooperative pool.
//
// The main actor is where AppKit draws and handles events, so a synchronous Apple event sent from
// there takes the whole window down for its duration rather than the one surface that asked (L236).
// Measured on 2026-08-31: 2,646 of 2,646 samples over three seconds sat in one `AESendMessage`,
// with no other main thread activity at all, and Dan's app was unusable throughout.
//
// The cooperative pool is not the answer either. It is bounded and does not grow, so a blocking item
// on it starves every other concurrent task in the process (L241). This is a serial DispatchQueue,
// whose pool libdispatch does grow, so the one blocked thread costs nothing else.
//
// Two properties beyond "off the main actor", both of which the OmniFocus path needed and had not:
//
//   - A DEADLINE. A wait with no deadline cannot fail, it can only hang, and a hang is worse than a
//     failure because it is indistinguishable from slowness (L110). Nothing in the old path would
//     have ended the freeze if OmniFocus had never answered.
//   - A REFUSAL while one item is outstanding. The deadline releases the CALLER, not the work: an
//     Apple event already sent cannot be recalled. The reconcile fires at launch, every 30 minutes
//     and on every Downbeat export change, so without this an unanswered OmniFocus would collect one
//     more queued event every half hour for the life of the process.
enum BlockingWorkError: Error, Equatable {
    // The caller stopped waiting. The work itself may still be running: see the type's note.
    case timedOut(seconds: Double)
    // A previous item has not returned, so this one was never submitted.
    case busy
}

final class BlockingWorkThread: @unchecked Sendable {
    private let queue: DispatchQueue
    private let state = NSLock()
    private var outstanding = false

    init(name: String) {
        queue = DispatchQueue(label: "com.danwright.overture.blocking.\(name)")
    }

    // Whether an item submitted here has yet to return. Public because it is the difference between
    // "OmniFocus refused" and "OmniFocus has not answered the last one", which are different sentences
    // to whoever pressed the button (L11).
    var isBusy: Bool {
        state.lock()
        defer { state.unlock() }
        return outstanding
    }

    // Both halves of the outstanding flag, kept SYNCHRONOUS: `NSLock.lock()` is unavailable from an
    // async context, and the point of the rule is that a lock must not be held across a suspension.
    // Neither of these suspends, so the flag is safe and `run` stays async.
    private func claimTheThread() -> Bool {
        state.lock()
        defer { state.unlock() }
        if outstanding { return false }
        outstanding = true
        return true
    }

    private func releaseTheThread() {
        state.lock()
        defer { state.unlock() }
        outstanding = false
    }

    // Runs `work` off the main actor and waits at most `deadlineSeconds` for it.
    //
    // `sleep` is a seam so a test can cross the deadline without waiting for real time: a deadline
    // test that waits is asserting about what else the machine is running rather than about the
    // outcome (L224, L290, L524).
    //
    // The work's own error is rethrown UNWRAPPED, because the OmniFocus callers classify by it and a
    // marker meant to be read by code must reach its reader intact (L199).
    func run<T: Sendable>(deadlineSeconds: Double,
                          sleep: @escaping @Sendable (Double) async -> Void = {
                              try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
                          },
                          _ work: @escaping @Sendable () throws -> T) async throws -> T {
        guard claimTheThread() else { throw BlockingWorkError.busy }

        let settled = FirstAnswer<T>()
        queue.async { [self] in
            let result = Result { try work() }
            // Cleared BEFORE the answer is handed over, so a caller woken by this item can submit the
            // next one immediately rather than racing its own predecessor's bookkeeping.
            releaseTheThread()
            settled.answer(result)
        }
        let deadline = Task {
            await sleep(deadlineSeconds)
            settled.answer(.failure(BlockingWorkError.timedOut(seconds: deadlineSeconds)))
        }
        defer { deadline.cancel() }
        return try await settled.value()
    }
}

// One answer, whoever gets there first, for exactly one waiter. The work thread and the deadline both
// race to supply it, and the loser is a no-op rather than a second resume, which would trap.
private final class FirstAnswer<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var arrivedEarly: Result<T, Error>?
    private var answered = false

    func answer(_ result: Result<T, Error>) {
        lock.lock()
        if answered {
            lock.unlock()
            return
        }
        answered = true
        let waiting = continuation
        continuation = nil
        // The answer can beat the waiter to the lock, so it is held rather than dropped.
        if waiting == nil { arrivedEarly = result }
        lock.unlock()
        waiting?.resume(with: result)
    }

    func value() async throws -> T {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if let early = arrivedEarly {
                arrivedEarly = nil
                lock.unlock()
                c.resume(with: early)
            } else {
                continuation = c
                lock.unlock()
            }
        }
    }
}

extension BlockingWorkThread {
    // #3419: ONE worker for OmniFocus across the whole process, shared by both sync call sites.
    // Per-site workers would each refuse only their own overlap, so the launch sync and a reconcile
    // tick could still put two Apple events into OmniFocus at once, which is the state the refusal
    // exists to prevent.
    static let omniFocus = BlockingWorkThread(name: "omnifocus")
}
