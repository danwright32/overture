import Foundation
import SwiftData
import Testing

// #4358 (plan v7 D6 and decision 4, slice E3): the queue engine's launch. The first output comes from one read of
// the saved store OFF the main thread, and nothing is published before it lands; then the engine's own rows (the
// ones its trackers watch) fill in keyset batches of 20 on a byte order sort, one batch per main actor turn, each
// timed against plan v7's 16 ms; the inquiries follow in one fetch; and a read of every stored identifier finds any
// row the keyset skipped, which is admitted and counted. One test PRODUCES each state the surface can show
// (loading, failed for each reason, ready; filling, failed, done) and each shortfall outcome (L151). The store,
// schedule, clock and counting derivation are `QueueEngineIntakeTests.swift`'s, and the held read is the verifier
// suite's.
//
// Every "the store says" is a fresh read through a context of its own, never the engine's own records (L70).

/// Engines built for a launch test: the launch setup is the test's subject, so every test names it.
@MainActor
enum LaunchRig {
    static func engine(_ store: EngineStore, _ turns: EngineTurns, launch: QueueEngineLaunchSetup,
                       clock: EngineTestClock = EngineTestClock(), saves: StoreSaveCount = StoreSaveCount(),
                       saveCenter: NotificationCenter = .default,
                       verifier: QueueEngineVerifierSetup = QueueEngineVerifierSetup(triggers: .byHand)) -> CountsEngine {
        QueueEngine(context: store.context, derivation: EngineDerivations.counts(), saves: saves, clock: clock.clock,
                    events: QueueEngineSystemEvents(workspace: NotificationCenter(), system: NotificationCenter()),
                    saveCenter: saveCenter, schedule: turns.schedule,
                    refused: { Issue.record("a generation \($1) was refused over \($0)") },
                    verifier: verifier, launch: launch)
    }

    static func inTurn(batchSize: Int = QueueEngineLaunchFill.batchSize) -> QueueEngineLaunchSetup {
        var setup = QueueEngineLaunchSetup(reads: .inTurn)
        setup.batchSize = batchSize
        return setup
    }

    static func report(_ engine: CountsEngine) -> QueueEngineFillReport? {
        if case .done(let report) = engine.launch.fill { return report }
        return nil
    }

    static func fillEnded(_ engine: CountsEngine) -> Bool {
        switch engine.launch.fill {
        case .done, .failed: return true
        case .waiting, .filling: return false
        }
    }

    /// Runs the engine's turns until the fill ends, waiting between them for whatever the launch thread is
    /// reading, whose answer comes back as a turn.
    static func runUntilFilled(_ engine: CountsEngine, _ turns: EngineTurns) async {
        for _ in 0..<50 {
            turns.run()
            if fillEnded(engine) { return }
            await waitUntil("the launch's next step") { !turns.queued.isEmpty || fillEnded(engine) }
        }
    }
}

/// A read that fails the first `failures` times it is made, then reads for real.
final class FailingFirst<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Int
    private let real: @Sendable (ModelContainer) throws -> T

    init(_ failures: Int, real: @escaping @Sendable (ModelContainer) throws -> T) {
        left = failures
        self.real = real
    }

    var read: @Sendable (ModelContainer) throws -> T {
        { [self] container in
            let fail = lock.withLock { () -> Bool in
                defer { left -= 1 }
                return left > 0
            }
            if fail { throw CocoaError(.fileReadUnknown) }
            return try real(container)
        }
    }
}

/// An uptime that moves by `step` seconds every time it is read, so each batch measures exactly `step`.
final class SteppedUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var at: TimeInterval = 1_000
    let step: TimeInterval

    init(step: TimeInterval) {
        self.step = step
    }

    var read: @Sendable () -> TimeInterval {
        { [self] in
            lock.withLock {
                at += step
                return at
            }
        }
    }
}

// MARK: - The keyset

// D6 and 0b.3: the keyset predicate `naturalKey > cursor` compares the stored BYTES, so the sort feeding it must
// order the same way, or the fill skips rows and repeats others while every count looks plausible (the default
// `.localizedStandard` missed 60 rows and repeated 120 at 5,376).
@Suite("The launch fill's keyset agrees with the cursor's byte order (#4358)")
@MainActor
struct QueueEngineLaunchKeysetTests {

    static let keys = ["show-9", "show-10", "Show-2", "show-b", "show-B", "shöw-1", "show-é", "show-f", "show 3",
                       "show-a10", "show-a9"]

    static func byteOrder(_ keys: [String]) -> [String] {
        keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    }

    @Test func aBatchOfOneVisitsEveryKeyOnceInByteOrder() throws {
        // The positive control: on these keys the localized order really differs from the byte order, so a fill
        // sorted the localized way would be caught here rather than agree by accident (L159).
        #expect(Self.keys.sorted(using: String.StandardComparator.localizedStandard) != Self.byteOrder(Self.keys))
        let store = try EngineStore(shows: 0, inquiries: 0, smallRows: 0, seed: 401)
        for key in Self.keys { store.addShow().naturalKey = key }
        try store.context.save()
        let reader = ModelContext(store.container)
        var cursor: String?
        var visited: [String] = []
        for _ in 0...Self.keys.count + 1 {
            let batch = try reader.fetch(QueueEngineLaunchFill.batch(after: cursor, limit: 1))
            guard let row = batch.first else { break }
            visited.append(row.naturalKey)
            cursor = row.naturalKey
        }
        #expect(visited == Self.byteOrder(Self.keys))
    }
}

// MARK: - The first output

@Suite("The launch publishes nothing until its first read lands (#4358)")
@MainActor
final class QueueEngineLaunchFirstReadTests {

    // The read is held on the launch thread, so the engine is loading for as long as the test likes: a turn asked
    // for meanwhile (an edit, saved) derives nothing, because a pass now would publish an empty queue (D6). The
    // output that lands carries the save count and generation taken when the read STARTED (E2's contract), and the
    // edit made while it was held is taken in by the next turn under a newer generation.
    @Test func nothingIsPublishedBeforeTheReadLandsAndItsInputsAreFixedAtItsStart() async throws {
        let store = try EngineStore(shows: 7, seed: 402)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        let saves = StoreSaveCount()
        let held = HeldRead()
        defer { held.release() }
        var setup = QueueEngineLaunchSetup()
        setup.read = held.read
        let engine = LaunchRig.engine(store, turns, launch: setup, clock: clock, saves: saves)
        let before = saves.value(for: store.container)
        engine.start()
        #expect(engine.launch.firstPaint == .loading(since: clock.now, attempt: 1))
        await waitUntil("the launch read to reach the thread") { held.entered == 1 }
        try #require(try store.shows().first).fitReason = "edited while the launch read was held"
        try store.context.save()
        turns.run()
        #expect(engine.output == nil, "a turn published before the first read landed")
        #expect(engine.counters.passes == 0)
        held.release()
        await waitUntil("the first read to land") { engine.output != nil }
        let first = try #require(engine.output)
        #expect(first.reasons == [.first])
        #expect(first.value.shows == 7)
        #expect(first.saveCount == before, "the output claims a save count from after its read started")
        guard case .ready(_, attempts: 1) = engine.launch.firstPaint else {
            Issue.record("the launch is \(engine.launch.firstPaint), not ready on its first attempt")
            return
        }
        await LaunchRig.runUntilFilled(engine, turns)
        #expect(LaunchRig.report(engine) != nil, "the fill never finished: \(engine.launch.fill)")
        #expect(try engine.facts == store.freshFacts())
        #expect((engine.output?.generation ?? 0) >= first.generation)
    }

    @Test func aReadThatThrowsIsFailedWithNothingOnScreenAndRetryRecovers() throws {
        let store = try EngineStore(shows: 5, seed: 403)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        var setup = LaunchRig.inTurn()
        setup.read = FailingFirst(1, real: QueueEngineFreshRead.read).read
        let engine = LaunchRig.engine(store, turns, launch: setup, clock: clock)
        engine.start()
        turns.run()
        #expect(engine.launch.firstPaint == .failed(.readFailed, attempts: 1, at: clock.now))
        #expect(engine.output == nil, "a failed launch put something on screen")
        #expect(engine.launch.fill == .waiting)
        engine.retryLaunch()
        turns.run()
        #expect(engine.launch.firstPaint == .ready(at: clock.now, attempts: 2))
        #expect(engine.output?.value.shows == 5)
        #expect(LaunchRig.report(engine)?.shows == 5)
    }

    // D6: a short read is a failure, never a smaller queue.
    @Test func aShortReadIsAFailureNotAShorterQueue() throws {
        let store = try EngineStore(shows: 4, seed: 404)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        var setup = LaunchRig.inTurn()
        setup.read = VerifierReads.short
        let engine = LaunchRig.engine(store, turns, launch: setup, clock: clock)
        engine.start()
        turns.run()
        #expect(engine.launch.firstPaint == .failed(.shortRead, attempts: 1, at: clock.now))
        #expect(engine.output == nil)
    }

    // The launch thread's deadline runs on the injected clock, so the test passes it rather than waiting 30 s; and a
    // retry while the abandoned read still holds the thread is refused as wedged rather than queued behind it.
    @Test func aReadPastItsDeadlineIsTimedOutAndARetryBehindItIsWedged() async throws {
        let store = try EngineStore(shows: 3, seed: 405)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        let held = HeldRead()
        defer { held.release() }
        var setup = QueueEngineLaunchSetup()
        setup.read = held.read
        let engine = LaunchRig.engine(store, turns, launch: setup, clock: clock)
        engine.start()
        await waitUntil("the launch deadline to be armed") { clock.waiting == 1 && held.entered == 1 }
        clock.advance(by: QueueEngineLaunchFill.deadlineSeconds)
        await waitUntil("the launch to give up") {
            if case .failed = engine.launch.firstPaint { return true }
            return false
        }
        #expect(engine.launch.firstPaint == .failed(.timedOut, attempts: 1, at: clock.now))
        engine.retryLaunch()
        #expect(engine.launch.firstPaint == .loading(since: clock.now, attempt: 2))
        await waitUntil("the retry to be refused") {
            if case .failed = engine.launch.firstPaint { return true }
            return false
        }
        #expect(engine.launch.firstPaint == .failed(.wedged, attempts: 2, at: clock.now))
        #expect(engine.output == nil)
    }
}

// MARK: - The fill

@Suite("The launch fill arms every row in batches, one per turn, and finds what it skipped (#4358)")
@MainActor
final class QueueEngineLaunchFillTests {

    // One batch per main actor turn, never more (the main thread is held for one batch at a time), every show
    // and contact armed by the end: an unsaved edit on ANY row reaches the engine through its tracker alone.
    @Test func eachTurnTakesOneBatchAndEveryRowEndsArmed() throws {
        let store = try EngineStore(shows: 45, inquiries: 5, seed: 406)
        let turns = EngineTurns()
        let size = QueueEngineLaunchFill.batchSize
        let engine = LaunchRig.engine(store, turns, launch: LaunchRig.inTurn(), saveCenter: NotificationCenter())
        engine.start()
        #expect(turns.runOne(), "the first read was never asked for")
        #expect(engine.output?.value.shows == 45)
        var taken = 0
        var steps = 0
        while LaunchRig.report(engine) == nil, steps < 20, turns.runOne() {
            steps += 1
            let now = engine.fillReport.shows
            #expect(now - taken <= size, "one turn took \(now - taken) rows, more than one batch of \(size)")
            taken = now
        }
        let report = try #require(LaunchRig.report(engine), "the fill never finished: \(engine.launch.fill)")
        #expect(report.shows == 45)
        #expect(report.inquiries == 5)
        #expect(report.batches == 45 / size + 1, "the fill was not taken in batches of \(size)")
        #expect(report.batchSeconds.count == report.batches)
        #expect(report.shortfall == .measured(missing: 0, admitted: 0))
        // Armed: an unsaved edit on every show and every inquiry, with no save the engine can hear, reaches it.
        for show in try store.shows() { show.fitReason = "armed? \(show.naturalKey)" }
        for inquiry in try store.context.fetch(FetchDescriptor<Inquiry>()) { inquiry.eventName += " armed?" }
        turns.run()
        #expect(try engine.facts == FactStore.extractAll(from: store.context))
    }

    // D6's test: a show re-keyed below the cursor while the fill is under way, by a save the engine cannot hear, is
    // skipped by the keyset; the identifier read finds it, one fetch admits it, the shortfall is recorded, and the
    // output is a pass over facts equal to the store. Batch size 1 so the fill really takes many batches (L101).
    @Test func aRowReKeyedBelowTheCursorIsTheShortfallAndIsAdmitted() throws {
        let store = try EngineStore(shows: 6, seed: 407)
        let turns = EngineTurns()
        let engine = LaunchRig.engine(store, turns, launch: LaunchRig.inTurn(batchSize: 1), saveCenter: NotificationCenter())
        engine.start()
        turns.runOne()
        for _ in 0..<3 { turns.runOne() }
        #expect(engine.fillReport.batches == 3, "the fill did not take one row per turn")
        let moved = try #require(try store.shows().last)
        moved.naturalKey = "show-00001-moved"
        try store.context.save()
        turns.run()
        let report = try #require(LaunchRig.report(engine), "the fill never finished: \(engine.launch.fill)")
        #expect(report.batches > 2, "the multi-batch path was not taken")
        #expect(report.shows == 5, "the keyset reached the row it should have skipped")
        #expect(report.shortfall == .measured(missing: 1, admitted: 1))
        let fresh = try store.freshFacts()
        #expect(engine.facts == fresh)
        let output = try #require(engine.output)
        let oracle = EngineDerivations.counts().derive(QueueEnginePassInput(facts: fresh, viewInputs: engine.viewInputs,
                                                                             now: output.now))
        #expect(output.value == oracle)
        // Admitted means watched: an unsaved edit on it alone reaches the engine.
        moved.fitReason = "edited after its admission"
        turns.run()
        #expect(engine.facts.shows[moved.persistentModelID]?.fitReason == "edited after its admission")
    }

    // An identifier read that cannot be made measures nothing, so the shortfall is unmeasured, never "none" (L215).
    @Test func aShortfallCheckThatCannotReadIsUnmeasuredNeverNone() throws {
        let store = try EngineStore(shows: 3, seed: 408)
        let turns = EngineTurns()
        var setup = LaunchRig.inTurn()
        setup.identifiers = { _ in throw CocoaError(.fileReadUnknown) }
        let engine = LaunchRig.engine(store, turns, launch: setup)
        engine.start()
        turns.run()
        #expect(LaunchRig.report(engine)?.shortfall == .unmeasured(.readFailed))
    }

    // A batch that cannot be read stops the fill as failed with the output still on screen; a retry resumes from
    // where it stopped, so no row is taken twice and none is missed.
    @Test func aBatchThatCannotBeReadFailsTheFillAndRetryResumesIt() throws {
        let store = try EngineStore(shows: 5, seed: 409)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        var setup = LaunchRig.inTurn(batchSize: 2)
        let calls = Counter()
        setup.fetchBatch = { descriptor, context in
            calls.value += 1
            if calls.value == 2 { throw CocoaError(.fileReadUnknown) }
            return try context.fetch(descriptor)
        }
        let engine = LaunchRig.engine(store, turns, launch: setup, clock: clock)
        engine.start()
        turns.run()
        #expect(engine.launch.fill == .failed(.readFailed, attempts: 1, at: clock.now))
        #expect(engine.output?.value.shows == 5, "a failed fill took the queue off screen")
        engine.retryLaunch()
        turns.run()
        let report = try #require(LaunchRig.report(engine), "the retried fill never finished: \(engine.launch.fill)")
        #expect(report.shows == 5)
        #expect(report.shortfall == .measured(missing: 0, admitted: 0))
    }

    @MainActor final class Counter {
        var value = 0
    }

    // Each batch is timed on the engine's uptime against plan v7's 16 ms, and one over it is counted, not hidden.
    @Test func eachBatchIsMeasuredAgainstTheBudget() throws {
        for (step, over) in [(QueueEngineLaunchFill.batchBudgetSeconds * 1.1, true),
                             (QueueEngineLaunchFill.batchBudgetSeconds * 0.5, false)] {
            let store = try EngineStore(shows: 30, seed: 410)
            let turns = EngineTurns()
            var setup = LaunchRig.inTurn(batchSize: 10)
            setup.uptime = SteppedUptime(step: step).read
            let engine = LaunchRig.engine(store, turns, launch: setup)
            engine.start()
            turns.run()
            let report = try #require(LaunchRig.report(engine))
            #expect(report.batches == 4)
            #expect(report.batchesOverBudget == (over ? report.batches : 0), "at \(step) s a batch")
            #expect(abs(report.slowestBatch - step) < 1e-9)
        }
    }

    // D6: the first verification is forced when the fill ends, not left to three seconds of quiet.
    @Test func theFirstVerificationIsForcedWhenTheFillEnds() async throws {
        let store = try EngineStore(shows: 4, seed: 411)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        let engine = LaunchRig.engine(store, turns, launch: LaunchRig.inTurn(), clock: clock,
                                      verifier: QueueEngineVerifierSetup(triggers: .automatic))
        engine.start()
        turns.run()
        #expect(LaunchRig.report(engine) != nil)
        #expect(engine.verifierCounts.started == 1, "the fill ended and no verification was forced")
        await VerifierRig.finished(engine, beyond: 0, "the forced first verification")
        #expect(engine.verifierCounts.matches == 1)
        // It took the place of the first output's quiet timer: three quiet seconds later the same output is not
        // verified again. (The floor and the ten minute timer are what is left sleeping.)
        await waitUntil("the floor and the ten minute timer are sleeping") { clock.waiting == 2 }
        clock.advance(by: QueueEngineVerifier.quietSeconds)
        turns.run()
        #expect(engine.verifierCounts.started == 1, "the first output was verified a second time after quiet")
    }
}
