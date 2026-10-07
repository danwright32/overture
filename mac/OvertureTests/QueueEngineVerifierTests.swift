import Foundation
import SwiftData
import Testing

// #4358 (plan v7 D7 and decision 9, slice E2): the queue engine's verifier and recovery, one test that PRODUCES each
// outcome (L151): match, factMismatch, outputMismatch, superseded twice over (a read straddling saves, and a read
// at a save count no output describes), cancelled, unmeasured for each of its reasons (busy at the start, busy at
// the recovery, readFailed, shortRead, timedOut, wedged), healed, healDidNotConverge, a foreign save, and
// unverifiedTooLong; then the triggers (three seconds of quiet, twenty outputs), the durable record, the fault set's
// bounds, and the scan keeping the verifier off the cooperative pool. One file for the suites, on E1a's reasoning
// (every new file adds project file hunks to the review diff). The store, schedule, clock and counting derivation
// are `QueueEngineIntakeTests.swift`'s.
//
// Every "the store says" in here is a fresh read through a context of its own (L70), and every read the verifier is
// handed is either the real one or a named distortion of it, so each outcome is caused, never awaited (L159).

/// Reads a test hands the verifier in place of the real one.
enum VerifierReads {
    /// The real read with one show taken out of its facts and its count, so the store "says" that show is not there
    /// while the engine holds it: a fact mismatch with nothing actually wrong in the store.
    static func missing(_ id: PersistentIdentifier) -> @Sendable (ModelContainer) throws -> QueueEngineFreshRead {
        { container in
            let real = try QueueEngineFreshRead.read(container)
            var facts = real.facts
            facts.shows.removeValue(forKey: id)
            return QueueEngineFreshRead(facts: facts, counted: [.shows: facts.shows.count,
                                                                .inquiries: facts.inquiries.count])
        }
    }

    static let throwing: @Sendable (ModelContainer) throws -> QueueEngineFreshRead = { _ in
        throw CocoaError(.fileReadUnknown)
    }

    /// The real read, with a count saying one show more than the fetch returned.
    static let short: @Sendable (ModelContainer) throws -> QueueEngineFreshRead = { container in
        let real = try QueueEngineFreshRead.read(container)
        return QueueEngineFreshRead(facts: real.facts, counted: [.shows: real.facts.shows.count + 1,
                                                                 .inquiries: real.facts.inquiries.count])
    }

    /// The real read, but a save is counted DURING every one of them, so each straddles a save.
    static func straddling(_ saves: NotificationCenter) -> @Sendable (ModelContainer) throws -> QueueEngineFreshRead {
        { container in
            let context = ModelContext(container)
            saves.post(name: ModelContext.didSave, object: context)
            return try QueueEngineFreshRead.read(container)
        }
    }
}

/// A read that waits, on the verifier's thread, until the test lets it go.
final class HeldRead: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var entries = 0

    var entered: Int { lock.withLock { entries } }

    var read: @Sendable (ModelContainer) throws -> QueueEngineFreshRead {
        { [self] container in
            lock.withLock { entries += 1 }
            gate.wait()
            return try QueueEngineFreshRead.read(container)
        }
    }

    /// Lets every held read go. Called by every test that holds one, so no verifier thread outlives its test.
    func release(_ count: Int = 4) {
        for _ in 0..<count { gate.signal() }
    }
}

@MainActor
enum VerifierRig {
    /// `saveCenter` is where the engine hears saves: a private one is an engine that hears none.
    static func engine(_ store: EngineStore, _ turns: EngineTurns, clock: EngineTestClock = EngineTestClock(),
                       saves: StoreSaveCount = StoreSaveCount(), saveCenter: NotificationCenter = .default,
                       setup: QueueEngineVerifierSetup = QueueEngineVerifierSetup(triggers: .byHand),
                       derivation: QueueEngineDerivation<EngineDerivations.Counts> = EngineDerivations.counts())
        -> CountsEngine {
        let engine = QueueEngine(context: store.context, derivation: derivation, saves: saves, clock: clock.clock,
                                 events: QueueEngineSystemEvents(workspace: NotificationCenter(), system: NotificationCenter()),
                                 saveCenter: saveCenter, schedule: turns.schedule,
                                 refused: { Issue.record("a generation \($1) was refused over \($0)") }, verifier: setup)
        engine.start()
        turns.run()
        return engine
    }

    /// Waits for the verifier to reach any outcome beyond `before`.
    @discardableResult
    static func finished(_ engine: CountsEngine, beyond before: Int, _ what: String) async -> Bool {
        await waitUntil(what) { outcomes(engine) > before }
    }

    static func outcomes(_ engine: CountsEngine) -> Int {
        let c = engine.verifierCounts
        return c.matches + c.factMismatches + c.outputMismatches + c.superseded + c.cancelled
            + c.unmeasured.values.reduce(0, +)
    }
}

// MARK: - Each outcome

@Suite("The queue engine's verifier produces each of its outcomes (#4358)")
@MainActor
final class QueueEngineVerifierOutcomeTests {

    @Test func aCleanStoreMatches() async throws {
        let store = try EngineStore(shows: 6, seed: 51)
        let turns = EngineTurns()
        let engine = VerifierRig.engine(store, turns)
        engine.verifyNow()
        await VerifierRig.finished(engine, beyond: 0, "the verification of a clean store")
        #expect(engine.verifierCounts.matches == 1)
        #expect(engine.verifierCounts.lastMatchedAt != nil)
        #expect(engine.verifierFindings.isEmpty, "a clean store wrote \(engine.verifierFindings.map(\.kind))")
        #expect(engine.faults.isEmpty)
    }

    // The store "says" a held show is not there (the read is distorted, the store is not), so the verifier faults
    // it; recovery fetches the row, finds it in a throwaway context's read, and heals it in the next turn.
    @Test func aHeldRowTheReadDoesNotFindIsAFactMismatchThenHealed() async throws {
        let store = try EngineStore(shows: 4, seed: 52)
        let turns = EngineTurns()
        let id = try #require(try store.shows().first).persistentModelID
        let engine = VerifierRig.engine(store, turns,
                                        setup: QueueEngineVerifierSetup(triggers: .byHand, read: VerifierReads.missing(id)))
        engine.verifyNow()
        await VerifierRig.finished(engine, beyond: 0, "the verification that misses a show")
        guard case .some = engine.verifierFindings.first else {
            Issue.record("no finding at all, so the mismatch was not produced: \(engine.verifierCounts)")
            return
        }
        #expect(engine.verifierCounts.factMismatches == 1)
        #expect(engine.verifierFindings.first?.kind == CardDivergenceRecord.Kind.factMismatch)
        #expect(engine.verifierFindings.first?.fields == ["shows.heldNotStored"])
        #expect(engine.isFaulted(id), "the mismatched row was not faulted")
        let passes = engine.counters.passes
        #expect(turns.run() >= 1, "a fact mismatch asked for no recovery turn")
        #expect(!engine.isFaulted(id), "the row was not healed by the recovery turn")
        #expect(engine.verifierFindings.map(\.kind) == [.factMismatch, .healed])
        #expect(engine.verifierFindings.last?.fields == ["shows.heldNotStored"])
        #expect(engine.counters.passes == passes, "a heal that changed no fact derived a pass")
        #expect(try engine.facts == store.freshFacts())
    }

    // The facts agree and the output on screen is not the pass over them: an output published that the facts
    // do not give. The heal is a pass over the matching facts, with the `recovery` reason.
    @Test func anOutputTheFactsDoNotGiveIsAnOutputMismatchThenHealedByAPass() async throws {
        let store = try EngineStore(shows: 3, seed: 53)
        let turns = EngineTurns()
        let engine = VerifierRig.engine(store, turns)
        let current = try #require(engine.output)
        var wrong = current.value
        wrong.shows += 7
        engine.publish(QueueEngineOutput(value: wrong, saveCount: current.saveCount, generation: engine.mintGeneration(),
                                         now: current.now, reasons: [.first]))
        engine.verifyNow()
        await VerifierRig.finished(engine, beyond: 0, "the verification of a wrong output")
        #expect(engine.verifierCounts.outputMismatches == 1)
        #expect(engine.verifierFindings.map(\.kind) == [.outputMismatch])
        #expect(engine.verifierFindings.first?.fields == ["shows"])
        turns.run()
        #expect(engine.output?.reasons == [.recovery])
        #expect(engine.output?.value == current.value, "the healing pass did not put the right output back")
        #expect(engine.verifierFindings.map(\.kind) == [.outputMismatch, .healed])
        // And a second verification now matches.
        engine.verifyNow()
        await VerifierRig.finished(engine, beyond: 1, "the verification after the heal")
        #expect(engine.verifierCounts.matches == 1)
    }

    @Test func aReadStraddlingASaveEveryTimeIsSuperseded() async throws {
        let store = try EngineStore(shows: 2, seed: 54)
        let turns = EngineTurns()
        let center = NotificationCenter()
        let engine = VerifierRig.engine(store, turns, saves: StoreSaveCount(center: center),
                                        setup: QueueEngineVerifierSetup(triggers: .byHand,
                                                                        read: VerifierReads.straddling(center)))
        engine.verifyNow()
        await VerifierRig.finished(engine, beyond: 0, "the verification whose reads straddle saves")
        #expect(engine.verifierCounts.superseded == 1)
        #expect(engine.verifierFindings.isEmpty)
    }

    // A save the engine has not yet taken in: the read lands at a save count no output describes.
    @Test func aReadAtASaveCountNoOutputDescribesIsSuperseded() async throws {
        let store = try EngineStore(shows: 2, seed: 55)
        let turns = EngineTurns()
        let engine = VerifierRig.engine(store, turns)
        try #require(try store.shows().first).fitReason = "saved, turn not run"
        try store.context.save()
        engine.verifyNow()
        await VerifierRig.finished(engine, beyond: 0, "the verification ahead of the engine")
        #expect(engine.verifierCounts.superseded == 1)
        #expect(engine.verifierCounts.factMismatches == 0, "a save the engine had not taken in yet read as a mismatch")
    }

    // More outputs arrive while the read is held than the ring keeps, so the run is cancelled.
    @Test func moreOutputsThanTheRingHoldsCancelTheRun() async throws {
        let store = try EngineStore(shows: 2, seed: 56)
        let turns = EngineTurns()
        let held = HeldRead()
        defer { held.release() }
        let engine = VerifierRig.engine(store, turns, setup: QueueEngineVerifierSetup(triggers: .byHand, read: held.read))
        engine.verifyNow()
        await waitUntil("the verifier's read began") { held.entered == 1 }
        for stage in [StageFocus.scout, .reachedOut, .scout, .reachedOut, .scout] {
            engine.setViewInputs(QueueEngineViewInputs(focusedStage: stage))
            turns.run()
        }
        held.release()
        await VerifierRig.finished(engine, beyond: 0, "the cancelled verification")
        #expect(engine.verifierCounts.cancelled == 1, "\(engine.verifierCounts)")
    }

    // An unsaved edit on the main context: the held facts are not the saved store's, so nothing is compared.
    @Test func anUnsavedEditAtTheStartIsUnmeasuredBusy() async throws {
        let store = try EngineStore(shows: 2, seed: 57)
        let turns = EngineTurns()
        let engine = VerifierRig.engine(store, turns)
        try #require(try store.shows().first).fitReason = "unsaved"
        turns.run()
        engine.verifyNow()
        #expect(engine.verifierCounts.unmeasured[.busy] == 1)
        #expect(engine.verifierCounts.matches == 0 && engine.verifierFindings.isEmpty)
    }

    @Test func aReadThatThrowsIsUnmeasuredAndFaultsNothing() async throws {
        let store = try EngineStore(shows: 2, seed: 58)
        let turns = EngineTurns()
        let engine = VerifierRig.engine(store, turns,
                                        setup: QueueEngineVerifierSetup(triggers: .byHand, read: VerifierReads.throwing))
        engine.verifyNow()
        await VerifierRig.finished(engine, beyond: 0, "the verification whose read throws")
        #expect(engine.verifierCounts.unmeasured[.readFailed] == 1)
        #expect(engine.faults.isEmpty, "a failed read faulted a row (L215)")
    }

    @Test func aShortReadIsUnmeasuredAndFaultsNothing() async throws {
        let store = try EngineStore(shows: 2, seed: 59)
        let turns = EngineTurns()
        let engine = VerifierRig.engine(store, turns,
                                        setup: QueueEngineVerifierSetup(triggers: .byHand, read: VerifierReads.short))
        engine.verifyNow()
        await VerifierRig.finished(engine, beyond: 0, "the verification whose read comes back short")
        #expect(engine.verifierCounts.unmeasured[.shortRead] == 1)
        #expect(engine.faults.isEmpty, "a short read faulted a row (L211)")
    }

    // A read that never returns: the deadline gives up on it at thirty seconds on the engine's clock, and the
    // next verification is refused while it is still running, as the thread being wedged.
    @Test func aReadPastTheDeadlineTimesOutAndTheNextIsWedged() async throws {
        let store = try EngineStore(shows: 2, seed: 60)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        let held = HeldRead()
        defer { held.release() }
        let engine = VerifierRig.engine(store, turns, clock: clock,
                                        setup: QueueEngineVerifierSetup(triggers: .byHand, read: held.read))
        engine.verifyNow()
        await waitUntil("the verifier's read began") { held.entered == 1 }
        // The deadline's sleep and the clock's own floor are both sleeping before the clock moves.
        await waitUntil("the deadline is sleeping") { clock.waiting == 2 }
        clock.advance(by: 29)
        #expect(engine.verifierCounts.unmeasured[.timedOut] == nil, "the deadline ended before thirty seconds")
        clock.advance(by: 1)
        await VerifierRig.finished(engine, beyond: 0, "the deadline giving up on the read")
        #expect(engine.verifierCounts.unmeasured[.timedOut] == 1)
        engine.verifyNow()
        await VerifierRig.finished(engine, beyond: 1, "the refusal behind the wedged read")
        #expect(engine.verifierCounts.unmeasured[.wedged] == 1)
        #expect(engine.verifierFindings.map(\.kind) == [.verifierTimedOut, .verifierWedged])
        #expect(held.entered == 1, "a second read was started behind the one still running")
    }
}

// MARK: - Recovery

@Suite("The queue engine's recovery heals, waits for Dan's edits, and gives up within bounds (#4358)")
@MainActor
final class QueueEngineRecoveryTests {

    private func foreignSave(_ container: ModelContainer, _ id: PersistentIdentifier, _ value: String) async throws {
        let failure: String? = await phase0OnThread("engine-verifier-foreign") {
            let other = ModelContext(container)
            guard let row = other.model(for: id) as? Prospect else { return "the row was not found" }
            row.fitReason = value
            return Phase0.saveFailure(other)
        }
        try Phase0.requireSaved(failure, step: "the foreign save")
    }

    // Decision 9(a): an unsaved edit Dan made on the row is never thrown away. The row stays faulted and is
    // counted busy; once Dan's edit is saved, the next turn heals it (the foreign field is lost when main saves,
    // which #4106 probe 0b.4 measured and decision 9 accepts).
    @Test func aForeignSaveOnARowWithAnUnsavedEditWaitsAndKeepsTheEdit() async throws {
        let store = try EngineStore(shows: 3, seed: 61)
        let turns = EngineTurns()
        let engine = VerifierRig.engine(store, turns)
        let show = try #require(try store.shows().first)
        let id = show.persistentModelID
        show.groupName = "Dan's unsaved edit"
        turns.run()
        try await foreignSave(store.container, id, "written elsewhere")
        await waitUntil("the foreign save asked for a turn") { !turns.queued.isEmpty }
        turns.run()
        #expect(engine.isFaulted(id), "a row with an unsaved edit was not left faulted")
        #expect(engine.verifierCounts.unmeasured[.busy] ?? 0 >= 1)
        #expect(show.groupName == "Dan's unsaved edit", "recovery discarded Dan's unsaved edit")
        #expect(!engine.verifierFindings.contains { $0.kind == .healed })
        try store.context.save()
        turns.run()
        #expect(!engine.isFaulted(id), "the row was not healed once the edit was saved")
        #expect(engine.verifierFindings.map(\.kind) == [.foreignSave, .healed])
        #expect(try engine.facts == store.freshFacts())
    }

    /// An engine that hears no save (its save centre and its save counter are private ones), and a save through
    /// another context it therefore never learns of: the held row is stale and only the verifier can find it.
    private func unheardForeignSave(_ store: EngineStore, _ turns: EngineTurns, clock: EngineTestClock,
                                    refetch: @escaping QueueEngineRefetch,
                                    healCheck: @escaping @MainActor (Set<PersistentIdentifier>, ModelContainer) throws
                                        -> FactStore = QueueEngineRecovery.readAlone)
        async throws -> (CountsEngine, PersistentIdentifier) {
        var setup = QueueEngineVerifierSetup(triggers: .byHand, refetch: refetch)
        setup.healCheck = healCheck
        let engine = VerifierRig.engine(store, turns, clock: clock, saves: StoreSaveCount(center: NotificationCenter()),
                                        saveCenter: NotificationCenter(), setup: setup)
        let id = try #require(try store.shows().first).persistentModelID
        try await foreignSave(store.container, id, "written where nobody listened")
        turns.run()
        // The premise, measured rather than assumed (#4106 probe 2): the engine still holds the old value.
        #expect(engine.facts.shows[id]?.fitReason != "written where nobody listened",
                "the engine took in a save it was never told of, so this fixture produces no stale row")
        engine.verifyNow()
        await VerifierRig.finished(engine, beyond: 0, "the verification that finds the stale row")
        #expect(engine.verifierFindings.first?.kind == .factMismatch)
        #expect(engine.verifierFindings.first?.fields == ["shows.fitReason"])
        #expect(engine.isFaulted(id))
        return (engine, id)
    }

    // The realistic stale object: recovery's fetch brings it back, and the heal is recorded.
    @Test func aStaleRowTheVerifierFindsIsFetchedAgainAndHealed() async throws {
        let store = try EngineStore(shows: 3, seed: 64)
        let turns = EngineTurns()
        let (engine, id) = try await unheardForeignSave(store, turns, clock: EngineTestClock(),
                                                        refetch: QueueEngineRecovery.refetchByIdentifier)
        turns.run()
        #expect(!engine.isFaulted(id), "\(engine.verifierFindings.map(\.kind))")
        #expect(engine.verifierFindings.map(\.kind) == [.factMismatch, .healed])
        #expect(engine.facts.shows[id]?.fitReason == "written where nobody listened")
        #expect(try engine.facts == store.freshFacts())
    }

    // A main context forced never to converge (a refetch that fetches nothing): three failed attempts end the
    // round with `healDidNotConverge`, and nothing tries again inside the retry interval.
    @Test func aRowThatNeverConvergesGivesUpAfterThreeAttempts() async throws {
        let store = try EngineStore(shows: 3, seed: 62)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        let (engine, id) = try await unheardForeignSave(store, turns, clock: clock, refetch: { _, _, _, _ in true })
        for attempt in 1...3 {
            if attempt > 1 {
                await waitUntil("the next attempt's timer is sleeping") { clock.waiting >= 2 }
                clock.advance(by: QueueEngineFaults.attemptSpacingSeconds)
            }
            await waitUntil("attempt \(attempt) asked for a turn") { !turns.queued.isEmpty }
            turns.run()
        }
        #expect(engine.verifierFindings.map(\.kind) == [.factMismatch, .healDidNotConverge],
                "\(engine.verifierFindings.map(\.kind))")
        #expect(engine.verifierFindings.last?.fields == ["shows.fitReason"])
        #expect(engine.verifierCounts.healDidNotConverge == 1)
        #expect(engine.isFaulted(id), "a row that never converged left the fault set")
        let findings = engine.verifierFindings.count
        engine.sourceFired("gmailConnected")
        turns.run()
        #expect(engine.verifierFindings.count == findings, "a round that gave up was tried again at once")
    }

    // A heal check that cannot be read measured nothing about the row (L11): it is neither healed nor a failed
    // attempt, so three turns of it write no `healDidNotConverge`, and the row stays faulted.
    @Test func aHealCheckThatCannotBeReadIsNoAttempt() async throws {
        let store = try EngineStore(shows: 3, seed: 65)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        let (engine, id) = try await unheardForeignSave(store, turns, clock: clock,
                                                        refetch: QueueEngineRecovery.refetchByIdentifier,
                                                        healCheck: { _, _ in throw CocoaError(.fileReadUnknown) })
        let unread = engine.counters.unreadRows.times
        for attempt in 1...3 {
            if attempt > 1 {
                await waitUntil("the next try's timer is sleeping") { clock.waiting >= 2 }
                clock.advance(by: QueueEngineFaults.attemptSpacingSeconds)
            }
            await waitUntil("try \(attempt) asked for a turn") { !turns.queued.isEmpty }
            turns.run()
        }
        #expect(engine.counters.unreadRows.times == unread + 3, "the failed heal check reads were not counted")
        #expect(engine.verifierFindings.map(\.kind) == [.factMismatch], "\(engine.verifierFindings.map(\.kind))")
        #expect(engine.isFaulted(id) && engine.faults.entries[id]?.attempts == 0)
    }

    @Test func aForeignSaveIsRecordedByTableAndHealedInItsOwnTurn() async throws {
        let store = try EngineStore(shows: 3, seed: 63)
        let turns = EngineTurns()
        let engine = VerifierRig.engine(store, turns)
        let id = try #require(try store.shows().first).persistentModelID
        try await foreignSave(store.container, id, "written elsewhere")
        await waitUntil("the foreign save asked for a turn") { !turns.queued.isEmpty }
        turns.run()
        #expect(engine.verifierFindings.first?.kind == .foreignSave)
        #expect(engine.verifierFindings.first?.fields == ["shows"])
        #expect(engine.verifierFindings.map(\.kind) == [.foreignSave, .healed])
        #expect(engine.facts.shows[id]?.fitReason == "written elsewhere")
    }
}

// MARK: - Triggers, the record, and the bounds

@Suite("The queue engine's verifier triggers, record and bounds (#4358)")
@MainActor
final class QueueEngineVerifierTriggerTests {

    private let sandboxes = TemporarySandboxes()

    @Test func threeSecondsOfQuietStartAVerificationAndNotBefore() async throws {
        let store = try EngineStore(shows: 2, seed: 71)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        let engine = VerifierRig.engine(store, turns, clock: clock, setup: QueueEngineVerifierSetup())
        // The floor, the quiet timer and the ten minute timer.
        await waitUntil("the three timers are sleeping") { clock.waiting == 3 }
        clock.advance(by: 2.9)
        // The clock ends a due sleep inside `advance`, so a quiet timer that ended early is already gone from the
        // sleepers here, before its turn could run and start anything (seen to survive a check on `started` alone).
        #expect(clock.waiting == 3, "the quiet timer ended before three seconds")
        #expect(engine.verifierCounts.started == 0, "the verifier started before three seconds of quiet")
        clock.advance(by: 0.1)
        await VerifierRig.finished(engine, beyond: 0, "the verification after three quiet seconds")
        #expect(engine.verifierCounts.started == 1 && engine.verifierCounts.matches == 1)
    }

    @Test func twentyOutputsStartAVerificationWhateverTheQuiet() async throws {
        let store = try EngineStore(shows: 2, seed: 72)
        let turns = EngineTurns()
        let engine = VerifierRig.engine(store, turns, setup: QueueEngineVerifierSetup())
        for index in 1..<QueueEngineVerifier.forcedEveryGenerations {
            engine.setViewInputs(QueueEngineViewInputs(focusedStage: index.isMultiple(of: 2) ? .scout : .reachedOut))
            turns.run()
        }
        #expect(engine.verifierCounts.started == 1, "the twentieth output did not start a verification")
        await VerifierRig.finished(engine, beyond: 0, "the forced verification")
        #expect(engine.verifierCounts.matches == 1)
    }

    // Always superseded, so no comparison ever reaches a verdict: at ten minutes that is recorded.
    @Test func tenMinutesWithNoVerdictIsRecorded() async throws {
        let store = try EngineStore(shows: 2, seed: 73)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        let center = NotificationCenter()
        let engine = VerifierRig.engine(store, turns, clock: clock, saves: StoreSaveCount(center: center),
                                        setup: QueueEngineVerifierSetup(read: VerifierReads.straddling(center)))
        await waitUntil("the timers are sleeping") { clock.waiting == 3 }
        clock.advance(by: QueueEngineVerifier.unverifiedTooLongSeconds)
        await waitUntil("the ten minute record") { engine.verifierCounts.unverifiedTooLong == 1 }
        #expect(engine.verifierFindings.contains { $0.kind == .unverifiedTooLong })
        #expect(engine.verifierCounts.matches == 0)
    }

    // The durable half: a match counts toward the lifetime count beside the card check's stamp, and a mismatch
    // is a line in the divergence log naming fields and never the show (C7, L222).
    @Test func aMatchCountsForLifeAndAMismatchIsALineNamingNoShow() async throws {
        let store = try EngineStore(shows: 3, seed: 74)
        let turns = EngineTurns()
        let dir = try sandboxes.make(named: "engine-verifier-log")
        let log = QueueEngineVerifierLog(url: CardDivergenceLog.url(in: dir), defaults: ScratchDefaults.make("verifier"))
        let show = try #require(try store.shows().first)
        let engine = VerifierRig.engine(store, turns, setup: QueueEngineVerifierSetup(triggers: .byHand, log: log))
        engine.verifyNow()
        await VerifierRig.finished(engine, beyond: 0, "the matching verification")
        #expect(log.defaults.integer(forKey: CardDivergenceLog.verifierMatchCountKey) == 1)
        #expect(log.defaults.object(forKey: CardDivergenceLog.verifierLastMatchedKey) as? Date != nil)

        let mismatching = VerifierRig.engine(store, turns, setup: QueueEngineVerifierSetup(
            triggers: .byHand, read: VerifierReads.missing(show.persistentModelID), log: log))
        mismatching.verifyNow()
        await VerifierRig.finished(mismatching, beyond: 0, "the mismatching verification")
        let read = CardDivergenceLog.read(at: log.url)
        #expect(read.records.map(\.kind) == [.factMismatch])
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(!text.contains(show.naturalKey) && !text.contains(show.groupName), "the record names the show")
    }

    // A burst then quiet: the second foreign save inside ten minutes is held back by the cooldown, and once the
    // window ends the next turn writes its count rather than losing it (D8's drain, L710).
    @Test func aBurstsHeldCountIsWrittenOnceItsWindowEnds() async throws {
        let store = try EngineStore(shows: 3, seed: 78)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        let dir = try sandboxes.make(named: "engine-verifier-drain")
        let log = QueueEngineVerifierLog(url: CardDivergenceLog.url(in: dir), defaults: ScratchDefaults.make("drain"))
        let engine = VerifierRig.engine(store, turns, clock: clock,
                                        setup: QueueEngineVerifierSetup(triggers: .byHand, log: log))
        let ids = try store.shows().prefix(2).map(\.persistentModelID)
        let container = store.container
        for (index, id) in ids.enumerated() {
            let failure: String? = await phase0OnThread("engine-verifier-burst") {
                let other = ModelContext(container)
                guard let row = other.model(for: id) as? Prospect else { return "the row was not found" }
                row.fitReason = "burst \(index)"
                return Phase0.saveFailure(other)
            }
            try Phase0.requireSaved(failure, step: "a foreign save in the burst")
            await waitUntil("the foreign save asked for a turn") { !turns.queued.isEmpty }
            turns.run()
        }
        let foreign = { CardDivergenceLog.read(at: log.url).records.filter { $0.kind == .foreignSave } }
        #expect(foreign().map(\.suppressedRepeats) == [0], "the burst's second record was not held back")
        clock.advance(by: 600)
        engine.sourceFired("gmailConnected")
        turns.run()
        #expect(foreign().map(\.suppressedRepeats) == [0, 1], "the held count was not written once its window ended")
    }

    @Test func everyVerifierKindHasTheCooldown() {
        for kind in [CardDivergenceRecord.Kind.factMismatch, .outputMismatch, .foreignSave, .healed, .healDidNotConverge,
                     .unverifiedTooLong, .verifierTimedOut, .verifierWedged] {
            #expect(kind.cooldown == 600, "\(kind)")
        }
    }

    // The fault set's bounds, as values (D7: 3 attempts or 60 s per round, retry at five minutes or on a save that
    // touches the row, a per hour cap, stuck after an hour).
    @Test func theFaultSetsBoundsHold() throws {
        let store = try EngineStore(shows: 2, seed: 75)
        let id = try #require(try store.shows().first).persistentModelID
        let t0 = EngineStore.baseNow
        var faults = QueueEngineFaults()
        faults.admit([id: ["shows.fitReason"]], origin: .verifier, at: t0)
        #expect(faults.due(at: t0, touched: []) == [id])
        let first = faults.failed(id, at: t0)
        #expect(first == nil)
        let second = faults.failed(id, at: t0 + 20)
        #expect(second == nil)
        let third = faults.failed(id, at: t0 + 40)
        let gaveUp = try #require(third, "a third failure did not end the round")
        #expect(gaveUp.fields == ["shows.fitReason"])
        #expect(faults.due(at: t0 + 100, touched: []).isEmpty, "a round that gave up was due before its retry")
        #expect(faults.due(at: t0 + 100, touched: [id]) == [id], "a save touching the row did not make it due")
        #expect(faults.due(at: t0 + 340, touched: []) == [id], "five minutes did not make it due again")
        // A round also ends on time: one attempt, then one over sixty seconds later.
        var timed = QueueEngineFaults()
        timed.admit([id: []], origin: .foreignSave, at: t0)
        let early = timed.failed(id, at: t0)
        #expect(early == nil)
        let late = timed.failed(id, at: t0 + 61)
        #expect(late != nil, "a round past sixty seconds did not end")
        // The hour's cap: four rounds, then nothing until the first falls out of the hour.
        var capped = QueueEngineFaults()
        capped.admit([id: []], origin: .verifier, at: t0)
        var at = t0
        for _ in 0..<QueueEngineFaults.roundsPerHour {
            for _ in 0..<QueueEngineFaults.attemptsPerRound { _ = capped.failed(id, at: at) }
            at += QueueEngineFaults.retrySeconds
        }
        #expect(capped.due(at: at, touched: [id]).isEmpty, "a fifth round ran inside the hour")
        #expect(capped.summary(at: t0 + 3600) == QueueEngineFaults.Summary(count: 1, oldestSince: t0, stuck: 1))
        let healed = capped.healed(id)
        #expect(healed != nil && capped.isEmpty)
    }

    // A run that judged an output older than the one now on screen asks for another, so the newest output is not
    // left unverified until some later one arrives (L710); one that could not say asks too; one that judged the
    // output on screen, or measured nothing, does not.
    @Test func aVerdictOnAnOlderOutputAsksForAnother() {
        #expect(QueueEngineVerifier.needsAnother(after: .match(generation: 4), onScreen: 5))
        #expect(!QueueEngineVerifier.needsAnother(after: .match(generation: 5), onScreen: 5))
        #expect(QueueEngineVerifier.needsAnother(after: .outputMismatch(fields: ["shows"], generation: 3), onScreen: 5))
        #expect(QueueEngineVerifier.needsAnother(after: .factMismatch(rows: [:], generation: 2), onScreen: 5))
        #expect(QueueEngineVerifier.needsAnother(after: .superseded, onScreen: 5))
        #expect(QueueEngineVerifier.needsAnother(after: .cancelled, onScreen: 5))
        #expect(!QueueEngineVerifier.needsAnother(after: .unmeasured(.readFailed), onScreen: 5))
    }

    // The recovery timer's next wake comes from the fault set, so a row the hour's cap holds back still gets one,
    // at the moment the cap frees a round, rather than waiting for an unrelated turn (L51).
    @Test func theNextTryWakesWhenTheHoursCapFreesARound() throws {
        let store = try EngineStore(shows: 2, seed: 77)
        let id = try #require(try store.shows().first).persistentModelID
        let t0 = EngineStore.baseNow
        var faults = QueueEngineFaults()
        #expect(faults.nextTry(at: t0) == nil)
        faults.admit([id: []], origin: .verifier, at: t0)
        #expect(faults.nextTry(at: t0) == t0 + QueueEngineFaults.attemptSpacingSeconds, "an open round is not tried soon")
        var at = t0
        for round in 0..<QueueEngineFaults.roundsPerHour {
            for _ in 0..<QueueEngineFaults.attemptsPerRound { _ = faults.failed(id, at: at) }
            if round < QueueEngineFaults.roundsPerHour - 1 {
                #expect(faults.nextTry(at: at) == at + QueueEngineFaults.retrySeconds)
            }
            at += QueueEngineFaults.retrySeconds
        }
        let capped = at - QueueEngineFaults.retrySeconds
        #expect(faults.due(at: capped + QueueEngineFaults.retrySeconds, touched: [id]).isEmpty, "the cap did not hold")
        #expect(faults.nextTry(at: capped + QueueEngineFaults.retrySeconds) == t0 + 3600,
                "a capped row's next wake is not when the hour frees a round")
        #expect(faults.due(at: t0 + 3600, touched: []) == [id], "the row is not due when the cap frees a round")
    }

    // The field names a mismatch carries, read by Mirror over two real extractions.
    @Test func aMismatchNamesTheTableAndMember() throws {
        let store = try EngineStore(shows: 2, seed: 76)
        let before = try store.freshFacts()
        let show = try #require(try store.shows().first)
        show.fitReason += " revised"
        try store.context.save()
        let after = try store.freshFacts()
        #expect(before.mismatches(against: after) == [show.persistentModelID: ["shows.fitReason"]])
        #expect(before.mismatches(against: before).isEmpty)
    }

    // L241: the verifier never runs on the cooperative pool. Its work goes through `BlockingWorkThread`, and no
    // `Task.detached` or `async` function in its files constructs a context (plan v7 D7's source scan).
    @Test func theVerifierStaysOffTheCooperativePool() {
        for path in ["Overture/App/QueueEngine.swift", "Overture/Domain/QueueEngineVerifier.swift"] {
            let findings = Self.poolFindings(in: SourceGuardHelper.source(path))
            #expect(findings.isEmpty, "\(path): \(findings.joined(separator: "; "))")
        }
        let engine = SourceGuardHelper.source("Overture/App/QueueEngine.swift")
        #expect(engine.contains("let thread = verifierThread") && engine.contains("thread.run(deadlineSeconds:")
                    && engine.contains("BlockingWorkThread(name: \"queue-verifier\")"),
                "the verification no longer goes through the verifier's own thread")
        // The detector itself, on both shapes it must catch.
        #expect(!Self.poolFindings(in: "func f() {\n Task.detached { }\n}\n").isEmpty)
        #expect(!Self.poolFindings(in: "func g() async {\n let c = ModelContext(x)\n}\n").isEmpty)
        #expect(Self.poolFindings(in: "func h() {\n let c = ModelContext(x)\n}\n").isEmpty)
    }

    static func poolFindings(in source: String) -> [String] {
        let lines = SwiftSource.scannableLines(in: source, skipping: [])
        var findings: [String] = []
        var inAsync: (line: Int, depth: Int)?
        var depth = 0
        for (line, code) in lines {
            if code.contains("Task.detached") { findings.append("line \(line) starts a detached task") }
            if inAsync == nil, code.range(of: #"\bfunc\b[^{]*\basync\b"#, options: .regularExpression) != nil {
                inAsync = (line, depth)
            }
            if let open = inAsync, code.contains("ModelContext(") {
                findings.append("line \(line) builds a context inside the async function at line \(open.line)")
            }
            depth += code.filter { $0 == "{" }.count - code.filter { $0 == "}" }.count
            if let open = inAsync, depth <= open.depth, code.contains("}") { inAsync = nil }
        }
        return findings
    }
}
