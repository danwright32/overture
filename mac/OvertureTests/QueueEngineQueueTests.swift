import Foundation
import SwiftData
import Testing

// #4358 slice E4b: the queue engine's pieces, unwired. One file for every suite, on E1a's reasoning (each new file
// adds project file hunks to the review diff): the queue's derivation over facts and the inputs that arrive by a
// signal, the card check at publish and the verifier's comparison (iv), the engine as the show resolver with its
// fourth refusal and the launch fill's fallback, "Reload this show", the landing generation (#4369), and the launch
// notice's sentences. The store, schedule, clock and counting derivation are `QueueEngineIntakeTests.swift`'s.
//
// Every "the store says" in here is a fresh read through a context of its own (L70). Every name and address is
// invented (L155, L222), and every date is pinned (L130).

/// The queue engine, built as the suites here need it: the queue's own derivation by default, a schedule the test
/// runs, a clock it moves, and saves heard or, for a stale row only the verifier can find, not heard at all.
@MainActor
enum QueueEngineRig {
    typealias Engine = QueueEngine<QueueEnginePass>

    static func engine(_ store: EngineStore, _ turns: EngineTurns,
                       derivation: QueueEngineDerivation<QueueEnginePass> = QueueEngineQueue.derivation(freezeWatch: { nil }),
                       clock: EngineTestClock = EngineTestClock(), hearsSaves: Bool = true,
                       setup: QueueEngineVerifierSetup = QueueEngineVerifierSetup(triggers: .byHand),
                       launch: QueueEngineLaunchSetup = QueueEngineLaunchSetup(reads: .inTurn),
                       context: QueueEngineContextInputs = EngineHarness.noSignals,
                       landing: QueueEngineLandingSetup = QueueEngineLandingSetup()) -> Engine {
        QueueEngine(context: store.context, derivation: derivation,
                    saves: hearsSaves ? StoreSaveCount() : StoreSaveCount(center: NotificationCenter()),
                    clock: clock.clock,
                    events: QueueEngineSystemEvents(workspace: NotificationCenter(), system: NotificationCenter()),
                    saveCenter: hearsSaves ? .default : NotificationCenter(), schedule: turns.schedule,
                    refused: { Issue.record("a generation \($1) was refused over \($0)") }, verifier: setup,
                    launch: launch, contextInputs: { context }, landing: landing)
    }

    static func started(_ store: EngineStore, _ turns: EngineTurns, clock: EngineTestClock = EngineTestClock(),
                        hearsSaves: Bool = true,
                        setup: QueueEngineVerifierSetup = QueueEngineVerifierSetup(triggers: .byHand),
                        derivation: QueueEngineDerivation<QueueEnginePass> = QueueEngineQueue.derivation(freezeWatch: { nil }),
                        context: QueueEngineContextInputs = EngineHarness.noSignals) -> Engine {
        let engine = engine(store, turns, derivation: derivation, clock: clock, hearsSaves: hearsSaves, setup: setup,
                            context: context)
        engine.start()
        turns.run()
        return engine
    }

    /// A save through another context that the engine never hears (it is built with `hearsSaves: false`), so the row
    /// it holds goes stale and only the verifier can find it. Verified, so the row comes back FAULTED.
    static func faulted(_ store: EngineStore, _ turns: EngineTurns, setup: QueueEngineVerifierSetup)
        async throws -> (Engine, Prospect) {
        let engine = started(store, turns, hearsSaves: false, setup: setup)
        let show = try #require(try store.shows().first)
        let id = show.persistentModelID
        let container = store.container
        let failure: String? = await phase0OnThread("engine-queue-foreign") {
            let other = ModelContext(container)
            guard let row = other.model(for: id) as? Prospect else { return "the row was not found" }
            row.fitReason = "written where nobody listened"
            return Phase0.saveFailure(other)
        }
        try Phase0.requireSaved(failure, step: "the unheard save")
        engine.verifyNow()
        await waitUntil("the verification that finds the stale row") { engine.verifierCounts.factMismatches > 0 }
        #expect(engine.isFaulted(id), "the fixture produced no faulted row, so nothing below is about one")
        return (engine, show)
    }
}

// MARK: - The derivation

@Suite("The queue's derivation for the engine runs the queue's own pass over facts (#4358 E4b)")
@MainActor
final class QueueEngineQueueDerivationTests {

    // The pass the engine derives is the pass `make` derives over the same store's models, handed the same inputs:
    // every table the engine keeps reaches it, by value. The models' arm skips the in-pass card check as the
    // engine's does, which is the one input the two are meant to differ in.
    @Test func theEnginesPassEqualsThePassOverTheModelsOfTheSameStore() throws {
        let store = try EngineStore(shows: 30, inquiries: 4, smallRows: 4, seed: 4401)
        let fresh = try store.freshFacts()
        let shows = try store.shows()
        let keys = Set(shows.prefix(6).map(\.naturalKey))
        let view = QueueEngineViewInputs(focusedStage: nil, focusedKeys: nil, requestedCardKeys: keys)
        let context = QueueEngineContextInputs(clients: .none, gmailConnected: true, replyRunAlive: true)
        let input = QueueEnginePassInput(facts: fresh, viewInputs: view, now: EngineStore.baseNow, context: context)
        let engines = QueueEngineQueue.derive(input)
        let models = store.context
        var inputs = QueueRenderPass.Inputs(
            allProspects: QueueRenderPass.Corpus(shows),
            inquiries: try models.fetch(FetchDescriptor<Inquiry>()).sorted { $0.createdAt < $1.createdAt },
            orgAnswers: try models.fetch(FetchDescriptor<OrgReachabilityAnswer>()).sorted { $0.orgKey < $1.orgKey },
            sources: try models.fetch(FetchDescriptor<WatchedSource>()).sorted { $0.sourceId < $1.sourceId },
            refusals: ContactRefusal.ledger(from: try models.fetch(FetchDescriptor<RefusedContactAddress>())
                .sorted { $0.handleKey < $1.handleKey }),
            overrides: ProducerOverrides(promotedRows: try models.fetch(FetchDescriptor<PromotedProducer>()),
                                         demotedRows: try models.fetch(FetchDescriptor<DemotedHouse>())),
            context: StageContext(now: EngineStore.baseNow,
                                  geo: GeoRefusals(userExcludedTowns: Set(try models.fetch(FetchDescriptor<ExcludedTown>())
                                                       .map(\.town)),
                                                   allowedSeedTowns: Set(try models.fetch(FetchDescriptor<AllowedSeedTown>())
                                                       .map(\.town))),
                                  clients: .none))
        inputs.gmailConnected = true
        inputs.replyRunAlive = true
        inputs.requestedCardKeys = keys
        inputs.checksACardInThePass = false
        let overModels = QueueRenderPass.make(inputs)
        // The premise, measured: a store with every table populated, and cards built.
        #expect(fresh.refusedAddresses.count == 4 && fresh.excludedTowns.count == 4 && fresh.inquiries.count == 4)
        #expect(engines.builtCards.cards.count == keys.count, "the requested cards were not built")
        let differing = RenderDataComparison.differingFields(overModels, engines.data)
        #expect(differing.isEmpty, Comment(rawValue: "the engine's pass differs from the models' in: "
            + differing.joined(separator: ", ")))
        #expect(engines.data.gmailConnected, "a signal input did not reach the pass")
        #expect(Set(QueueEngineQueue.derivation(freezeWatch: { nil }).builtCardKeys(engines)) == keys)
    }

    // The derivation is deterministic over one input, so a rebuild on the verifier's thread can only differ from the
    // output on screen for a reason that is a fault.
    @Test func thePassIsTheSameEveryTimeAndOffTheMainActor() async throws {
        let store = try EngineStore(shows: 25, seed: 4402)
        let fresh = try store.freshFacts()
        let input = QueueEnginePassInput(facts: fresh, viewInputs: QueueEngineViewInputs(focusedStage: nil, focusedKeys: nil,
                                                                                         requestedCardKeys: ["show-00003"]),
                                         now: EngineStore.baseNow, context: EngineHarness.noSignals)
        let here = QueueEngineQueue.derive(input)
        let there = await Task.detached { QueueEngineQueue.derive(input) }.value
        #expect(QueueEngineQueue.differingFields(here, there).isEmpty)
        // And the comparison sees a difference when there is one (L159): another instant moves the pass.
        let later = QueueEngineQueue.derive(QueueEnginePassInput(facts: fresh, viewInputs: input.viewInputs,
                                                                 now: EngineStore.baseNow.addingTimeInterval(86_400 * 40),
                                                                 context: input.context))
        #expect(!QueueEngineQueue.differingFields(here, later).isEmpty)
    }

    // The next change is the earliest rule already in play: a reply draft awaited, which stalls after its timeout.
    // With the reply run alive the stall cannot come due, and the answer says so (the signal reaches the clock).
    @Test func theNextChangeIsTheAwaitedDraftsStallAndTheRunAliveSignalMovesIt() throws {
        let store = try EngineStore(shows: 4, seed: 4403)
        let show = try #require(try store.shows().first)
        let contact = try #require(show.recipients.first ?? {
            show.setRecipients([Recipient(id: "awaited@example.org", email: "awaited@example.org", provenance: .act)])
            return show.recipients.first
        }())
        contact.replyDraftRequestedAt = EngineStore.baseNow
        try store.context.save()
        let fresh = try store.freshFacts()
        let view = QueueEngineViewInputs(focusedStage: nil, focusedKeys: nil)
        let idle = QueueEngineQueue.derive(QueueEnginePassInput(facts: fresh, viewInputs: view, now: EngineStore.baseNow,
                                                               context: EngineHarness.noSignals))
        #expect(idle.nextChange == EngineStore.baseNow.addingTimeInterval(Recipient.replyDraftStallTimeout))
        let alive = QueueEngineQueue.derive(QueueEnginePassInput(
            facts: fresh, viewInputs: view, now: EngineStore.baseNow,
            context: QueueEngineContextInputs(clients: .none, replyRunAlive: true)))
        #expect(alive.nextChange != idle.nextChange, "the reply run's signal did not reach the next change")
    }

    // The engine with the queue's derivation, end to end: started, a change taken in, and the output on screen equal
    // to the pass over a fresh read.
    @Test func theEngineRunsTheQueuesPassAndItsOutputMatchesAFreshRead() async throws {
        let store = try EngineStore(shows: 20, seed: 4404)
        let turns = EngineTurns()
        let engine = QueueEngineRig.started(store, turns)
        let show = try #require(try store.shows().first)
        show.status = .dismissed
        try store.context.save()
        turns.run()
        let output = try #require(engine.output)
        let fresh = try store.freshFacts()
        let rebuilt = QueueEngineQueue.derive(QueueEnginePassInput(facts: fresh, viewInputs: engine.viewInputs,
                                                                   now: output.now, context: output.context))
        #expect(QueueEngineQueue.differingFields(output.value, rebuilt).isEmpty)
        #expect(!output.value.data.queueScope.contains { $0.showID == show.persistentModelID },
                "the dismissed show is still in the queue's scope")
        engine.verifyNow()
        await waitUntil("the verification") { engine.verifierCounts.matches + engine.verifierCounts.outputMismatches > 0 }
        #expect(engine.verifierCounts.matches == 1, "\(engine.verifierCounts)")
    }
}

// MARK: - The main actor pass

@Suite("The engine's own turns run the main actor pass, and the verifier's rebuild does not (#4358 E4b)")
@MainActor
final class QueueEngineMainActorPassTests {

    @MainActor
    final class Count {
        var passes = 0
    }

    // The queue's derivation counts and times every pass on the freeze watch through `onTheMainActor`. A turn that
    // ran `derive` instead would leave a freeze spanning it reporting zero passes; a verifier that ran the wrapper
    // would count a rebuild nobody waited for as a pass on the main thread.
    @Test func everyTurnsPassGoesThroughItAndNoVerificationDoes() async throws {
        let store = try EngineStore(shows: 6, seed: 4451)
        let turns = EngineTurns()
        let count = Count()
        var derivation = EngineDerivations.counts()
        let plain = derivation.derive
        derivation.onTheMainActor = { input in
            count.passes += 1
            return plain(input)
        }
        let engine = EngineHarness.engine(store, derivation, turns: turns)
        engine.start()
        turns.run()
        store.addShow(contacts: 1)
        try store.context.save()
        turns.run()
        #expect(engine.counters.passes == 2)
        #expect(count.passes == engine.counters.passes, "a turn's pass did not go through the main actor form")
        engine.verifyNow()
        await waitUntil("the verification") { engine.verifierCounts.matches > 0 }
        #expect(count.passes == engine.counters.passes, "the verifier's rebuild ran the main actor form")
    }
}

// MARK: - The signal inputs

@Suite("The engine's signal inputs are exactly the pass's signal inputs (#4358 E4b)")
struct QueueEngineContextInputsTests {

    // Derived from both sides (L96): every input `QueueInputSource` says arrives by a signal is a member of the value
    // the engine carries, and nothing else is.
    @Test func everySignalInputIsCarriedAndNothingElse() {
        let signals = Set(QueueInputSource.byInput.filter { $0.value == .signal }.keys
            .map { $0.hasPrefix("context.") ? String($0.dropFirst("context.".count)) : $0 })
        let members = Set(Mirror(reflecting: QueueEngineContextInputs(clients: .none)).children.compactMap(\.label))
        #expect(signals.count >= 8, "too few signal inputs were found to have checked anything")
        #expect(signals == members, Comment(rawValue: "signals " + signals.sorted().joined(separator: ", ")
            + " against members " + members.sorted().joined(separator: ", ")))
    }
}

// MARK: - The card checks

@Suite("The card check at publish and the verifier's comparison (iv) read the model, never the facts (#4358 E4b)")
@MainActor
final class QueueEngineCardCheckTests {

    /// The queue's derivation with one built card's calendar links rewritten, so the card the pass hands on disagrees
    /// with the same card built from the model: what a fact the intake missed looks like.
    static func tampering(_ key: String, checkAtPublish: Bool) -> QueueEngineDerivation<QueueEnginePass> {
        let real = QueueEngineQueue.derivation(freezeWatch: { nil })
        var derivation = QueueEngineDerivation<QueueEnginePass>(
            derive: { input in
                let pass = real.derive(input)
                var cards = pass.builtCards.cards
                cards[key]?.sourceCalendarURLs = ["https://tampered.example.org"]
                return QueueEnginePass(data: pass.data,
                                       builtCards: QueueModel.CardStore.Contents(
                                           cards: cards, shows: pass.builtCards.shows,
                                           contacts: pass.builtCards.contacts,
                                           requestedKeys: pass.builtCards.requestedKeys),
                                       nextChange: pass.nextChange, checkKey: key)
            },
            differingFields: real.differingFields, nextChange: real.nextChange, builtCardKeys: real.builtCardKeys)
        derivation.checkAtPublish = checkAtPublish ? real.checkAtPublish : nil
        derivation.compareCards = real.compareCards
        return derivation
    }

    @Test func aCardThatDisagreesWithItsModelIsRecordedAndTheFreshCardIsDrawn() throws {
        let store = try EngineStore(shows: 8, seed: 4411)
        let turns = EngineTurns()
        let show = try #require(try store.shows().first)
        let key = show.naturalKey
        let engine = QueueEngineRig.started(store, turns, derivation: Self.tampering(key, checkAtPublish: true))
        engine.setViewInputs(QueueEngineViewInputs(focusedStage: nil, focusedKeys: nil, requestedCardKeys: [key]))
        turns.run()
        let output = try #require(engine.output)
        #expect(engine.verifierCounts.cardDivergences >= 1)
        let finding = try #require(engine.verifierFindings.last { $0.kind == .cardDivergence })
        #expect(finding.fields == ["sourceCalendarURLs"])
        #expect(finding.cardsBuilt == 1)
        #expect(output.value.corrected[key]?.sourceCalendarURLs == [], "the fresh card was not the one drawn (C1)")
        let row = try #require(output.value.data.rows.first { $0.id == key })
        #expect(output.value.card(for: row).sourceCalendarURLs == [])
    }

    @Test func aCardThatAgreesIsNoFinding() throws {
        let store = try EngineStore(shows: 8, seed: 4412)
        let turns = EngineTurns()
        let key = try #require(try store.shows().first).naturalKey
        let engine = QueueEngineRig.started(store, turns)
        engine.setViewInputs(QueueEngineViewInputs(focusedStage: nil, focusedKeys: nil, requestedCardKeys: [key]))
        turns.run()
        #expect(engine.output?.value.checkKey == key, "no card was sampled, so agreement was not measured")
        #expect(engine.verifierCounts.cardDivergences == 0)
        #expect(engine.output?.value.corrected.isEmpty == true)
    }

    // Comparison (iv) through the verifier: the facts and the output agree (the derivation tampers the same way on
    // both sides), and the cards built from the saved shows do not.
    @Test func comparisonFourFindsACardTheModelsBuildDifferently() async throws {
        let store = try EngineStore(shows: 8, seed: 4413)
        let turns = EngineTurns()
        let key = try #require(try store.shows().first).naturalKey
        let engine = QueueEngineRig.started(store, turns, derivation: Self.tampering(key, checkAtPublish: false))
        engine.setViewInputs(QueueEngineViewInputs(focusedStage: nil, focusedKeys: nil, requestedCardKeys: [key]))
        turns.run()
        engine.verifyNow()
        await waitUntil("the verification") { engine.verifierCounts.cardMismatches + engine.verifierCounts.matches > 0 }
        #expect(engine.verifierCounts.cardMismatches == 1, "\(engine.verifierCounts)")
        #expect(engine.verifierFindings.last?.kind == .cardMismatch)
        #expect(engine.verifierFindings.last?.fields == ["sourceCalendarURLs"])
        #expect(engine.faults.isEmpty, "a card term disagreeing with itself faulted a row no refetch can heal")
    }

    @Test func comparisonFourAgreesOnAnUntamperedPass() async throws {
        let store = try EngineStore(shows: 8, seed: 4414)
        let turns = EngineTurns()
        let keys = Set(try store.shows().prefix(4).map(\.naturalKey))
        let engine = QueueEngineRig.started(store, turns)
        engine.setViewInputs(QueueEngineViewInputs(focusedStage: nil, focusedKeys: nil, requestedCardKeys: keys))
        turns.run()
        let pass = try #require(engine.output?.value)
        #expect(pass.builtCards.cards.count == 4, "no cards were built, so nothing was compared")
        #expect(try QueueEngineQueue.compareCards(pass, store.container).isEmpty)
        engine.verifyNow()
        await waitUntil("the verification") { engine.verifierCounts.cardMismatches + engine.verifierCounts.matches > 0 }
        #expect(engine.verifierCounts.matches == 1, "\(engine.verifierCounts)")
    }
}

// MARK: - The resolver

@Suite("The engine resolves a press by identity, refuses a faulted row, and falls back during the fill (#4358 E4b)")
@MainActor
final class QueueEngineResolverTests {

    @Test func aHeldShowResolvesAndADeletedOneIsGone() throws {
        let store = try EngineStore(shows: 6, seed: 4421)
        let turns = EngineTurns()
        let engine = QueueEngineRig.started(store, turns)
        let shows = try store.shows()
        let first = try #require(shows.first)
        #expect(ShowIdentity(first).resolve(in: engine).show === first)
        #expect(engine.identity(forKey: first.naturalKey)?.showID == first.persistentModelID)
        #expect(engine.everyShow.map(\.naturalKey) == shows.map(\.naturalKey), "every show, in key order")
        let identity = ShowIdentity(first)
        store.context.delete(first)
        try store.context.save()
        turns.run()
        guard case .refused(.gone) = identity.resolve(in: engine) else {
            Issue.record("a deleted show resolved to something")
            return
        }
    }

    @Test func aFaultedShowIsFoundAndRefusedAsOutOfStep() async throws {
        let store = try EngineStore(shows: 4, seed: 4422)
        let turns = EngineTurns()
        // A refetch that never converges, so the row stays faulted for the press.
        var setup = QueueEngineVerifierSetup(triggers: .byHand, refetch: { _, _, _, _ in true })
        setup.healCheck = { _, _ in FactStore() }
        let (engine, show) = try await QueueEngineRig.faulted(store, turns, setup: setup)
        guard case .refused(.outOfStep) = ShowIdentity(show).resolve(in: engine) else {
            Issue.record("a faulted show was not refused as out of step")
            return
        }
        // The same identity through rows a caller merely holds is found: only the engine knows a row is out of step.
        #expect(ShowIdentity(show).resolve(in: [show]).show === show)
    }

    // While the fill has not reached a show, a press on it still resolves, through the main context, and the show is
    // taken in by the next turn.
    @Test func aShowTheFillHasNotReachedResolvesThroughTheContextAndIsTakenIn() throws {
        let store = try EngineStore(shows: 6, seed: 4423)
        let turns = EngineTurns()
        var launch = QueueEngineLaunchSetup(reads: .inTurn)
        launch.batchSize = 2
        let engine = QueueEngineRig.engine(store, turns, launch: launch)
        engine.start()
        #expect(turns.runOne(), "the first read was not scheduled")
        #expect(engine.output != nil, "the first output was not published")
        let last = try #require(try store.shows().last)
        let reread = engine.counters.rowsReread
        #expect(ShowIdentity(last).resolve(in: engine).show === last, "an unreached show did not resolve")
        #expect(engine.identity(forKey: last.naturalKey)?.showID == last.persistentModelID)
        #expect(engine.everyShow.count == 6, "every show, read through the context while the fill runs")
        #expect(turns.runOne())
        #expect(engine.counters.rowsReread > reread, "the show a press found was not taken in by the next turn")
        turns.run()
        guard case .done = engine.launch.fill else {
            Issue.record("the fill did not finish: \(engine.launch.fill)")
            return
        }
    }
}

// MARK: - Reload this show

@Suite("Reload this show produces each of its outcomes (#4358 E4b)")
@MainActor
final class QueueEngineReloadTests {

    @Test func aStaleShowIsReloadedAndHealed() async throws {
        let store = try EngineStore(shows: 4, seed: 4431)
        let turns = EngineTurns()
        let (engine, show) = try await QueueEngineRig.faulted(store, turns,
                                                              setup: QueueEngineVerifierSetup(triggers: .byHand))
        let passes = engine.counters.passes
        #expect(engine.reload(ShowIdentity(show)) == .reloaded)
        #expect(!engine.isFaulted(show.persistentModelID))
        #expect(engine.facts.shows[show.persistentModelID]?.fitReason == "written where nobody listened")
        #expect(engine.verifierFindings.map(\.kind) == [.factMismatch, .healed])
        turns.run()
        #expect(engine.counters.passes == passes + 1, "the reloaded value was not published")
        #expect(try engine.facts == store.freshFacts())
    }

    @Test func aShowInStepHasNothingToReload() throws {
        let store = try EngineStore(shows: 3, seed: 4432)
        let turns = EngineTurns()
        let engine = QueueEngineRig.started(store, turns)
        #expect(engine.reload(ShowIdentity(try #require(try store.shows().first))) == .alreadyInStep)
    }

    @Test func anUnsavedEditIsNeverReloadedAway() async throws {
        let store = try EngineStore(shows: 4, seed: 4433)
        let turns = EngineTurns()
        let (engine, show) = try await QueueEngineRig.faulted(store, turns,
                                                              setup: QueueEngineVerifierSetup(triggers: .byHand))
        show.groupName = "Dan's unsaved edit"
        #expect(engine.reload(ShowIdentity(show)) == .unsavedEdit)
        #expect(show.groupName == "Dan's unsaved edit", "the reload discarded Dan's unsaved edit")
        #expect(engine.isFaulted(show.persistentModelID))
    }

    @Test func aRefetchThatDoesNotConvergeIsStillOutOfStep() async throws {
        let store = try EngineStore(shows: 4, seed: 4434)
        let turns = EngineTurns()
        let setup = QueueEngineVerifierSetup(triggers: .byHand, refetch: { _, _, _, _ in true })
        let (engine, show) = try await QueueEngineRig.faulted(store, turns, setup: setup)
        #expect(engine.reload(ShowIdentity(show)) == .stillOutOfStep)
        #expect(engine.isFaulted(show.persistentModelID))
    }

    @Test func aRefetchThatFindsNothingIsGone() async throws {
        let store = try EngineStore(shows: 4, seed: 4435)
        let turns = EngineTurns()
        let setup = QueueEngineVerifierSetup(triggers: .byHand, refetch: { _, _, _, _ in false })
        let (engine, show) = try await QueueEngineRig.faulted(store, turns, setup: setup)
        #expect(engine.reload(ShowIdentity(show)) == .gone)
        #expect(!engine.isFaulted(show.persistentModelID), "a row found gone is out of step with nothing")
        #expect(engine.facts.shows[show.persistentModelID] == nil)
    }

    @Test func aRefetchThatThrowsIsUnreadableAndNotGone() async throws {
        let store = try EngineStore(shows: 4, seed: 4436)
        let turns = EngineTurns()
        let setup = QueueEngineVerifierSetup(triggers: .byHand,
                                             refetch: { _, _, _, _ in throw CocoaError(.fileReadUnknown) })
        let (engine, show) = try await QueueEngineRig.faulted(store, turns, setup: setup)
        #expect(engine.reload(ShowIdentity(show)) == .unreadable)
        #expect(engine.isFaulted(show.persistentModelID))
        #expect(engine.facts.shows[show.persistentModelID] != nil, "a failed read was taken as a deletion (L215)")
    }

    @Test func everyOutcomeSaysItsOwnWholeSentenceNamingTheShow() {
        let sentences = QueueEngineReload.allCases.map { $0.sentence(org: "Lark & Finch Players") }
        #expect(Set(sentences).count == QueueEngineReload.allCases.count, "two outcomes share a sentence (L260)")
        for sentence in sentences {
            #expect(sentence.contains("Lark & Finch Players"), Comment(rawValue: sentence))
            #expect(sentence.range(of: "[\u{2014}\u{2013}]", options: .regularExpression) == nil, Comment(rawValue: sentence))
        }
    }

    // The resolver's fourth refusal names the button that unsticks the row, in both forms.
    @Test func theOutOfStepRefusalNamesTheReloadButton() {
        let refusal = ShowIdentity.Refusal.outOfStep
        for sentence in [refusal.sentence(org: "Lark & Finch Players"), refusal.sentence(org: nil),
                         refusal.undoSentence(org: "Lark & Finch Players")] {
            #expect(sentence.contains("Reload this show"), Comment(rawValue: sentence))
        }
    }
}

// MARK: - The landing generation (#4369)

@Suite("A landing holds the intake to batches and the queue to one publish, unless Dan acts (#4358 E4b, #4369)")
@MainActor
final class QueueEngineLandingTests {

    private func engine(_ store: EngineStore, _ turns: EngineTurns, batch: Int) -> CountsEngine {
        let engine = EngineHarness.engine(store, EngineDerivations.counts(), turns: turns,
                                          landing: QueueEngineLandingSetup(batchSize: batch))
        engine.start()
        turns.run()
        return engine
    }

    @Test func theBatchIsDecisionTensOneHundredAndFifty() {
        #expect(QueueEngineLandingSetup().batchSize == 150)
    }

    @Test func aLandingPublishesOnceWhenItClosesAndReadsInBatches() throws {
        let store = try EngineStore(shows: 4, seed: 4441)
        let turns = EngineTurns()
        let engine = engine(store, turns, batch: 2)
        let passes = engine.counters.passes
        let landing = engine.openLanding()
        for _ in 0..<5 { store.addShow(contacts: 1) }
        try store.context.save()
        turns.run()
        #expect(engine.counters.passes == passes, "the engine published while the landing was open")
        #expect(engine.counters.landingBatches >= 3, "five rows at two a batch took \(engine.counters.landingBatches)")
        #expect(engine.counters.heldTurns >= 1)
        #expect(try engine.facts == store.freshFacts(), "a carried row was never read")
        engine.closeLanding(landing)
        turns.run()
        #expect(engine.counters.passes == passes + 1, "the close did not publish exactly once")
        #expect(engine.output?.value.shows == 9)
        #expect(!engine.isHoldingForALanding)
    }

    // C4: Dan's change mid-landing publishes at once, with his row read first and whatever was taken in so far.
    @Test func danActingMidLandingPublishesHisChangeAtOnce() throws {
        let store = try EngineStore(shows: 4, seed: 4442)
        let turns = EngineTurns()
        let engine = engine(store, turns, batch: 2)
        let passes = engine.counters.passes
        let landing = engine.openLanding()
        for _ in 0..<6 { store.addShow(contacts: 0) }
        try store.context.save()
        #expect(turns.runOne(), "the landing's save asked for no turn")
        #expect(engine.counters.passes == passes)
        // Dan dismisses a show that was already held: noted, as the resolver notes what an action touches.
        let dans = try #require(try store.shows().first)
        dans.status = .dismissed
        engine.noteChanged(dans)
        #expect(turns.runOne())
        #expect(engine.counters.passes == passes + 1, "Dan's change waited for the landing")
        #expect(engine.facts.shows[dans.persistentModelID]?.statusRaw == ReviewStatus.dismissed.rawValue)
        #expect(engine.isHoldingForALanding, "rows were still carried, so the landing still holds")
        turns.run()
        #expect(engine.counters.passes == passes + 1, "the carry published before the landing closed")
        engine.closeLanding(landing)
        turns.run()
        #expect(engine.counters.passes == passes + 2)
        // Dan's change is his to save; once saved, the engine and the store agree.
        try store.context.save()
        turns.run()
        #expect(try engine.facts == store.freshFacts())
    }

    @Test func aLandingClosedTwiceOrByAnotherEngineClosesNothingElse() throws {
        let store = try EngineStore(shows: 3, seed: 4443)
        let turns = EngineTurns()
        let engine = engine(store, turns, batch: 2)
        let first = engine.openLanding()
        let second = engine.openLanding()
        engine.closeLanding(first)
        engine.closeLanding(first)
        #expect(engine.isHoldingForALanding, "closing one landing twice closed the other")
        engine.closeLanding(second)
        #expect(!engine.isHoldingForALanding)
    }

    @Test func aViewChangeMidLandingIsDanActing() throws {
        let store = try EngineStore(shows: 3, seed: 4444)
        let turns = EngineTurns()
        let engine = engine(store, turns, batch: 2)
        let passes = engine.counters.passes
        let landing = engine.openLanding()
        engine.setViewInputs(QueueEngineViewInputs(focusedStage: nil, focusedKeys: ["show-00001"]))
        turns.run()
        #expect(engine.counters.passes == passes + 1, "a view Dan asked for waited for the landing")
        engine.closeLanding(landing)
        turns.run()
        #expect(engine.counters.passes == passes + 1, "a landing that changed nothing published at its close")
    }
}

// MARK: - The launch notice's sentences

@Suite("The launch notice says the verifier's count, never zero as clean (#4358 E4b)")
struct QueueEngineNoticeCopyTests {

    static let eastern = TimeZone(identifier: "America/New_York")!
    static let at = Date(timeIntervalSince1970: 1_800_014_400)   // 2027-01-15 07:00 Eastern

    @Test func zeroMatchesIsNeverChecked() {
        let sentence = QueueEngineNoticeCopy.verifierSentence(matches: 0, lastMatchedAt: nil, timeZone: Self.eastern)
        #expect(sentence.contains("not yet checked"))
        #expect(!sentence.contains("matched"))
    }

    @Test func oneAndSeveralAreTheirOwnSentencesWithTheirDay() {
        let one = QueueEngineNoticeCopy.verifierSentence(matches: 1, lastMatchedAt: Self.at, timeZone: Self.eastern)
        let many = QueueEngineNoticeCopy.verifierSentence(matches: 12, lastMatchedAt: Self.at, timeZone: Self.eastern)
        #expect(one == "Overture checked your queue against your saved shows once, on January 15 at 7:00 AM, and "
                + "they matched.")
        #expect(many.contains("12 times") && many.contains("January 15 at 7:00 AM"))
        #expect(!one.contains("1 times"))
    }

    @Test func faultsAreSaidOnlyWhenThereAreAnyAndStuckOnesAskForTheButton() {
        #expect(QueueEngineNoticeCopy.faultSentence(.init(count: 0, oldestSince: nil, stuck: 0)) == nil)
        let fresh = QueueEngineNoticeCopy.faultSentence(.init(count: 1, oldestSince: Self.at, stuck: 0))
        let stuck = QueueEngineNoticeCopy.faultSentence(.init(count: 3, oldestSince: Self.at, stuck: 2))
        #expect(fresh?.contains("Reload this show") == false)
        #expect(stuck?.contains("Reload this show") == true && stuck?.contains("2 of them") == true)
        let sentences = [(1, 0), (1, 1), (3, 0), (3, 2)].compactMap {
            QueueEngineNoticeCopy.faultSentence(.init(count: $0.0, oldestSince: Self.at, stuck: $0.1))
        }
        #expect(Set(sentences).count == 4)
    }

    @Test func theLogLineCarriesEveryNetAndTheVerifiersState() {
        var counters = QueueEngineCounters()
        counters.fullReads = 2
        counters.foreignSaves.record(at: Self.at)
        let line = QueueEngineNoticeCopy.logLine(matches: 0, lastMatchedAt: nil,
                                                 faults: .init(count: 1, oldestSince: Self.at, stuck: 0),
                                                 counters: counters)
        for part in ["verifier matches 0", "last matched never", "faulted rows 1", "full reads 2", "foreign saves 1",
                     "unclassified saves 0", "merged inserts 0", "unread rows 0"] {
            #expect(line.contains(part), Comment(rawValue: "\(part) is missing from: \(line)"))
        }
    }
}
