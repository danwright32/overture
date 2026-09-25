import Foundation

// #4107: one reconcile tick at a time, and never a request lost.
//
// Three things start a tick: the timer, the Downbeat export watcher, and the menu's "Run reconcile now".
// Each used to call the tick directly, and a tick spends most of its life suspended on Gmail, so a second
// request arriving meanwhile started a second tick that interleaved with the first on the main actor and
// paid for the whole of it again, while doing nothing the first was not already doing.
//
// Refusing the second request would be wrong in the other direction. A tick that is already past the
// export read cannot see an export that changed after it, so an export change dropped because a tick was
// running would wait up to half an hour for the timer. So the rule is ONE in flight and ONE queued:
//
//   - nothing running: start now;
//   - one running, none queued: queue exactly one run, to start when the current one finishes, so it
//     sees everything that changed while the current one was running;
//   - one running and one queued: join the queued one, since it has not started and will see this
//     request's change too.
//
// Every caller gets the result of a run that STARTED after it asked, which is what makes joining safe.
@MainActor
final class CoalescingRunner<Result: Sendable> {
    private let body: @MainActor () async -> Result
    private var current: (id: Int, task: Task<Result, Never>)?
    private var queued: (id: Int, task: Task<Result, Never>)?
    private var lastID = 0
    // How many callers are waiting on a result right now. Read by the tests, so "these requests arrived
    // while a run was going" is a fact they can wait on rather than a sleep they hope was long enough.
    private(set) var waiting = 0

    init(_ body: @escaping @MainActor () async -> Result) {
        self.body = body
    }

    func request() async -> Result {
        waiting += 1
        defer { waiting -= 1 }
        if let queued { return await queued.task.value }
        let prior = current?.task
        lastID += 1
        let id = lastID
        let body = self.body
        let task = Task { @MainActor [weak self] in
            if let prior { _ = await prior.value }
            self?.began(id)
            let result = await body()
            self?.ended(id)
            return result
        }
        // Recorded before anything can suspend, so a request arriving next always sees this one.
        if prior == nil { current = (id, task) } else { queued = (id, task) }
        return await task.value
    }

    private func began(_ id: Int) {
        guard queued?.id == id, let promoted = queued else { return }
        current = promoted
        queued = nil
    }

    private func ended(_ id: Int) {
        if current?.id == id { current = nil }
    }
}
