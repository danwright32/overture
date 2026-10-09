import Foundation
import SwiftData
import Testing

// #4361 (plan v7 Phase 4b(b)): T2 ContradictedCancellation and T3 feed breaks, patched inside the queue engine
// (`QueueEnginePatches` in Domain/FactStore.swift, the terms in Domain/CancellationPatches.swift), tested. One
// file for every suite, on E1a's reasoning (each new file adds project file hunks to the review diff).
//
// What each suite here holds, in the plan's words (discussion #4267, sections 4 and 7):
//   * the PER-TERM harness: seeded operation sequences over 0c.2's committed synthetic fixtures and op mix
//     (`Phase0cWorld`, 60 and 300 rows, invented containment-rich names), and after EVERY operation and every undo
//     the patched values equal the unpatched terms: T2 `contradictedKeys(among:)` and the row by row brute force
//     `liveTwin`, T3 `FeedBreakEvent.events` with `contradicted` nil, so it stays independent of T2;
//   * the WHOLE-PASS harness: the engine itself, with the queue's own derivation, taking the same operations in
//     through saves and turns, and after each one its published pass equals the pass over a fresh read with nothing
//     patched (the verifier's comparison (iii)), so a hand-off between the patches and the pass is seen (L220, L14);
//   * the per-term VERIFIER comparison: a patched value that disagrees with the unpatched term over a fresh read is
//     named in `QueueEnginePatches.mismatches(against:)`, which the verifier reports as `patchMismatch` (#4360's
//     verdict, record kind and heal, which every patched term shares);
//   * rows re-evaluated per change bounded by the ROOM, never the corpus (plan section 15).
// Each names the mutation that must turn it red (L1); the PR records each as seen.
//
// Failures print seed, step, operation and 8 hex digit hashes, never a title or a room (L222).

// MARK: - The per-term harness

@MainActor
enum PatchedCancellationsHarness {
    struct Outcome {
        var checks = 0
        var bruteChecks = 0
        var skipped = 0
        var accrualPasses = 0
        var applied: [Phase0cOp: Int] = [:]
        var failures: [String] = []
    }

    static func facts(_ rows: [Prospect]) -> [PersistentIdentifier: RowFacts] {
        Dictionary(rows.map { ($0.persistentModelID, RowFacts.extract($0)) }, uniquingKeysWith: { first, _ in first })
    }

    /// The rows as a store of facts with no small table, which is what a bring-up reads (#4362: T4 reads the overrides).
    static func store(_ rows: [Prospect]) -> FactStore {
        var store = FactStore()
        store.shows = facts(rows)
        return store
    }

    static func hash(_ keys: Set<String>) -> String { Phase0b.hash8(keys.sorted().joined(separator: ",")) }

    /// One seed: the patches built cold from the world's rows, then `steps` operations from T2's and T3's op mix, each
    /// checked after it and after its undo, and an accrual (up one, or down one where the row stays flagged) checked and
    /// undone after every operation, which is where 0c.2's bulk accrual miss lived.
    static func run(size: Int, seed: UInt64, steps: Int, outcome: inout Outcome) throws {
        let world = try Phase0cWorld(size: size, seed: seed)
        var rows = try world.rows()
        // The engine's own value and its own route: shows noted changed, then brought up to the facts at the day.
        var patches = QueueEnginePatches()
        patches.bringUp(to: store(rows), asOf: world.asOf)

        func feed(_ changed: Set<PersistentIdentifier>) {
            for id in changed.sorted() { patches.noteChanged(id) }
            patches.bringUp(to: store(rows), asOf: world.asOf)
        }

        let sampled = Set((0..<10).map { steps * $0 / 10 })
        func check(_ step: Int, _ op: String, brute: Bool) {
            outcome.checks += 1
            let place = "seed \(seed) size \(size) step \(step) op \(op)"
            let canonical = rows.sorted(by: CanonicalOracle.byNaturalKey)
            let oracle = ContradictedCancellation.contradictedKeys(among: canonical)
            let mine = patches.contradictions?.contradictedKeys ?? []
            let byRow = brute
                ? Set(rows.filter { ContradictedCancellation.liveTwin(of: $0, among: rows) != nil }.map(\.naturalKey))
                : oracle
            if brute { outcome.bruteChecks += 1 }
            if mine != oracle || mine != byRow {
                outcome.failures.append("\(place): T2 patched \(hash(mine)) (\(mine.count)) oracle \(hash(oracle)) "
                                        + "(\(oracle.count)) brute \(hash(byRow)) (\(byRow.count))")
            }
            let want = OracleRendering.feedBreaks(CanonicalOracle.feedBreakEvents(rows, asOf: world.asOf))
            let got = OracleRendering.feedBreaks(patches.feedBreaks?.output ?? [])
            if want != got {
                outcome.failures.append("\(place): T3 patched \(Phase0b.hash8(got)) oracle \(Phase0b.hash8(want))")
            }
        }

        check(-1, "cold build", brute: true)
        for step in 0..<steps {
            let brute = size <= 60 || sampled.contains(step)
            let op = Phase0cOp.t2t3[world.roll(Phase0cOp.t2t3.count)]
            guard let edit = world.perform(op, rows: rows, fronts: []) else {
                outcome.skipped += 1
                continue
            }
            outcome.applied[op, default: 0] += 1
            let changed = try world.commit(edit)
            rows = try world.rows()
            feed(changed)
            check(step, op.rawValue, brute: brute)
            if op.alwaysUndone || world.roll(2) == 0 {
                let undone = try world.undo(edit)
                rows = try world.rows()
                feed(undone)
                check(step, op.rawValue + " (undo)", brute: brute)
            }
            let accrual: Phase0cOp = world.roll(2) == 0 ? .accrualAll : .accrualDown
            if let pass = world.perform(accrual, rows: rows, fronts: []) {
                outcome.accrualPasses += 1
                let changed = try world.commit(pass)
                rows = try world.rows()
                feed(changed)
                check(step, op.rawValue + " then " + accrual.rawValue, brute: false)
                let undone = try world.undo(pass)
                rows = try world.rows()
                feed(undone)
                check(step, op.rawValue + " then " + accrual.rawValue + " (undo)", brute: false)
            }
        }
        check(steps, "end", brute: true)
        // The cold build is the patched type's own, and is compared against the oracle, never used as it (L70).
        var cold = QueueEnginePatches()
        cold.bringUp(to: store(rows), asOf: world.asOf)
        let canonical = rows.sorted(by: CanonicalOracle.byNaturalKey)
        if cold.contradictions?.contradictedKeys != ContradictedCancellation.contradictedKeys(among: canonical)
            || cold.feedBreaks?.output != FeedBreakEvent.events(among: canonical, asOf: world.asOf)
            || cold.contradictions?.contradictedKeys != patches.contradictions?.contradictedKeys
            || cold.feedBreaks?.output != patches.feedBreaks?.output {
            outcome.failures.append("seed \(seed) size \(size): the cold build, the patched values and the oracle disagree")
        }
    }

    /// CI settings by default (the 0c.2 harness's, which every mutation of its skip was caught at), deep ones opt in
    /// with `TEST_RUNNER_MEASURE_4106_PHASE0C_LINKS_DEEP=1`, the variable 0c.2 reads.
    static func runAll() throws -> (outcome: Outcome, settings: String) {
        let plan: [(size: Int, seeds: Int, steps: Int)] = Phase0cLinks.deep
            ? [(60, 20, 500), (300, 20, 500)] : [(60, 3, 20), (300, 1, 8)]
        var outcome = Outcome()
        for leg in plan {
            for s in 0..<leg.seeds {
                try run(size: leg.size, seed: 4361_0600 + UInt64(leg.size * 100 + s), steps: leg.steps,
                        outcome: &outcome)
            }
        }
        let settings = plan.map { "\($0.size) rows x \($0.seeds) seeds x \($0.steps) ops" }.joined(separator: ", ")
        return (outcome, (Phase0cLinks.deep ? "DEEP " : "CI ") + settings)
    }
}

@Suite("#4361 T2 and T3 patched equal their unpatched terms after every operation")
@MainActor
struct PatchedCancellationsHarnessTests {

    // Mutations that must turn this red (plan section 7): T2, skip the old room on a venue move
    // (`patch-t2-old-room`); T3, drop the covered-count update on a twin flip (`patch-t3-covered-flip`).
    @Test func thePatchesEqualTheirTermsAfterEveryOperationAndUndo() throws {
        let (outcome, settings) = try PatchedCancellationsHarness.runAll()
        let applied = outcome.applied.sorted { $0.key.rawValue < $1.key.rawValue }
            .map { "\($0.key.rawValue) \($0.value)" }.joined(separator: "; ")
        print("""
            patched-4361 per-term harness [\(settings)]: \(outcome.checks) comparisons (\(outcome.bruteChecks) also \
            against the brute force), \(outcome.accrualPasses) accrual passes, \(outcome.skipped) ops skipped, \
            mismatches \(outcome.failures.count)
              ops applied: \(applied)
            """)
        #expect(outcome.failures.isEmpty, Comment(rawValue: outcome.failures.prefix(10).joined(separator: "\n")))
        #expect(outcome.checks > 100, "the harness compared too little to mean anything")
        // Positive control (L159): the op mix reached the operations the named mutations live in.
        for op in [Phase0cOp.roomRespell, .flagAcross, .twinAppear, .deleteTwin, .rollover] {
            #expect((outcome.applied[op] ?? 0) > 0, "the harness never applied \(op.rawValue)")
        }
    }

    // Plan section 15: a change re-evaluates the rows of its own room, never the corpus. Counted at 60 and at 300 rows:
    // a live row's change tests at most the flagged rows of its rooms, and a flagged row's at most the live rows of its.
    @Test func aChangeTestsOnlyItsOwnRoomsRowsAtSixtyAndThreeHundred() throws {
        for size in [60, 300] {
            let world = try Phase0cWorld(size: size, seed: 4361_0700 + UInt64(size))
            let rows = try world.rows()
            var t2 = PatchableContradictions()
            t2.apply(PatchedCancellationsHarness.facts(rows).map { ($0.key, PatchableContradictions.Slice($0.value)) })
            let rooms = Dictionary(rows.map { ($0.persistentModelID, RowFacts.extract($0).foldedKeys.contradictionRoom) },
                                   uniquingKeysWith: { first, _ in first })
            func room(_ p: Prospect) -> String { rooms[p.persistentModelID] ?? "" }
            for row in rows where row.missedScoutCount == 0 || row.disappearedFromFeed {
                let mates = rows.filter { room($0) == room(row) && $0.persistentModelID != row.persistentModelID }
                let bound = row.missedScoutCount == 0
                    ? mates.filter(\.disappearedFromFeed).count : mates.filter { $0.missedScoutCount == 0 }.count
                let before = t2.tests
                let title = row.groupName
                row.groupName = title + " Encore Evening"
                t2.apply([(row.persistentModelID, PatchableContradictions.Slice(RowFacts.extract(row)))])
                row.groupName = title
                t2.apply([(row.persistentModelID, PatchableContradictions.Slice(RowFacts.extract(row)))])
                let spent = t2.tests - before
                #expect(spent <= 2 * bound, "size \(size): a change and its undo made \(spent) twin tests, room \(bound)")
            }
            // Positive control: the corpus is several rooms, so a room bound is smaller than the corpus.
            #expect(Set(rows.map(room)).count > 3, "size \(size): too few rooms for the bound to mean anything")
        }
    }
}

// MARK: - The whole-pass harness

/// A clock the harness SETS to the world's day, both ways, because a rollover's undo moves the day back. Its sleeps
/// never end on their own: no timer is wanted here, the harness forces every pass.
final class PatchedCancellationsDayClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date

    init(day: String) { instant = Self.noon(day) }

    func set(day: String) { lock.withLock { instant = Self.noon(day) } }

    var clock: QueueEngineClock {
        QueueEngineClock(now: { [self] in lock.withLock { instant } },
                         sleep: { _ in try await Task.sleep(for: .seconds(86_400 * 365)) })
    }

    /// Noon, Eastern, on `day`, so the Eastern day the pass judges at is `day` itself.
    static func noon(_ day: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: day + " 12:00") ?? Date(timeIntervalSince1970: 0)
    }
}

@MainActor
enum PatchedCancellationsEngineHarness {
    typealias Engine = QueueEngine<QueueEnginePass>

    struct Outcome {
        var checks = 0
        var applied = 0
        var failures: [String] = []
    }

    /// One seed through the engine: every operation and its undo saved, taken in by a turn, and checked.
    static func run(size: Int, seed: UInt64, steps: Int, outcome: inout Outcome) throws -> Engine {
        let world = try Phase0cWorld(size: size, seed: seed, models: AppSchema.models)
        let turns = EngineTurns()
        let day = PatchedCancellationsDayClock(day: world.asOf)
        let system = NotificationCenter()
        let engine = QueueEngine(context: world.context, derivation: QueueEngineQueue.derivation(freezeWatch: { nil }),
                                 saves: StoreSaveCount(), clock: day.clock,
                                 events: QueueEngineSystemEvents(workspace: NotificationCenter(), system: system),
                                 schedule: turns.schedule,
                                 refused: { Issue.record("a generation \($1) was refused over \($0)") },
                                 verifier: QueueEngineVerifierSetup(triggers: .byHand),
                                 launch: QueueEngineLaunchSetup(reads: .inTurn),
                                 contextInputs: { EngineHarness.noSignals })
        // Every card at 60 rows, so a contradicted row's card is compared too; none at 300, where the pass's own lists
        // and the patched values carry the comparison and a card per row would make the harness the suite's slowest.
        // Before the start, so the first pass is derived for the same view the comparison rebuilds at.
        if size <= 60 {
            engine.setViewInputs(QueueEngineViewInputs(focusedStage: nil, focusedKeys: nil,
                                                       requestedCardKeys: Set(try world.rows().map(\.naturalKey))))
        }
        engine.start()
        turns.run()
        var shownDay = world.asOf

        func settle() {
            turns.run()
            // The day the world judges at, reached the way the app reaches it: the calendar day turning.
            if world.asOf != shownDay {
                shownDay = world.asOf
                day.set(day: world.asOf)
                system.post(name: .NSCalendarDayChanged, object: nil)
                turns.run()
            }
        }

        func check(_ step: Int, _ op: String) {
            outcome.checks += 1
            let place = "seed \(seed) size \(size) step \(step) op \(op)"
            guard let output = engine.output else {
                outcome.failures.append("\(place): nothing published")
                return
            }
            let fresh: FactStore
            do {
                fresh = try FactStore.extractAll(from: ModelContext(world.container))
            } catch {
                outcome.failures.append("\(place): the fresh read threw")
                return
            }
            let rebuilt = QueueEngineQueue.derive(QueueEnginePassInput(facts: fresh, viewInputs: engine.viewInputs,
                                                                       now: output.now, context: output.context))
            let fields = QueueEngineQueue.differingFields(output.value, rebuilt)
            if !fields.isEmpty {
                outcome.failures.append("\(place): the published pass differs from the unpatched one in "
                                        + fields.joined(separator: ", "))
            }
            let terms = engine.patches.mismatches(against: fresh)
            if !terms.isEmpty {
                outcome.failures.append("\(place): patched \(terms.joined(separator: ", ")) differ")
            }
            // Positive control: the pass was handed T2 and T3 at its own day, so the comparisons above are about them.
            if engine.patches.feedBreaks?.asOf != EasternDate.today(output.now) || engine.patches.contradictions == nil {
                outcome.failures.append("\(place): the pass was handed nothing patched for its day")
            }
        }

        check(-1, "start")
        for step in 0..<steps {
            let op = Phase0cOp.t2t3[world.roll(Phase0cOp.t2t3.count)]
            guard let edit = world.perform(op, rows: try world.rows(), fronts: []) else { continue }
            outcome.applied += 1
            _ = try world.commit(edit)
            settle()
            check(step, op.rawValue)
            if op.alwaysUndone || world.roll(2) == 0 {
                _ = try world.undo(edit)
                settle()
                check(step, op.rawValue + " (undo)")
            }
        }
        return engine
    }
}

@Suite("#4361 the engine's published pass, patched, equals the unpatched pass after every operation")
@MainActor
final class PatchedCancellationsEngineHarnessTests {

    // Mutation that must turn this red while the per-term harness stays green: leave T2 and T3 out of the resolve step
    // (`patch-resolve-cancellations`), so a deleted or re-keyed row stays in them.
    @Test func thePublishedPassEqualsTheUnpatchedPassAfterEveryOperationAndTheVerifierMatches() async throws {
        var outcome = PatchedCancellationsEngineHarness.Outcome()
        var last: PatchedCancellationsEngineHarness.Engine?
        let plan: [(size: Int, seeds: Int, steps: Int)] = Phase0cLinks.deep
            ? [(60, 10, 200), (300, 5, 100)] : [(60, 2, 16), (300, 1, 6)]
        for leg in plan {
            for s in 0..<leg.seeds {
                last = try PatchedCancellationsEngineHarness.run(size: leg.size, seed: 4361_0800 + UInt64(leg.size + s),
                                                                 steps: leg.steps, outcome: &outcome)
            }
        }
        print("patched-4361 whole-pass harness: \(outcome.checks) comparisons over \(outcome.applied) operations, "
              + "mismatches \(outcome.failures.count)")
        #expect(outcome.failures.isEmpty, Comment(rawValue: outcome.failures.prefix(10).joined(separator: "\n")))
        #expect(outcome.checks > 20, "the harness compared too little to mean anything")
        // And the engine's own verifier, over the last world as it stands: the per-term kind and comparison (iii).
        let engine = try #require(last)
        engine.verifyNow()
        await waitUntil("the verification of the last world") { engine.verifierCounts.ended > 0 }
        #expect(engine.verifierCounts.matches == 1, "\(engine.verifierCounts)")
    }
}

// MARK: - The verifier's per-term kind

@Suite("#4361 a patched T2 or T3 the unpatched term disagrees with is named, and the verifier reports it")
@MainActor
final class PatchedCancellationsVerifierTests {

    /// A store with a contradicted row and a three member feed break, so both patched values hold something, and the
    /// live twin that makes the contradiction, which the tests delete behind the patches' back.
    private func store() throws -> (EngineStore, Prospect) {
        let store = try EngineStore(shows: 4, inquiries: 0, smallRows: 0, seed: 4361)
        for (i, title) in ["Lantern Hour", "Glass Lantern", "Harbor Lights"].enumerated() {
            let gone = store.addShow(contacts: 0)
            gone.groupName = title
            gone.venue = "Willow Barn"
            gone.performanceDate = store.day(20 + i)
            gone.missedScoutCount = 4
        }
        let twin = store.addShow(contacts: 0)
        twin.groupName = "Lantern Hour"
        twin.venue = "Willow Barn"
        twin.performanceDate = store.day(20)
        twin.missedScoutCount = 0
        try store.context.save()
        return (store, twin)
    }

    private var asOf: String { EasternDate.today(EngineStore.baseNow) }

    // Mutation that must turn this red: drop T2's comparison from `mismatches(against:)` (`patch-verifier-t2`).
    @Test func aChangeThePatchesNeverHeardOfIsNamedByTermAndAgreementIsNot() throws {
        let (store, twin) = try store()
        let before = try store.freshFacts()
        var patches = QueueEnginePatches()
        patches.bringUp(to: before, asOf: asOf)
        // The premise: the fixture holds a contradiction and a break covering it, so losing the twin moves both.
        #expect(patches.contradictions?.contradictedKeys.isEmpty == false, "the fixture contradicts nothing")
        #expect(patches.feedBreaks?.output.first?.coveredByAnotherCard == 1, "the fixture's break covers nothing")
        #expect(patches.mismatches(against: before).isEmpty, "the patches disagree with the facts they were built from")
        store.context.delete(twin)
        try store.context.save()
        let after = try store.freshFacts()
        let named = patches.mismatches(against: after)
        #expect(named.contains("contradictions.contradicted"), "\(named)")
        #expect(named.contains("feedBreaks.events"), "\(named)")
        // Once told, the patches agree again.
        patches.noteChanged(twin.persistentModelID)
        patches.bringUp(to: after, asOf: asOf)
        #expect(patches.mismatches(against: after).isEmpty, "\(patches.mismatches(against: after))")
    }

    // The resolve step, through the engine itself: a show inserted and taken in under its TEMPORARY identifier, then
    // saved (a re-key), then deleted (a removal). Neither is a stored value changing, so neither is noted; the resolve
    // step is the only route either takes into T2 and T3. Mutation that must turn this red: leave T2 and T3 out of the
    // resolve step (`patch-resolve-cancellations`).
    @Test func aFirstSaveAndADeletionReachTwoAndThreeThroughTheResolveStep() throws {
        let (store, twin) = try store()
        let turns = EngineTurns()
        let engine = EngineHarness.started(store, turns)
        func expectInStep(_ step: String) throws {
            let fresh = try store.freshFacts()
            #expect(engine.patches.mismatches(against: fresh).isEmpty,
                    Comment(rawValue: step + ": " + engine.patches.mismatches(against: fresh).joined(separator: ", ")))
            let held = Set(engine.patches.contradictions?.slices.keys.map { $0 } ?? [])
            #expect(held == Set(fresh.shows.keys), Comment(rawValue: step + ": T2 holds other identities than the store"))
        }
        // A second twin, unsaved, so the engine takes it in under a temporary identifier.
        let second = store.addShow(contacts: 0)
        second.groupName = "Lantern Hour"
        second.venue = "Willow Barn"
        second.performanceDate = twin.performanceDate
        engine.noteChanged(second)
        turns.run()
        #expect(engine.patches.contradictions?.slices[second.persistentModelID] != nil,
                "the unsaved show was not taken in, so its first save re-keys nothing here")
        try store.context.save()
        turns.run()
        try expectInStep("after the first save")
        // Both twins deleted: the contradiction goes, and the break's covered count with it.
        store.context.delete(twin)
        store.context.delete(second)
        try store.context.save()
        turns.run()
        try expectInStep("after the deletion")
        #expect(engine.patches.contradictions?.contradictedKeys.isEmpty == true, "the contradiction outlived its twins")
    }

    // The verifier reports the stale terms as `patchMismatch` once the facts agree (#4360's verdict).
    @Test func theVerifierReportsAStaleTermAsAPatchMismatch() throws {
        let (store, twin) = try store()
        var patches = QueueEnginePatches()
        patches.bringUp(to: try store.freshFacts(), asOf: asOf)
        store.context.delete(twin)
        try store.context.save()
        let fresh = try store.freshFacts()
        let derivation = EngineDerivations.counts()
        let value = derivation.derive(QueueEnginePassInput(facts: fresh, viewInputs: QueueEngineViewInputs(),
                                                           now: EngineStore.baseNow, context: EngineHarness.noSignals))
        let snapshot = QueueEngineSnapshot(saveCount: 0, generation: 7, facts: fresh, viewInputs: QueueEngineViewInputs(),
                                           context: EngineHarness.noSignals, now: EngineStore.baseNow, value: value,
                                           clean: true, patches: patches)
        guard case .patchMismatch(let fields, 7) = QueueEngineVerifier.compare(snapshot, with: fresh,
                                                                                derivation: derivation) else {
            Issue.record("a stale T2 and T3 were not a patch mismatch")
            return
        }
        #expect(fields.contains("contradictions.contradicted") && fields.contains("feedBreaks.events"), "\(fields)")
    }
}

// MARK: - Cost (opt in)

// What T2 and T3 cost inside the engine's pass over facts, and what the patches cost per change, on a clone of the live
// store and its fourfold copy. OPT IN on #4106's rule for every probe of this kind (it clones Dan's store, and a
// stopwatch on a shared Mac measures the Mac, L224); without the variable it says it did not run (L98):
//
//   TEST_RUNNER_MEASURE_4361=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/QueueEnginePatchedCancellationsCostProbeTests
//
// Counts and milliseconds only, never a name (L222). Debug, medians of five, the load beside each block (L356, L395).
@Suite("#4361 T2 and T3 inside the engine's pass, measured (opt in, live store clone)")
@MainActor
final class QueueEnginePatchedCancellationsCostProbeTests {

    private let sandboxes = TemporarySandboxes()

    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["MEASURE_4361"] != nil }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func theTermsInsideTheEnginesPassAtOneAndFourTimesTheStore() throws {
        guard Self.enabled else {
            print("patched-4361: not measured. Set TEST_RUNNER_MEASURE_4361=1 to run it.")
            return
        }
        let dir = try sandboxes.make(named: "patched-4361")
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        let big = try Phase0.scaledCopy(of: clone, factor: 4, in: dir)
        for (label, url) in [("live clone", clone), ("4x", big)] {
            let container = try Phase0.openContainer(at: url)
            let facts = try FactStore.extractAll(from: container.mainContext)
            let shows = QueueEngineQueue.shows(facts)
            let now = Date()
            let asOf = EasternDate.today(now)
            let set = ContradictedCancellation.contradictedKeys(among: shows)
            let t2Reading = Phase0.median5("patched4361-t2Cold-\(label)") {
                _ = ContradictedCancellation.contradictedKeys(among: shows)
            }
            let t3Reading = Phase0.median5("patched4361-t3Cold-\(label)") {
                _ = FeedBreakEvent.events(among: shows, asOf: asOf, contradicted: set)
            }
            func input(_ keys: Set<String>, patches: QueueEnginePatches?) -> QueueEnginePassInput {
                QueueEnginePassInput(facts: facts,
                                     viewInputs: QueueEngineViewInputs(focusedStage: .scout, focusedKeys: nil,
                                                                       requestedCardKeys: keys),
                                     now: now, context: EngineHarness.noSignals, patches: patches)
            }
            let viewport = Set(QueueEngineQueue.derive(input([], patches: nil)).data.focusedRows
                .prefix(QueueViewportAssumption.rows).map(\.id))
            // T2 and T3 alone, built cold from every show (T1 beside them is #4360's to measure).
            var t2 = PatchableContradictions(), t3 = PatchableFeedBreaks(asOf: asOf)
            let cold = Phase0.median5("patched4361-patchesCold-\(label)") {
                t2 = PatchableContradictions()
                t3 = PatchableFeedBreaks(asOf: asOf)
                let flips = t2.apply(facts.shows.map { ($0.key, PatchableContradictions.Slice($0.value)) })
                t3.apply(facts.shows.map { ($0.key, PatchableFeedBreaks.Slice($0.value)) }, flips: flips,
                         covered: t2.contradictedKeys)
            }
            #expect(t2.contradictedKeys == set && t3.output == FeedBreakEvent.events(among: shows, asOf: asOf),
                    "the patched values disagree with the terms")
            // The pass handed every patched term (T1 too, as the engine hands it) against the pass handed none: the
            // terms' share of today's pass. T1's own share is #4360's reading.
            var all = QueueEnginePatches()
            all.bringUp(to: facts, asOf: asOf)
            let unpatchedPass = input(viewport, patches: nil)
            let patchedPass = input(viewport, patches: all)
            // Alternated, so neither arm always runs second (#4617).
            var whole: [Double] = [], lean: [Double] = []
            for round in 0..<10 {
                let a = Phase0.time { _ = QueueEngineQueue.derive(unpatchedPass) }
                let b = Phase0.time { _ = QueueEngineQueue.derive(patchedPass) }
                if round % 2 == 0 { whole.append(a); lean.append(b) } else {
                    lean.append(Phase0.time { _ = QueueEngineQueue.derive(patchedPass) })
                    whole.append(Phase0.time { _ = QueueEngineQueue.derive(unpatchedPass) })
                }
            }
            print(Phase0.orderLine(alternated: true, ["patched4361-passUnpatched-\(label)",
                                                      "patched4361-passPatched-\(label)"]))
            // Every row changed and changed back, through the patches: the per change cost over every real room.
            // The moved value is read from the model with its title changed and put back unsaved, outside the timing.
            var live = Phase0cStats(), flagged = Phase0cStats(), other = Phase0cStats()
            for model in try container.mainContext.fetch(FetchDescriptor<Prospect>()) {
                let id = model.persistentModelID
                guard let row = facts.shows[id] else { continue }
                let title = model.groupName
                model.groupName = title + " Encore Evening"
                let moved = RowFacts.extract(model)
                model.groupName = title
                let ms = Phase0.time {
                    for value in [moved, row] {
                        let flips = t2.apply([(id, PatchableContradictions.Slice(value))])
                        t3.apply([(id, PatchableFeedBreaks.Slice(value))], flips: flips, covered: t2.contradictedKeys)
                    }
                }
                if row.missedScoutCount == 0 { live.add(ms / 2) } else if row.disappearedFromFeed {
                    flagged.add(ms / 2)
                } else { other.add(ms / 2) }
            }
            print("""
                patched-4361 [\(label)] \(Phase0.load())
                  shows \(shows.count), contradicted \(set.count), breaks \(t3.output.count)
                  T2 contradictedKeys over facts, whole corpus   \(t2Reading.text)  (plan census 143.2 ms at 5,376, over models)
                  T3 feed break events over facts, set given     \(t3Reading.text)  (plan census 149.9 ms at 5,376, before Step C)
                  the patches built cold, both terms             \(cold.text)
                  the engine's pass, nothing patched             \(Phase0.reading("patched4361-passUnpatched-\(label)", runs: whole).text)
                  the engine's pass, T1, T2 and T3 patched       \(Phase0.reading("patched4361-passPatched-\(label)", runs: lean).text)
                  one change through the patches, live row       \(live.text("patched4361-changeLive-\(label)"))
                  one change through the patches, flagged row    \(flagged.text("patched4361-changeFlagged-\(label)"))
                  one change through the patches, other row      \(other.text("patched4361-changeOther-\(label)"))
                  budget line: contradictions and feed breaks 3 ms per change at 5,376 (plan section 13)
                """)
        }
    }
}
