import AppKit
import Foundation
import SwiftData
import Testing

// #4358 (slice E1b): when the queue engine derives, on what clock, and whether its facts survive every kind of
// change. One file for the three suites, on E1a's reasoning: every new file adds entries to the generated
// project file, and those count toward what the lessons review can read. The store, the schedule, the clock,
// the counting derivation and the identity walk are declared in `QueueEngineIntakeTests.swift`.

// MARK: - The generation gate and coalescing

// #4358 (plan v2 Phase 4 steps 2 and 3). A pass derives only when something it reads moved, so the same view
// handed in a hundred times, a frame asking for cards the last pass already built, and a write that changed
// nothing are each no pass at all. Changes made in one main actor turn are one pass (the night test is in the
// intake suite). And an output never replaces a newer one.
@Suite("The queue engine's generation gate and coalescing (#4358)")
@MainActor
final class QueueEngineGateTests {

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
        #expect(turns.run() == 0, "handing in the same view asked for a turn")
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
        let engine = started(store, EngineDerivations.counts(builtCardKeys: ["show-00001", "show-00002"]), turns)
        let passes = engine.counters.passes
        engine.setViewInputs(QueueEngineViewInputs(requestedCardKeys: ["show-00001"]))
        #expect(turns.run() == 0, "a frame asking only for built cards asked for a turn")
        engine.setViewInputs(QueueEngineViewInputs(requestedCardKeys: ["show-00001", "show-00009"]))
        turns.run()
        #expect(engine.counters.passes == passes + 1)
    }

    // A write that changed nothing is a turn (its tracker fired) and no pass: the equality gate feeds the
    // generation gate.
    @Test func anEqualValueWriteIsATurnAndNoPass() throws {
        let store = try EngineStore(shows: 4, seed: 30)
        let turns = EngineTurns()
        let engine = started(store, EngineDerivations.counts(), turns)
        let passes = engine.counters.passes
        let turnsBefore = engine.counters.turns
        for show in try store.shows() { show.groupName = show.groupName }
        try store.context.save()
        turns.run()
        #expect(engine.counters.turns > turnsBefore, "the write never reached the engine, so the gate was not asked")
        #expect(engine.counters.passes == passes, "a write that changed nothing derived a pass")
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
        let asked = await waitUntil("the Gmail signal asked the engine for a turn") { !turns.queued.isEmpty }
        #expect(asked)
        turns.run()
        #expect(engine.output?.reasons == [.sourceFired])
    }
}

// MARK: - The clock

// #4358 (plan v2 Phase 4 step 4, L51, L524). One deadline after each pass, at the earlier of the output's own
// next change and a 60 second floor, on a clock the test moves by hand; and a pass on wake, on a change to the
// system clock or time zone, and on a new calendar day, each heard on the centre it is really posted to. A
// floor-only pass that changes the output is recorded by the fields it changed, which is the floor's named cost
// (L93).
@Suite("The queue engine's clock (#4358)")
@MainActor
final class QueueEngineClockTests {

    @Test func theDeadlineIsTheEarlierOfTheNextChangeAndTheFloor() {
        let now = EngineStore.baseNow
        #expect(QueueEngineDeadline.next(now: now, termNextChange: nil)
                == QueueEngineDeadline(at: now.addingTimeInterval(60), kind: .floor))
        #expect(QueueEngineDeadline.next(now: now, termNextChange: now.addingTimeInterval(10))
                == QueueEngineDeadline(at: now.addingTimeInterval(10), kind: .term))
        #expect(QueueEngineDeadline.next(now: now, termNextChange: now.addingTimeInterval(600))
                == QueueEngineDeadline(at: now.addingTimeInterval(60), kind: .floor))
        // A rule already due is due now, never in the past.
        #expect(QueueEngineDeadline.next(now: now, termNextChange: now.addingTimeInterval(-5))
                == QueueEngineDeadline(at: now, kind: .term))
    }

    private struct Rig {
        let store: EngineStore
        let turns: EngineTurns
        let clock: EngineTestClock
        let events: QueueEngineSystemEvents
        let engine: CountsEngine
    }

    private func rig(_ derivation: QueueEngineDerivation<EngineDerivations.Counts> = EngineDerivations.counts(),
                     seed: UInt64) async throws -> Rig {
        let store = try EngineStore(shows: 2, seed: seed)
        let turns = EngineTurns()
        let clock = EngineTestClock()
        let events = QueueEngineSystemEvents(workspace: NotificationCenter(), system: NotificationCenter())
        let engine = EngineHarness.engine(store, derivation, turns: turns, clock: clock, events: events)
        engine.start()
        turns.run()
        await waitUntil("the deadline's timer is sleeping") { clock.waiting == 1 }
        return Rig(store: store, turns: turns, clock: clock, events: events, engine: engine)
    }

    @Test func theFloorForcesAPassAfterSixtySecondsAndNotBefore() async throws {
        let rig = try await rig(seed: 41)
        #expect(rig.engine.deadline?.kind == .floor)
        rig.clock.advance(by: 59)
        #expect(rig.clock.waiting == 1 && rig.turns.queued.isEmpty, "the floor fired before its minute was up")
        rig.clock.advance(by: 1)
        let asked = await waitUntil("the floor asked for a turn") { !rig.turns.queued.isEmpty }
        #expect(asked)
        rig.turns.run()
        #expect(rig.engine.output?.reasons == [.clockFloor])
        #expect(rig.engine.counters.passes == 2)
    }

    @Test func aRuleComingDueBeforeTheFloorForcesAPassAtItsInstant() async throws {
        let due = EngineStore.baseNow.addingTimeInterval(10)
        let rig = try await rig(EngineDerivations.counts(nextChange: due), seed: 42)
        #expect(rig.engine.deadline == QueueEngineDeadline(at: due, kind: .term))
        rig.clock.advance(by: 10)
        let asked = await waitUntil("the rule's deadline asked for a turn") { !rig.turns.queued.isEmpty }
        #expect(asked)
        rig.turns.run()
        #expect(rig.engine.output?.reasons == [.clockTerm])
    }

    // Each of the four, on the centre it is really posted to. Wake is posted ONLY to the workspace's centre, so
    // the same name posted to the default one is the silent no-op this must never be (`SleepObserver`).
    @Test(arguments: QueueEngineSystemEvents.events.map { $0.reason })
    func eachSystemEventForcesAPass(_ reason: QueueEnginePassReason) async throws {
        let rig = try await rig(seed: 43)
        let event = try #require(QueueEngineSystemEvents.events.first { $0.reason == reason })
        // Which centre each is really posted to is decided HERE, from AppKit's own rule, never read back from
        // the list under test, which would make a list that put wake on the wrong centre agree with itself
        // (L70).
        let postedToWorkspace = event.name == NSWorkspace.didWakeNotification
        let wrong = postedToWorkspace ? rig.events.system : rig.events.workspace
        wrong.post(name: event.name, object: nil)
        #expect(rig.turns.queued.isEmpty, "\(event.name.rawValue) was heard on a centre it is never posted to")
        (postedToWorkspace ? rig.events.workspace : rig.events.system).post(name: event.name, object: nil)
        #expect(rig.turns.queued.count == 1, "\(event.name.rawValue) asked for no turn")
        rig.turns.run()
        #expect(rig.engine.output?.reasons == [reason])
    }

    @Test func theFourEventsAreTheAppsOwn() {
        let names = Set(QueueEngineSystemEvents.events.map { $0.name })
        #expect(names == [NSWorkspace.didWakeNotification, .NSSystemClockDidChange, .NSSystemTimeZoneDidChange,
                          .NSCalendarDayChanged])
        #expect(QueueEngineSystemEvents.events.filter { $0.workspace }.map { $0.name } == [NSWorkspace.didWakeNotification])
    }

    // The floor's cost, named: a pass the floor alone forced that changed the output is recorded with the
    // fields it changed. A floor pass that changed nothing records nothing.
    @Test func aFloorPassThatChangesTheOutputIsRecordedByField() async throws {
        let rig = try await rig(EngineDerivations.counts(readsTheMinute: true), seed: 44)
        rig.clock.advance(by: 60)
        await waitUntil("the floor asked for a turn") { !rig.turns.queued.isEmpty }
        rig.turns.run()
        #expect(rig.engine.floorChanges.map(\.fields) == [["minute"]])
        #expect(rig.engine.floorChanges.first?.at == rig.clock.now)
    }

    @Test func aFloorPassThatChangesNothingRecordsNothing() async throws {
        let rig = try await rig(seed: 45)
        rig.clock.advance(by: 60)
        await waitUntil("the floor asked for a turn") { !rig.turns.queued.isEmpty }
        rig.turns.run()
        #expect(rig.engine.output?.reasons == [.clockFloor])
        #expect(rig.engine.floorChanges.isEmpty)
    }

    // A pass the floor shares with a real change is not the floor's doing, so it records nothing even when the
    // output moved.
    @Test func aFloorPassThatAlsoTookInAChangeIsNotTheFloorsCost() async throws {
        let rig = try await rig(EngineDerivations.counts(readsTheMinute: true), seed: 46)
        rig.clock.advance(by: 60)
        await waitUntil("the floor asked for a turn") { !rig.turns.queued.isEmpty }
        // A change lands in the same turn as the floor's pass, so that pass takes both in.
        rig.store.addShow()
        try rig.store.context.save()
        rig.turns.run()
        #expect(rig.engine.output?.reasons == [.clockFloor, .factsChanged])
        #expect(rig.engine.floorChanges.isEmpty)
    }
}

// MARK: - The change-kind matrix

// #4358 (plan v2 Phase 4 step 6, Dan's condition): the change-kind equality matrix.
//
// Every kind of change the intake handles, applied to 1, 60 and 300 rows in turn on one seeded store, and after
// each: the engine's facts equal a fresh extraction from a NEW context's fetch of the saved store, never the
// engine's own records (L70); and the passes it took are the ones the gate promises (one per turn that changed
// something, none for a write that changed nothing). The seed is printed with every line, so a failure
// reproduces.
//
// WHAT THIS CANNOT YET ASSERT, said every run rather than left out (L460). The plan's second half of the
// condition is that the engine's OUTPUT equals `QueueRenderPass.make` over the fresh facts at the same pinned
// `now`. That needs `make` over facts, which needs every term generic over the facts protocols and a RenderData
// holding no model (#4357), so the output arm prints UNMEASURED for every kind until the cutover (#4358, slice
// E4) hands the engine that derivation.
//
// ITS COST, because the main actor is one serial queue every `@MainActor` suite waits in (testing.md, "How much
// of the Swift suite runs on the main actor"). The draft of this matrix held it for 63.8 s per run (measured
// 2026-10-06, 20 kinds): about 1.4 s a kind building a 401 show store, and three fresh reads of about 0.35 s
// each. It cannot leave the main actor whole, because the engine and the main context it watches are main
// actor bound. So the fresh read, which needs neither, runs off it, and only the kinds that change stored
// shows get the 401 show store; the rest insert their own rows or touch other tables, and 40 shows serve them.
// The sizes stay 1, 60 and 300, which is the plan's condition.
//
// Three kinds are DECLARED here and run by the slice that builds what they exercise: the scout landing as a
// bulk kind (#4369), the reconcile tick, and a saved or unsaved change landing on a row the launch fill has
// not armed yet (D6). Declared rather than left out, so the slice that owns each finds it named.
enum EngineChangeKind: String, CaseIterable, Sendable {
    case dismiss
    case bulkReprep
    case scoutBlockInsert
    case mergeDeleteWithCascade
    case loneContactDelete
    case contactMove
    case naturalKeyReKey
    case upsertByNaturalKey
    case unsavedEditThenSave
    case unsavedInsertThenSave
    case insertThenDeleteBeforeSave
    case equalValueWrite
    case inquiryInsert
    case inquiryEdit
    case inquiryDelete
    case smallTableInsert
    case smallTableEdit
    case smallTableDelete
    case foreignSave
    case contextSourceFired
    case scoutLanding
    case reconcileTick
    case launchFillUnarmedRow

    /// The slice that runs a declared kind, or nil for one this matrix runs.
    var declaredFor: String? {
        switch self {
        case .scoutLanding: return "#4369, the scout landing as a declared bulk kind, run by the cutover (#4358 E4)"
        case .reconcileTick: return "the reconcile tick's writers, run by the cutover (#4358 E4)"
        case .launchFillUnarmedRow: return "a change on a row the launch fill has not armed, run by the launch slice (#4358 E3)"
        default: return nil
        }
    }

    /// Whether the kind changes shows already stored, so the store needs 300 of them to pick from. The others
    /// insert their own rows or touch other tables, and a store of forty shows serves them.
    var needsStoredShows: Bool {
        [.dismiss, .bulkReprep, .mergeDeleteWithCascade, .loneContactDelete, .contactMove, .naturalKeyReKey,
         .upsertByNaturalKey, .unsavedEditThenSave, .equalValueWrite, .foreignSave].contains(self)
    }
    var needsInquiries: Bool { [.inquiryInsert, .inquiryEdit, .inquiryDelete].contains(self) }
    var needsSmallTables: Bool { [.smallTableInsert, .smallTableEdit, .smallTableDelete].contains(self) }
}

@Suite("The queue engine's change-kind equality matrix at 1, 60 and 300 rows (#4358)")
@MainActor
final class QueueEngineChangeKindMatrixTests {

    static let sizes = [1, 60, 300]
    static let seed: UInt64 = 4358

    @Test func theMatrixNamesTheScoutLandingAsADeclaredBulkKind() {
        #expect(EngineChangeKind.scoutLanding.declaredFor?.contains("#4369") == true)
        #expect(EngineChangeKind.allCases.filter { $0.declaredFor == nil }.count >= 20)
    }

    @Test(arguments: EngineChangeKind.allCases)
    func afterEachKindTheFactsEqualAFreshRead(_ kind: EngineChangeKind) async throws {
        if let owner = kind.declaredFor {
            print("engine-matrix seed \(Self.seed) kind \(kind.rawValue): DECLARED, run by \(owner)")
            return
        }
        let total = Self.sizes.reduce(0, +)
        let clock = ContinuousClock()
        let built = clock.now
        let store = try EngineStore(shows: kind.needsStoredShows ? total + 40 : 40,
                                    inquiries: kind.needsInquiries ? total + 10 : 5,
                                    smallRows: kind.needsSmallTables ? total + 10 : 3, seed: Self.seed)
        // Every show carries a contact, so a contact kind at 300 has 300 to touch.
        for show in try store.shows() where show.recipients.isEmpty {
            show.setRecipients([Recipient(id: "\(show.naturalKey)-only@example.org",
                                          email: "\(show.naturalKey)-only@example.org", provenance: .act)])
        }
        try store.context.save()
        let turns = EngineTurns()
        let engine = EngineHarness.engine(store, EngineDerivations.counts(), turns: turns)
        engine.start()
        turns.run()
        let setUp = clock.now - built
        // Derived from the kind's POSITION, never its hash, which Swift seeds afresh in every process (L339).
        var rng = SeededGenerator(seed: Self.seed &+ UInt64(EngineChangeKind.allCases.firstIndex(of: kind) ?? 0))
        var touched: Set<PersistentIdentifier> = []
        for size in Self.sizes {
            let passes = engine.counters.passes
            let applying = clock.now
            let expectedPasses = try await apply(kind, rows: size, store: store, engine: engine, turns: turns,
                                                 touched: &touched, rng: &rng)
            let applied = clock.now - applying
            let reading = clock.now
            // Read OFF the main actor, through a context of its own: the same read as `freshFacts`, without
            // holding every other main actor suite behind it (see the cost note above the suite).
            let container = store.container
            let fresh = try await Task.detached { try FactStore.extractAll(from: ModelContext(container)) }.value
            let read = clock.now - reading
            let equal = engine.facts == fresh
            let took = engine.counters.passes - passes
            print("engine-matrix seed \(Self.seed) kind \(kind.rawValue) rows \(size): facts "
                  + (equal ? "equal a fresh read" : "DIFFER from a fresh read (\(Self.differing(engine.facts, fresh)))")
                  + ", passes \(took) (expected \(expectedPasses)); output arm UNMEASURED until make runs over facts"
                  + "; set up \(setUp), applied \(applied), fresh read \(read)")
            #expect(equal, "seed \(Self.seed) kind \(kind.rawValue) rows \(size): the facts differ from a fresh read")
            #expect(took == expectedPasses,
                    "seed \(Self.seed) kind \(kind.rawValue) rows \(size): \(took) passes, expected \(expectedPasses)")
            #expect(engine.facts.shows.keys.allSatisfy { $0.storeIdentifier != nil },
                    "a row is still held under a temporary identifier after its save")
        }
    }

    /// Which tables differ, by count only (L222).
    static func differing(_ a: FactStore, _ b: FactStore) -> String {
        let (changed, gone) = a.differences(to: b)
        return "\(changed) rows differ, \(gone.count) held and not in the read"
    }

    private func pick<T>(_ items: [T], _ count: Int, rng: inout SeededGenerator) -> [T] {
        Array(items.shuffled(using: &rng).prefix(count))
    }

    /// Applies `kind` to `rows` rows, runs the turns it causes, and returns how many passes the gate should
    /// have derived.
    private func apply(_ kind: EngineChangeKind, rows n: Int, store: EngineStore, engine: CountsEngine,
                       turns: EngineTurns, touched: inout Set<PersistentIdentifier>,
                       rng: inout SeededGenerator) async throws -> Int {
        let context = store.context
        func untouchedShows() throws -> [Prospect] {
            try store.shows().filter { !touched.contains($0.persistentModelID) }
        }
        func commit() throws {
            try context.save()
            turns.run()
        }
        switch kind {
        case .dismiss:
            for show in pick(try untouchedShows().filter { $0.status != .dismissed }, n, rng: &rng) {
                show.status = .dismissed
                touched.insert(show.persistentModelID)
            }
            try commit()
            return 1
        case .bulkReprep:
            for show in pick(try untouchedShows(), n, rng: &rng) {
                show.reprepContactsRequested.toggle()
                show.reprepDraftRequested = true
                touched.insert(show.persistentModelID)
            }
            try commit()
            return 1
        case .scoutBlockInsert:
            for _ in 0..<n { store.addShow(contacts: store.int(1...2)) }
            try commit()
            return 1
        case .mergeDeleteWithCascade:
            for show in pick(try untouchedShows(), n, rng: &rng) { context.delete(show) }
            try commit()
            return 1
        case .loneContactDelete:
            for show in pick(try untouchedShows().filter { !$0.recipients.isEmpty }, n, rng: &rng) {
                touched.insert(show.persistentModelID)
                if let contact = show.recipients.sorted(by: { $0.id < $1.id }).first { context.delete(contact) }
            }
            try commit()
            return 1
        case .contactMove:
            let all = try store.shows()
            for from in pick(try untouchedShows().filter { !$0.recipients.isEmpty }, n, rng: &rng) {
                touched.insert(from.persistentModelID)
                guard let moved = from.recipients.sorted(by: { $0.id < $1.id }).first,
                      let to = all.filter({ $0 !== from }).randomElement(using: &rng) else { continue }
                from.recipients.removeAll { $0 === moved }
                to.recipients.append(moved)
            }
            try commit()
            return 1
        case .naturalKeyReKey:
            let chosen = pick(try untouchedShows(), n, rng: &rng)
            engine.setViewInputs(QueueEngineViewInputs(focusedKeys: chosen.map(\.naturalKey)))
            turns.run()
            for show in chosen {
                show.naturalKey += "-rekeyed"
                touched.insert(show.persistentModelID)
            }
            try commit()
            // The expected keys are read from the shows themselves, never from the engine (L70).
            #expect(engine.viewInputs.focusedKeys == chosen.map(\.naturalKey),
                    "the focused leads were not renamed with the shows they name")
            // The new view above was one pass; the re-key is one more.
            return 2
        case .upsertByNaturalKey:
            for show in pick(try untouchedShows(), n, rng: &rng) {
                touched.insert(show.persistentModelID)
                let twin = Prospect(naturalKey: show.naturalKey, groupName: "Upserted \(n)", discipline: "music",
                                    venue: show.venue, performanceDate: show.performanceDate, sourceListingURL: nil,
                                    priorRelationship: "none", production: "presenter", profile: "strong",
                                    coverage: "likely_uncovered", fitScore: 9, tier: "mid", fitReason: "upserted",
                                    matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil,
                                    status: .drafted, ingestedAt: EngineStore.baseNow)
                context.insert(twin)
            }
            try commit()
            return 1
        case .unsavedEditThenSave:
            let chosen = pick(try untouchedShows(), n, rng: &rng)
            for show in chosen {
                show.fitReason = "unsaved \(n)"
                touched.insert(show.persistentModelID)
            }
            turns.run()
            #expect(chosen.allSatisfy { engine.facts.shows[$0.persistentModelID] == RowFacts.extract($0) },
                    "an unsaved edit was not taken in before its save")
            try commit()
            return 1
        case .unsavedInsertThenSave:
            let fresh = (0..<n).map { _ in store.addShow(contacts: 1) }
            for show in fresh { engine.noteChanged(show) }
            turns.run()
            try commit()
            // Taken in under temporary identifiers, then re-read under the permanent ones the save gave them.
            return 2
        case .insertThenDeleteBeforeSave:
            let fresh = (0..<n).map { _ in store.addShow(contacts: 1) }
            for show in fresh { engine.noteChanged(show) }
            turns.run()
            for show in fresh {
                context.delete(show)
                engine.noteChanged(show)
            }
            try commit()
            return 2
        case .equalValueWrite:
            for show in pick(try store.shows(), n, rng: &rng) { show.groupName = show.groupName }
            try commit()
            return 0
        case .inquiryInsert:
            for _ in 0..<n { store.addInquiry() }
            try commit()
            return 1
        case .inquiryEdit:
            let inquiries = try context.fetch(FetchDescriptor<Inquiry>()).sorted { $0.eventName < $1.eventName }
            for inquiry in pick(inquiries.filter { !touched.contains($0.persistentModelID) }, n, rng: &rng) {
                inquiry.notes = "edited \(n)"
                touched.insert(inquiry.persistentModelID)
            }
            try commit()
            return 1
        case .inquiryDelete:
            let inquiries = try context.fetch(FetchDescriptor<Inquiry>()).sorted { $0.eventName < $1.eventName }
            for inquiry in pick(inquiries, n, rng: &rng) { context.delete(inquiry) }
            try commit()
            return 1
        case .smallTableInsert:
            for _ in 0..<n { store.addSmallTableRows() }
            try commit()
            return 1
        case .smallTableEdit:
            for row in pick(try sorted(OrgReachabilityAnswer.self, \.orgKey, in: context), n, rng: &rng) {
                row.presenterName += " edited"
            }
            for row in pick(try sorted(WatchedSource.self, \.sourceId, in: context), n, rng: &rng) {
                row.orgName += " edited"
            }
            for row in pick(try sorted(RefusedContactAddress.self, \.id, in: context), n, rng: &rng) {
                row.handleKey += ".edited"
            }
            for row in pick(try sorted(PromotedProducer.self, \.orgKey, in: context), n, rng: &rng) {
                row.addedAt = row.addedAt.addingTimeInterval(1)
            }
            for row in pick(try sorted(DemotedHouse.self, \.orgKey, in: context), n, rng: &rng) {
                row.addedAt = row.addedAt.addingTimeInterval(1)
            }
            for row in pick(try sorted(ExcludedTown.self, \.town, in: context), n, rng: &rng) {
                row.addedAt = row.addedAt.addingTimeInterval(1)
            }
            for row in pick(try sorted(AllowedSeedTown.self, \.town, in: context), n, rng: &rng) {
                row.addedAt = row.addedAt.addingTimeInterval(1)
            }
            try commit()
            return 1
        case .smallTableDelete:
            for row in pick(try sorted(OrgReachabilityAnswer.self, \.orgKey, in: context), n, rng: &rng) { context.delete(row) }
            for row in pick(try sorted(WatchedSource.self, \.sourceId, in: context), n, rng: &rng) { context.delete(row) }
            for row in pick(try sorted(RefusedContactAddress.self, \.id, in: context), n, rng: &rng) { context.delete(row) }
            for row in pick(try sorted(PromotedProducer.self, \.orgKey, in: context), n, rng: &rng) { context.delete(row) }
            for row in pick(try sorted(DemotedHouse.self, \.orgKey, in: context), n, rng: &rng) { context.delete(row) }
            for row in pick(try sorted(ExcludedTown.self, \.town, in: context), n, rng: &rng) { context.delete(row) }
            for row in pick(try sorted(AllowedSeedTown.self, \.town, in: context), n, rng: &rng) { context.delete(row) }
            try commit()
            return 1
        case .foreignSave:
            let ids = pick(try untouchedShows(), n, rng: &rng).map(\.persistentModelID)
            touched.formUnion(ids)
            let container = store.container
            let failure: String? = await phase0OnThread("engine-matrix-foreign") {
                let other = ModelContext(container)
                for id in ids {
                    guard let row = other.model(for: id) as? Prospect else { return "a row was not found" }
                    row.fitReason = "written elsewhere"
                }
                return Phase0.saveFailure(other)
            }
            try Phase0.requireSaved(failure, step: "the matrix's foreign save")
            await waitUntil("the foreign save asked for a turn") { !turns.queued.isEmpty }
            turns.run()
            return 1
        case .contextSourceFired:
            let before = engine.facts
            engine.sourceFired("gmailConnected")
            turns.run()
            #expect(engine.facts == before, "a context source changed a stored fact")
            return 1
        case .scoutLanding, .reconcileTick, .launchFillUnarmedRow:
            return 0
        }
    }

    private func sorted<M: PersistentModel>(_ type: M.Type, _ key: KeyPath<M, String>,
                                            in context: ModelContext) throws -> [M] {
        try context.fetch(FetchDescriptor<M>()).sorted { $0[keyPath: key] < $1[keyPath: key] }
    }
}
