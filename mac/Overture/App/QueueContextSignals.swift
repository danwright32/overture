import Foundation
import Observation

// #4356 (plan v7 Phase 2, "each context source with a change signal"): where every input of the queue's
// render pass comes from, and how a change to it is noticed.
//
// Today the pass re-reads every input on every body evaluation, so an input that changes with no store save
// (Gmail disconnecting, a run starting or ending, the Downbeat roster reloading) reaches the screen at the
// next redraw that happens for any other reason. The engine (Phase 4) runs a pass only when something
// changed, so each such input needs its OWN signal, or it reaches the screen only when the 60 second floor
// fires (plan v7 section 4, L51). This table is the list of those inputs, and `QueueInputSourceTests`
// derives it from `QueueRenderPass.Inputs` and `StageContext` by `Mirror`, so a field added to either has
// to be classified here before the suite passes (L96).
enum QueueInputSource: Equatable, Sendable {
    /// Rows the engine keeps facts for; a change arrives as that row's change (`AppSchemaInputClass`).
    case storeRows
    /// A small table handed in whole; a change arrives as a store save.
    case smallTable
    /// The instant and the day, read through `TimeProbe`; a change arrives at the deadline it recorded.
    case clock
    /// Not in the store and not the clock: the app learns of a change only through the signal named in
    /// `QueueContextSignals`, which must exist for every input with this source.
    case signal
    /// The surface's own state (which stage is focused, which cards the last frame drew). A change is the
    /// surface asking for a different view, which it does itself.
    case viewInput
    /// Not an input the engine reads at all, with the reason.
    case notAnInput(reason: String)

    /// Every stored property of `QueueRenderPass.Inputs`, and of the `StageContext` inside it as
    /// `context.<field>`, by its own name.
    static let byInput: [String: QueueInputSource] = [
        "allProspects": .storeRows,
        "inquiries": .storeRows,
        "orgAnswers": .smallTable,
        "sources": .smallTable,
        "refusals": .smallTable,
        "overrides": .smallTable,
        "context.today": .clock,
        "context.now": .clock,
        "context.geo": .smallTable,
        "context.clients": .signal,
        "focusedStage": .viewInput,
        "focusedKeys": .viewInput,
        "gmailConnected": .signal,
        "runInFlight": .signal,
        "prepSlotRunning": .signal,
        "checkSlotRunning": .signal,
        "checkRunSince": .signal,
        "checkLookups": .signal,
        "replyRunAlive": .signal,
        "trace": .notAnInput(reason: """
            A Debug only fingerprint of the caller's own state, recorded beside a derivation and read by \
            nothing in the pass.
            """),
        "requestedCardKeys": .viewInput,
        "cardKeyRegistry": .notAnInput(reason: """
            Where the surface records which cards it drew, for the next pass. Written by the render and \
            never read as an input to this one.
            """),
        "producerTables": .notAnInput(reason: """
            A prebuilt copy of a value the pass derives from its own store inputs. The engine owns that \
            table and patches it (plan v7 T4); it is never an input in its own right.
            """),
    ]
}


// #4356 (plan v7 Phase 2): one change signal per queue input that is neither a store row nor the clock.
//
// `QueueInputSource.byInput` names every such input `.signal`; this builds the signal for each, from the
// objects the app already keeps for exactly these facts, so nothing here adds a second way of knowing:
//
//   * Gmail: `GmailConnection.isConnected`, which is `@Observable` (#1770).
//   * The client window: `ClientRoster.clients`, `@Observable`, reloaded when the Downbeat export changes.
//   * Each run slot and the reply run: `DetachedRunActivity.isRunning`, `@Observable`, told when the app
//     starts a run and polling only while one is live, to notice it end (#1923).
//   * The check's lookup count, which moves while a check runs and is written to a marker on disk: polled
//     at the SAME interval the check slot's activity follows its run at, and only while that run is live,
//     so an idle queue pays nothing for it (#1923's rule).
//
// An observed signal fires only when the value really differs from the last one it saw, because
// Observation reports a WRITE, and `ClientRoster.reload` writes the roster even when nothing changed.
//
// NOTHING STARTS THESE YET. The queue engine (Phase 4, #4358) starts them and runs a pass when one fires.
@MainActor
final class ContextSignal {
    let input: String
    private(set) var isLive = true
    /// How many times an observed signal has looked at its value after a write, fired or not. Lets a test
    /// wait for a look that must NOT fire, which has no other visible trace.
    fileprivate(set) var looks = 0
    /// Whether a polled signal is reading right now. True only while its run is live, so a test can wait
    /// for the polling to stop when the run ends.
    fileprivate(set) var isPolling = false
    fileprivate var task: Task<Void, Never>?

    fileprivate init(input: String) {
        self.input = input
    }

    func cancel() {
        isLive = false
        task?.cancel()
    }
}

@MainActor
enum QueueContextSignals {
    /// The app objects the signals read. Each is injected so a test flips its own copy and never the app's.
    struct Sources {
        let gmail: GmailConnection
        let roster: ClientRoster
        let prep: DetachedRunActivity
        let check: DetachedRunActivity
        let reply: DetachedRunActivity
        /// `PrepQueueService.liveCheckLookups` in the app: the check's lookup count, read from its marker.
        let checkLookups: @MainActor @Sendable () -> Int?
        let sleep: @MainActor @Sendable (TimeInterval) async -> Void
    }

    /// One signal for every `.signal` input, each calling `onChange` with that input's name.
    static func start(_ sources: Sources,
                      onChange: @escaping @MainActor @Sendable (String) -> Void) -> [String: ContextSignal] {
        let gmail = sources.gmail
        let roster = sources.roster
        let prep = sources.prep
        let check = sources.check
        let reply = sources.reply
        var out: [String: ContextSignal] = [:]
        out["gmailConnected"] = observing("gmailConnected", { gmail.isConnected }, onChange)
        out["context.clients"] = observing("context.clients", { roster.clients }, onChange)
        out["prepSlotRunning"] = observing("prepSlotRunning", { prep.isRunning }, onChange)
        out["checkSlotRunning"] = observing("checkSlotRunning", { check.isRunning }, onChange)
        // `runInFlight` and the check's start are each decided from the two slots together, so each moves
        // exactly when either slot does.
        out["runInFlight"] = observing("runInFlight", { [prep.isRunning, check.isRunning] }, onChange)
        out["checkRunSince"] = observing("checkRunSince", { check.isRunning }, onChange)
        out["replyRunAlive"] = observing("replyRunAlive", { reply.isRunning }, onChange)
        out["checkLookups"] = pollingWhileLive("checkLookups", run: check, read: sources.checkLookups,
                                               sleep: sources.sleep, onChange)
        return out
    }

    /// A signal that fires whenever `read`, which reads `@Observable` state, returns a different value.
    static func observing<Value: Equatable & Sendable>(
        _ input: String, _ read: @escaping @MainActor @Sendable () -> Value,
        _ onChange: @escaping @MainActor @Sendable (String) -> Void) -> ContextSignal {
        let signal = ContextSignal(input: input)
        arm(signal, read: read, last: read(), onChange: onChange)
        return signal
    }

    // Observation tracks ONE change and then stops, so every fire re-arms. The re-read happens on the next
    // main actor turn, after the write that triggered it has landed, because `onChange` is called before
    // the new value is stored.
    private static func arm<Value: Equatable & Sendable>(
        _ signal: ContextSignal, read: @escaping @MainActor @Sendable () -> Value, last: Value,
        onChange: @escaping @MainActor @Sendable (String) -> Void) {
        withObservationTracking {
            _ = read()
        } onChange: {
            Task { @MainActor in
                guard signal.isLive else { return }
                let current = read()
                signal.looks += 1
                if current != last { onChange(signal.input) }
                arm(signal, read: read, last: current, onChange: onChange)
            }
        }
    }

    /// A signal over a value that changes on disk while `run` is live: read at the run's own follow
    /// interval while it is, and not at all while it is not.
    static func pollingWhileLive<Value: Equatable & Sendable>(
        _ input: String, run: DetachedRunActivity, read: @escaping @MainActor @Sendable () -> Value,
        sleep: @escaping @MainActor @Sendable (TimeInterval) async -> Void,
        _ onChange: @escaping @MainActor @Sendable (String) -> Void) -> ContextSignal {
        let signal = ContextSignal(input: input)
        let interval = run.pollInterval
        // The starting value is read HERE, as the signal starts, so a change made before the loop is first
        // scheduled is still a change rather than the value it starts from.
        let initial = read()
        signal.task = Task { @MainActor in
            var last = initial
            for await _ in run.runStarts() {
                signal.isPolling = true
                defer { signal.isPolling = false }
                while run.isRunning && signal.isLive && !Task.isCancelled {
                    await sleep(interval)
                    let current = read()
                    if current != last {
                        last = current
                        onChange(input)
                    }
                }
                if !signal.isLive || Task.isCancelled { return }
            }
        }
        return signal
    }
}
