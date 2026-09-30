import Foundation

// #4330 (step A13 of the scout landing plan, discussion #4326): "a landing holds the store".
//
// Two predicates, stated separately, and this is only the second of them.
//
// "A scout run is in flight" stays RootView's #1027 guard (`!isScanning, readingStartedAt == nil` plus
// `ScoutStartGate`). It spans the Run press through the detached read and its ingest, and it is what stops
// a second RUN. It is deliberately NOT lifted in here: the detached read's own ingest is reached while
// `readingStartedAt` is still set, so a landing predicate built from it would refuse its own child.
//
// "A landing holds the store" is this. A token covers ONLY work that touches the store (the design
// correction decided on #4330, 2026-09-29, L110): runScout's network sweep and every other read phase
// await run WITHOUT it, so a paste or an ingest never waits minutes behind a sweep or behind the
// read budget question Dan has not answered yet. Each entry point takes a token at the start of its
// synchronous landing block, after its last read phase await, and ends it straight after its closing save.
//
// It never tells a caller to leave (L1012). `begin` holds a place in a queue and waits; waiters are served
// FIFO within a priority, and a Dan action goes ahead of every scout landing that has not started yet. A
// holder is never preempted: its store writes must finish. The only way out of the queue other than being
// served is the caller's own NAMED deadline, and the refusal it gets then says who was holding the store and
// for how long, so the caller can say why and lose nothing (the ingest keeps a copy of its results; a run
// press says why it did not start).
//
// Today every holder is synchronous (no await between begin and end), so on the main actor a second caller
// can never actually find the store held and the queue is exercised only by tests. That changes with A6's
// recovery (its re-read awaits the network) and A11's async lead paste; the queue exists so those can join
// it rather than interleave with a landing.
@MainActor
final class LandingSingleFlight {
    // The one the app uses. Tests that hold the store across a suspension build their own, so a held token
    // in one test can never make another test's landing wait.
    static let shared = LandingSingleFlight()

    // Every caller that can hold the store, named. The list of CALLERS is derived from the code by
    // `EveryScoutLandingGoesThroughTheSingleFlightTests`, which fails when a caller of `ScoutService.apply`
    // or `ScoutLandingStore.init` that can suspend mid landing does not come through here.
    enum EntryPoint: String, Sendable, CaseIterable {
        // Dan pressed Run while a landing held the store. The press waits its turn, and the sweep starts
        // only once the landing in progress has finished.
        case runPress
        // runScout's synchronous landing block, from the first landed source through the save that follows
        // the last one.
        case runScoutLanding
        // runScout's tail, after the read budget question: the handoff and `lastManualReadAt`, the booking
        // reconcile, the blocked town retirement, and their own save.
        case runScoutTail
        // ScoutExtractIngest's landing block, through its closing save.
        case scoutExtractIngest
    }

    enum Priority: Int, Sendable, Comparable {
        case danAction = 0
        case scout = 1
        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    // Named per caller, sized from what can hold the store ahead of it. Today a landing block holds the
    // store for seconds (0.7 measured the whole landing block of a 4x inserting landing at 7.8 s); A6's
    // recovery re-reads the network under a token, and a full sweep of the watchlist runs for minutes. So
    // each is set well past a landing and past a recovery, and short of never: a Run press left waiting
    // longer than ten minutes is better told why than left looking at an acknowledgement. The ingest waits
    // longest because its refusal is the costliest one to recover from (it is offered again later rather
    // than landing now), and nobody is looking at a screen waiting for it.
    enum Deadline {
        static let runPress: Duration = .seconds(10 * 60)
        static let runScoutLanding: Duration = .seconds(10 * 60)
        static let runScoutTail: Duration = .seconds(10 * 60)
        static let scoutExtractIngest: Duration = .seconds(30 * 60)
    }

    // What a caller gets when its own deadline passes before its turn. It names who was holding the store,
    // so the sentence the caller shows can say why (L11).
    struct Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        let entryPoint: EntryPoint
        let heldBy: EntryPoint?
        let waited: Duration

        var description: String { LandingWaitCopy.refused(entryPoint, waited: waited) }
    }

    // One landing's hold on the store. `end()` is idempotent, so a caller can `defer` it and also end it
    // early on a path that has finished its store work.
    @MainActor
    final class Token {
        let entryPoint: EntryPoint
        let priority: Priority
        private weak var flight: LandingSingleFlight?
        private(set) var hasEnded = false

        fileprivate init(entryPoint: EntryPoint, priority: Priority, flight: LandingSingleFlight) {
            self.entryPoint = entryPoint
            self.priority = priority
            self.flight = flight
        }

        func end() {
            guard !hasEnded else { return }
            hasEnded = true
            flight?.release(self)
        }
    }

    private struct Waiter {
        let order: Int
        let entryPoint: EntryPoint
        let priority: Priority
        let continuation: CheckedContinuation<Token, Error>
        var deadlineTask: Task<Void, Never>?
        let since: ContinuousClock.Instant
    }

    private(set) var holder: Token?
    private var waiters: [Waiter] = []
    private var nextOrder = 0
    private let sleep: @Sendable @MainActor (Duration) async -> Void
    private let now: () -> ContinuousClock.Instant

    // `sleep` and `now` are seams (L524): a test drives a deadline without waiting for it in real time.
    init(sleep: @escaping @Sendable @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.sleep = sleep
        self.now = now
    }

    var isHeld: Bool { holder != nil }

    // Who is waiting, in the order they will be served.
    var queue: [EntryPoint] { waiters.sorted(by: Self.servedFirst).map(\.entryPoint) }

    private static func servedFirst(_ a: Waiter, _ b: Waiter) -> Bool {
        a.priority != b.priority ? a.priority < b.priority : a.order < b.order
    }

    // Holds a place and waits. Returns at once when nothing holds the store. `onWait` runs only when the
    // caller actually has to wait, before it starts to, which is where a caller acknowledges the wait or
    // (the ingest, L665) keeps a copy of what it is holding.
    func begin(entryPoint: EntryPoint, priority: Priority, deadline: Duration,
               onWait: () -> Void = {}) async throws -> Token {
        if holder == nil && waiters.isEmpty {
            let token = Token(entryPoint: entryPoint, priority: priority, flight: self)
            holder = token
            return token
        }
        onWait()
        let order = nextOrder
        nextOrder += 1
        let since = now()
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(Waiter(order: order, entryPoint: entryPoint, priority: priority,
                                  continuation: continuation, deadlineTask: nil, since: since))
            let sleep = self.sleep
            let task = Task { @MainActor [weak self] in
                await sleep(deadline)
                guard !Task.isCancelled else { return }
                self?.expire(order)
            }
            if let i = waiters.firstIndex(where: { $0.order == order }) { waiters[i].deadlineTask = task }
        }
    }

    private func expire(_ order: Int) {
        guard let i = waiters.firstIndex(where: { $0.order == order }) else { return }
        let waiter = waiters.remove(at: i)
        waiter.continuation.resume(throwing: Refusal(entryPoint: waiter.entryPoint,
                                                     heldBy: holder?.entryPoint,
                                                     waited: now() - waiter.since))
    }

    fileprivate func release(_ token: Token) {
        guard holder === token else { return }
        holder = nil
        guard let next = waiters.sorted(by: Self.servedFirst).first,
              let i = waiters.firstIndex(where: { $0.order == next.order }) else { return }
        let waiter = waiters.remove(at: i)
        waiter.deadlineTask?.cancel()
        let granted = Token(entryPoint: waiter.entryPoint, priority: waiter.priority, flight: self)
        holder = granted
        waiter.continuation.resume(returning: granted)
    }

    // A Run press, as a Dan action: when a landing holds the store the press is acknowledged in the words
    // that say what is happening (L100), holds a place at the front of the queue, and returns once the
    // landing in progress has finished, so the sweep starts then. Returns at once when the store is free.
    // Throws the named refusal at its deadline, which the press shows.
    func waitForTurnToStartARun(deadline: Duration = Deadline.runPress,
                                acknowledge: (String) -> Void) async throws {
        let token = try await begin(entryPoint: .runPress, priority: .danAction, deadline: deadline,
                                    onWait: { acknowledge(LandingWaitCopy.runPressWaiting) })
        token.end()
    }

    // MARK: - The landing sequence

    // Which run read a source last, so a landing can tell whether a later run has already touched a source
    // since this one read it (the re-validation `WatchedSource.lastTouchedSequence` is compared against).
    //
    // Minted at the START of a read phase, which writes nothing to the store, so it is minted without the
    // token. It comes from the store and the pending ingest copies (`floor`), never the clock (L186), and it
    // is also above every sequence minted in this process, so two read phases running at once can never be
    // given the same number however their landings interleave.
    private(set) var lastMintedSequence = 0

    func mintSequence(above floor: Int) -> Int {
        let sequence = max(floor, lastMintedSequence) + 1
        lastMintedSequence = sequence
        return sequence
    }
}

// The sentences a landing wait can say. In one place so the inventory shows them together and the two
// surfaces that could show one cannot word it differently.
enum LandingWaitCopy {
    // The acknowledgement a Run press gets when a landing holds the store. Worded for what this step does
    // (L703): the holder is a landing in progress. A6 adds "the interrupted landing" for a recovery.
    static let runPressWaiting = "Your scout will start as soon as the landing in progress finishes."

    static func refused(_ entryPoint: LandingSingleFlight.EntryPoint, waited: Duration) -> String {
        let minutes = max(1, Int((Double(waited.components.seconds) / 60).rounded()))
        let span = minutes == 1 ? "a minute" : "\(minutes) minutes"
        switch entryPoint {
        case .runPress:
            return "Your scout did not start, because another landing was still saving to the store after "
                + "\(span). Nothing was changed. Run the scout again once it has finished."
        case .runScoutLanding:
            return "The scout could not land the shows it found, because another landing was still saving "
                + "to the store after \(span). None of them were applied, and the next scout reads these "
                + "calendars again."
        case .runScoutTail:
            return "The scout saved the shows it found but could not finish, because another landing was "
                + "still saving to the store after \(span). The changed pages were not handed over to be "
                + "read, and the next scout picks them up."
        case .scoutExtractIngest:
            return "The calendar results have not landed yet, because another landing was still saving to "
                + "the store after \(span). Overture kept a copy of them and will offer them again."
        }
    }

    // The ingest was refused AND its copy could not be written, so the sentence above would be false.
    static func ingestRefusedWithoutACopy(_ why: String) -> String {
        "The calendar results have not landed yet, because another landing was still saving to the store, "
            + "and Overture could not keep a copy of them (\(why)). They are still in the reader's results "
            + "file until the next read replaces it."
    }

    // A kept copy landed and could not be removed, so it will be offered, and land, a second time.
    static func copyNotRemoved(_ why: String) -> String {
        "Kept calendar results landed, but their copy could not be removed (\(why)), so Overture will "
            + "offer them again."
    }

    static func pendingUnreadable(path: String, why: String) -> String {
        "Overture could not read kept calendar results at \(path) (\(why))."
    }

    // What the sweep of kept copies says, when it did anything at all. nil when it had nothing to report.
    static func offered(landed: Int, stillWaiting: Int, stuck: Int) -> String? {
        var parts: [String] = []
        if landed > 0 {
            parts.append(landed == 1 ? "Calendar results that had been waiting for the store have landed."
                                     : "\(landed) sets of calendar results that had been waiting for the store have landed.")
        }
        if stillWaiting > 0 {
            parts.append(stillWaiting == 1 ? "One set of calendar results is still waiting for the store."
                                           : "\(stillWaiting) sets of calendar results are still waiting for the store.")
        }
        if stuck > 0 {
            parts.append(stuck == 1
                ? "One set of calendar results has been stuck for over a day without landing. It is kept, and Overture will keep offering it."
                : "\(stuck) sets of calendar results have been stuck for over a day without landing. They are kept, and Overture will keep offering them.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
