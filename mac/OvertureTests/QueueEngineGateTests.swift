import Foundation
import SwiftData
import Testing

// #4358 (plan v2 Phase 4 steps 2 and 3): the generation gate, coalescing and generations.
//
// A pass derives only when something it reads moved, so the same view handed in a hundred times, a frame asking
// for cards the last pass already built, and a write that changed nothing are each no pass at all. Changes made
// in one main actor turn are one pass. And an output never replaces a newer one.
@Suite("The queue engine's generation gate and coalescing (#4358)")
@MainActor
final class QueueEngineGateTests {

    typealias Engine = QueueEngine<EngineDerivations.Counts>

    /// The refusals the engine reported, held by reference because the handler is a main actor closure.
    @MainActor final class Refusals {
        var list: [(Int, Int)] = []
    }

    private func started<Value>(_ store: EngineStore, _ derivation: QueueEngineDerivation<Value>,
                                _ turns: EngineTurns) -> QueueEngine<Value> {
        let engine = EngineHarness.engine(store, derivation, turns: turns)
        engine.start()
        turns.run()
        return engine
    }

    @Test func theFirstPassDerivesOnceWithNothingElseAsked() throws {
        let store = try EngineStore(shows: 3, seed: 31)
        let turns = EngineTurns()
        let engine = started(store, EngineDerivations.counts(), turns)
        #expect(engine.counters.passes == 1)
        #expect(engine.output?.reasons == [.first])
        #expect(engine.output?.value.shows == 3)
    }

    @Test func theSameViewHandedInAHundredTimesIsNoPass() throws {
        let store = try EngineStore(shows: 3, seed: 32)
        let turns = EngineTurns()
        let engine = started(store, EngineDerivations.counts(), turns)
        let view = QueueEngineViewInputs(focusedStage: .scout, focusedKeys: ["show-00001"])
        engine.setViewInputs(view)
        turns.run()
        let passes = engine.counters.passes
        for _ in 0..<100 { engine.setViewInputs(view) }
        #expect(turns.run() == 0, "handing in the same view asked for a pass")
        #expect(engine.counters.passes == passes)
        // The positive control: a different stage is a reason, so the gate can say yes.
        engine.setViewInputs(QueueEngineViewInputs(focusedStage: .reachedOut, focusedKeys: ["show-00001"]))
        turns.run()
        #expect(engine.counters.passes == passes + 1)
        #expect(engine.output?.reasons == [.viewInputs])
    }

    @Test func cardsTheLastPassBuiltAreNoReasonAndAnyOtherIs() throws {
        let store = try EngineStore(shows: 2, seed: 33)
        let turns = EngineTurns()
        let counts = EngineDerivations.counts()
        let derivation = QueueEngineDerivation(derive: counts.derive, differingFields: counts.differingFields,
                                               nextChange: counts.nextChange,
                                               builtCardKeys: { _ in ["show-00001", "show-00002"] })
        let engine = started(store, derivation, turns)
        let passes = engine.counters.passes
        engine.setViewInputs(QueueEngineViewInputs(requestedCardKeys: ["show-00001"]))
        #expect(turns.run() == 0, "a frame asking only for built cards asked for a pass")
        engine.setViewInputs(QueueEngineViewInputs(requestedCardKeys: ["show-00001", "show-00009"]))
        turns.run()
        #expect(engine.counters.passes == passes + 1)
    }

    // A whole night dismissed in one turn: forty trackers fire and one save names forty rows, and that is ONE
    // pass, which is the whole point of the flag.
    @Test func aNightDismissedInOneTurnIsOnePass() throws {
        let store = try EngineStore(shows: 60, seed: 34)
        let turns = EngineTurns()
        let engine = started(store, EngineDerivations.counts(), turns)
        let passes = engine.counters.passes
        for show in try store.shows().prefix(40) { show.status = .dismissed }
        try store.context.save()
        #expect(turns.queued.count == 1, "forty changes in one turn asked for \(turns.queued.count) passes")
        #expect(turns.run() == 1)
        #expect(engine.counters.passes == passes + 1)
        #expect(try engine.facts == store.freshFacts())
    }

    @Test func eachOutputCarriesTheSaveCountAndANewerGeneration() throws {
        let store = try EngineStore(shows: 3, seed: 35)
        let turns = EngineTurns()
        let saves = StoreSaveCount()
        let engine = EngineHarness.engine(store, EngineDerivations.counts(), turns: turns, saves: saves)
        engine.start()
        turns.run()
        let first = try #require(engine.output)
        try #require(try store.shows().first).fitReason = "moved"
        try store.context.save()
        turns.run()
        let second = try #require(engine.output)
        #expect(second.generation == first.generation + 1)
        #expect(second.saveCount == saves.value(for: store.container) && second.saveCount > first.saveCount)
    }

    @Test func anOutputNoNewerThanTheOneOnScreenIsRefused() throws {
        let store = try EngineStore(shows: 2, seed: 36)
        let turns = EngineTurns()
        let refusals = Refusals()
        let engine = EngineHarness.engine(store, EngineDerivations.counts(), turns: turns,
                                          refused: { refusals.list.append(($0, $1)) })
        engine.start()
        turns.run()
        let current = try #require(engine.output)
        engine.publish(QueueEngineOutput(value: EngineDerivations.Counts(), saveCount: 0,
                                         generation: current.generation, now: current.now, reasons: [.first]))
        #expect(refusals.list.count == 1 && refusals.list.first?.0 == current.generation
                && refusals.list.first?.1 == current.generation)
        #expect(engine.output?.value == current.value, "a refused output replaced the one on screen")
        // The positive control: a newer one is applied.
        engine.publish(QueueEngineOutput(value: EngineDerivations.Counts(), saveCount: 0,
                                         generation: current.generation + 1, now: current.now, reasons: [.first]))
        #expect(engine.output?.generation == current.generation + 1 && refusals.list.count == 1)
    }

    @Test func theVerdictRefusesEqualAndOlderAndAppliesNewer() {
        #expect(QueueEngineGenerations.verdict(published: nil, incoming: 1) == .apply)
        #expect(QueueEngineGenerations.verdict(published: 4, incoming: 5) == .apply)
        #expect(QueueEngineGenerations.verdict(published: 4, incoming: 4) == .refuse(published: 4, incoming: 4))
        #expect(QueueEngineGenerations.verdict(published: 4, incoming: 2) == .refuse(published: 4, incoming: 2))
    }

    @Test func aContextSourceFiringIsAPassAndChangesNoFact() throws {
        let store = try EngineStore(shows: 2, seed: 37)
        let turns = EngineTurns()
        let engine = started(store, EngineDerivations.counts(), turns)
        let facts = engine.facts
        engine.sourceFired("gmailConnected")
        turns.run()
        #expect(engine.output?.reasons == [.sourceFired])
        #expect(engine.facts == facts)
    }

    // The signals the engine starts are the app's own (`QueueContextSignals`), so a real flip of a real source
    // reaches the pass with no store save behind it.
    @Test func theContextSignalsTheEngineStartsReachThePass() async throws {
        let store = try EngineStore(shows: 2, seed: 38)
        let turns = EngineTurns()
        let engine = started(store, EngineDerivations.counts(), turns)
        let rig = QueueInputSourceTests.rig()
        rig.signals.values.forEach { $0.cancel() }
        engine.startSignals(QueueContextSignals.Sources(gmail: rig.gmail, roster: rig.roster, prep: rig.prep,
                                                        check: rig.check, reply: rig.reply, checkLookups: { nil },
                                                        sleep: { _ in await Task.yield() }))
        defer { engine.stopSignals() }
        rig.flips.connected = true
        rig.gmail.refresh()
        let asked = await waitUntil("the Gmail signal asked the engine for a pass") { !turns.queued.isEmpty }
        #expect(asked)
        turns.run()
        #expect(engine.output?.reasons == [.sourceFired])
    }
}
