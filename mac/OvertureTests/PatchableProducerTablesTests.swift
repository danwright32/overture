import Foundation
import SwiftData
import Testing

// #4362 (plan v7 Phase 4b(c), discussion #4267 sections 4 and 7 T4): the producer tables' patched value, proven.
//
// The same three harnesses T1 (#4360) is held to, each on T4's op mix (0b.1's ten kinds plus the plan's four: an
// adversarial venue of the corpus's commonest words, one venue key added and removed again and again, a presenter key
// that is also a venue key, and a venue-only edit taking a presenter from one room to two):
//
// 1. THE PER TERM HARNESS (`PatchPropertyHarness`, `ProducerTablesHarnessTerm`). Seeded operation sequences over the
//    committed synthetic fixtures of 60 and 300 rows, with invented presenters (`Phase0cFixture.presenters`). After
//    EVERY operation and every undo the product value, fed from `RowFacts` as the engine feeds it, must equal the
//    oracle (`QueueModel.ProducerTables(shows:overrides:)`, which is `ProducerGate.Corpus` plus `VenueBrands`) over the
//    store as it stands, AND every presenter's brand verdict must equal the brute force over the definition with no
//    word prefilter (`phase0bBruteBrand`), because the patch and the oracle share the word candidate function, the
//    containment predicate and the arm order (L70). ChangedKeys must name exactly the presenter keys whose verdict
//    moved. Its named mutation (plan section 7): drop the witness decrement when a venue key leaves.
// 2. THE WHOLE PASS HARNESS (`EnginePropertyHarness`, with presenters and T4's ops): the engine's published pass held
//    to the pass over a fresh read with no patch, so a change the engine took in and never handed T4 (an override,
//    which changes no show) is seen.
// 3. THE VERIFIER KIND: a T4 out of step with facts that agree is `patchMismatch`, naming the table.
//
// Failures name seed, step, operation and the tables that differ, never a name. The cost probe is opt in, clones the
// live store, and prints counts and durations only:
//
//   TEST_RUNNER_MEASURE_4362=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/PatchableProducerTablesCostProbeTests
//
// Deep runs of the two harnesses share T1's switch, TEST_RUNNER_MEASURE_4360_DEEP=1 (20 seeds by 500 operations).

/// T4 as the per term harness drives it: the product value, fed from `RowFacts` as the engine feeds it.
@MainActor
struct ProducerTablesHarnessTerm: PatchHarnessTerm {
    typealias Patch = PatchableProducerTables<PersistentIdentifier>
    typealias Verdicts = [String: Phase0cProducerTables.Out]
    static let ops = Phase0cOp.t4

    private var patch: Patch
    /// The oracle's verdict per presenter key as of the last apply, for judging ChangedKeys.
    private var lastVerdicts: Verdicts

    static func world(size: Int, seed: UInt64) throws -> Phase0cWorld {
        try Phase0cWorld(size: size, seed: seed,
                         models: [Prospect.self, Recipient.self, PromotedProducer.self, DemotedHouse.self],
                         presenters: true)
    }

    static func facts(_ p: Prospect) -> Patch.Facts { Patch.Facts(of: RowFacts.extract(p)) }

    static func shows(_ rows: [Prospect]) -> [ProducerGate.Show] { rows.map(ProducerGate.Show.init) }

    static func overrides(_ world: Phase0cWorld) -> ProducerOverrides? { try? world.overrides() }

    /// The tables that differ between `held` and the oracle's cold build over `rows`, by name only.
    static func differing(_ held: QueueModel.ProducerTables, rows: [Prospect], overrides: ProducerOverrides) -> [String] {
        let oracle = QueueModel.ProducerTables(shows: shows(rows), overrides: overrides)
        var out: [String] = []
        if held.corpus.venues != oracle.corpus.venues { out.append("venues") }
        if held.corpus.venuesByPresenter != oracle.corpus.venuesByPresenter { out.append("venuesByPresenter") }
        if held.venueBrands != oracle.venueBrands { out.append("venueBrands") }
        return out
    }

    /// The patch's verdict per presenter key against the oracle's and the brute force's, by 8 hex digit hash.
    static func verdictFailures(_ patch: Patch, rows: [Prospect], overrides: ProducerOverrides) -> [String] {
        let want = Phase0cT4Check.oracleOutputs(shows(rows), overrides: overrides)
        let venueKeys = ProducerGate.Corpus(shows(rows)).venues.keys
        var out: [String] = []
        for (key, oracle) in want {
            let got = patch.verdict(key).map {
                Phase0cProducerTables.Out(brand: $0.brand, room: $0.roomName, count: $0.venueCount, qualifies: $0.qualifies)
            }
            if got != oracle { out.append("verdict \(Phase0b.hash8(key)) patch \(String(describing: got)) oracle \(oracle)") }
            if phase0bBruteBrand(key, venueKeys: venueKeys, overrides: overrides) != got?.brand {
                out.append("verdict \(Phase0b.hash8(key)) brand differs from the brute force with no word prefilter")
            }
        }
        return out
    }

    init(rows: [Prospect], world: Phase0cWorld) {
        let overrides = Self.overrides(world) ?? .none
        patch = Patch(rows: rows.map { (key: $0.persistentModelID, facts: Self.facts($0)) }, overrides: overrides)
        lastVerdicts = Phase0cT4Check.oracleOutputs(Self.shows(rows), overrides: overrides)
    }

    mutating func apply(_ changed: Set<PersistentIdentifier>, rows: [Prospect],
                        world: Phase0cWorld) -> (failures: [String], flips: Int) {
        guard let overrides = Self.overrides(world) else { return (["the overrides could not be read"], 0) }
        let byID = Dictionary(rows.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
        let result = patch.apply(changed.map { (key: $0, facts: byID[$0].map(Self.facts)) }, overrides: overrides)
        // ChangedKeys must name EXACTLY the presenter keys whose verdict moved, judged from the oracle's verdicts
        // before and after rather than from the patch's own bookkeeping (L70).
        let now = Phase0cT4Check.oracleOutputs(Self.shows(rows), overrides: overrides)
        let real = Phase0cT4Check.changedKeys(lastVerdicts, now)
        lastVerdicts = now
        var failures: [String] = []
        if !real.subtracting(result.presenterKeys).isEmpty {
            failures.append("ChangedKeys missed \(real.subtracting(result.presenterKeys).count) presenter keys whose verdict moved")
        }
        if !result.presenterKeys.subtracting(real).isEmpty {
            failures.append("ChangedKeys named \(result.presenterKeys.subtracting(real).count) presenter keys whose verdict did not move")
        }
        return (failures, result.presenterKeys.count)
    }

    func mismatch(rows: [Prospect], world: Phase0cWorld) -> String? {
        guard let overrides = Self.overrides(world) else { return "the overrides could not be read" }
        let found = Self.differing(patch.tables, rows: rows, overrides: overrides).map { "T4 patch differs in \($0)" }
            + Self.verdictFailures(patch, rows: rows, overrides: overrides)
        return found.isEmpty ? nil : found.prefix(5).joined(separator: "; ")
    }

    static func coldMismatch(rows: [Prospect], world: Phase0cWorld) -> String? {
        guard let overrides = overrides(world) else { return "the overrides could not be read" }
        let cold = Patch(rows: rows.map { (key: $0.persistentModelID, facts: facts($0)) }, overrides: overrides)
        let found = differing(cold.tables, rows: rows, overrides: overrides)
        return found.isEmpty ? nil : "T4 cold build differs in \(found)"
    }

    static func oracleMovesWithOrder(rows: [Prospect], world: Phase0cWorld) -> Bool {
        let overrides = overrides(world) ?? .none
        let reversed = QueueModel.ProducerTables(shows: shows(Array(rows.reversed())), overrides: overrides)
        return !differing(reversed, rows: rows, overrides: overrides).isEmpty
    }
}

// MARK: - The suite

@MainActor
@Suite("T4 producer tables patched inside the queue engine equal their oracle (#4362, plan v7 Phase 4b(c))")
struct PatchableProducerTablesTests {

    typealias Patch = ProducerTablesHarnessTerm.Patch

    @Test func thePatchEqualsTheOracleAndTheBruteForceAfterEveryOperationAndUndo() throws {
        let result = try PatchPropertyHarness.runAll(ProducerTablesHarnessTerm.self, ci: [(60, 3, 40), (300, 1, 20)])
        print(result.outcome.report("T4 per term", settings: result.settings, ms: result.ms))
        #expect(result.outcome.failures.isEmpty, "T4: the patched value disagreed with the oracle or the brute force")
        // Positive controls (L159): enough comparisons, a verdict that moved, and every op in the mix applied.
        #expect(result.outcome.checks > 100, "T4: the harness compared too little to mean anything")
        #expect(result.outcome.handOffs > 0, "T4: no presenter's verdict ever moved, so ChangedKeys was never judged")
        #expect(Set(result.outcome.applied.keys) == Set(Phase0cOp.t4),
                "T4: an op in the mix never ran: \(Set(Phase0cOp.t4).subtracting(result.outcome.applied.keys).map(\.rawValue))")
    }

    @Test func theEnginesPublishedPassEqualsThePassWithNoPatchAfterEveryOperation() async throws {
        let result = try await EnginePropertyHarness.runAll(ci: [(60, 2, 25), (300, 1, 10)], ops: Phase0cOp.t4,
                                                            presenters: true, seedBase: 4362_5000)
        print(result.outcome.report("T4 whole pass", settings: result.settings, ms: result.ms))
        #expect(result.outcome.failures.isEmpty, "the engine's pass with T4 patched disagreed with the pass without it")
        #expect(result.outcome.checks > 40, "the whole pass harness compared too little to mean anything")
        #expect(result.outcome.handOffs > 0, "no brand verdict moved through the engine, so no hand-off was judged")
    }

    // The fixture reaches every arm the rule has, or the harnesses above prove the patch over a corpus that never asks
    // the hard question (L159): a presenter spelled like a room, one that contains or is contained in a room's name,
    // and a producer playing two rooms.
    @Test func theFixtureReachesEveryArmOfTheRule() throws {
        let world = try ProducerTablesHarnessTerm.world(size: 60, seed: 4362_0001)
        let verdicts = Phase0cT4Check.oracleOutputs(ProducerTablesHarnessTerm.shows(try world.rows()), overrides: .none)
        #expect(verdicts.values.contains { $0.room }, "no presenter is spelled exactly like a room")
        #expect(verdicts.values.contains { $0.brand && !$0.room }, "no presenter names a room by containment")
        #expect(verdicts.values.contains { $0.qualifies }, "no presenter plays two rooms")
        // A presenter that is neither (one room, no brand) is what `insertNewPresenter` makes, since every invented
        // presenter in a 60 row fixture plays several rooms (measured on the first run of this test).
    }

    // The engine's own pass READS T4's tables rather than building them (L3): a pass handed the patches builds no
    // producer index, and the same pass handed none builds one, which is the positive control (L159).
    @Test func theEnginesPassReadsThePatchedTablesAndBuildsNone() throws {
        let world = try Phase0cWorld(size: 60, seed: 4362_0007, models: AppSchema.models, presenters: true)
        let facts = try FactStore.extractAll(from: ModelContext(world.container))
        var patches = QueueEnginePatches()
        patches.bringUp(to: facts)
        let plain = QueueEnginePassInput(facts: facts, viewInputs: QueueEngineViewInputs(), now: EngineStore.baseNow,
                                         context: EngineHarness.noSignals)
        var patched = plain
        patched.patches = patches
        let without = QueueRenderPass.WorkTally.measure { _ = QueueEngineQueue.derive(plain) }
        let with = QueueRenderPass.WorkTally.measure { _ = QueueEngineQueue.derive(patched) }
        #expect(without.producerIndexes >= 1, "the pass with no patch built no producer index, so this proves nothing")
        #expect(with.producerIndexes == 0, "the engine's pass built the producer tables although it was handed them")
    }

    // A change to anything T4 does not read (a dismissal) costs it nothing: no presenter re-asked, no witness tested.
    @Test func aChangeToNothingT4ReadsIsNoWork() throws {
        let world = try ProducerTablesHarnessTerm.world(size: 60, seed: 4362_0002)
        let rows = try world.rows()
        var patch = Patch(rows: rows.map { (key: $0.persistentModelID, facts: ProducerTablesHarnessTerm.facts($0)) },
                          overrides: .none)
        let row = try #require(rows.first { $0.presenter != nil })
        row.statusRaw = ReviewStatus.dismissed.rawValue
        let changed = patch.apply([(key: row.persistentModelID, facts: ProducerTablesHarnessTerm.facts(row))],
                                  overrides: .none)
        #expect(changed == Patch.Changed())
    }

    // The patch answers an empty store and a deletion of every row as the oracle does: nothing left behind, and every
    // presenter that was there reported as moved.
    @Test func aPatchEmptiedByDeletionHoldsNothing() throws {
        let world = try ProducerTablesHarnessTerm.world(size: 60, seed: 4362_0003)
        let rows = try world.rows()
        var patch = Patch(rows: rows.map { (key: $0.persistentModelID, facts: ProducerTablesHarnessTerm.facts($0)) },
                          overrides: .none)
        let presenters = Set(rows.compactMap { ProducerGate.key($0.presenter) })
        #expect(!presenters.isEmpty, "the fixture has no presenters, so this proves nothing")
        let changed = patch.apply(rows.map { (key: $0.persistentModelID, facts: nil) }, overrides: .none)
        #expect(ProducerTablesHarnessTerm.differing(patch.tables, rows: [], overrides: .none).isEmpty,
                "rows deleted from the patch left a table behind")
        #expect(changed.presenterKeys == presenters, "a presenter that left was missing from ChangedKeys")
        #expect(ProducerTablesHarnessTerm.differing(Patch(rows: [], overrides: .none).tables, rows: [],
                                                    overrides: .none).isEmpty)
    }

    // The verifier's comparison (plan v7 D7 (ii)): T4 kept while the store moved under it is `patchMismatch`, naming the
    // tables that differ. A presenter-only edit, which T1 does not read, so only T4's tables can be named.
    @Test func aStaleT4IsAPatchMismatchNamingItsTables() throws {
        let world = try Phase0cWorld(size: 60, seed: 4362_0004, models: AppSchema.models, presenters: true)
        var stale = QueueEnginePatches()
        let before = try FactStore.extractAll(from: ModelContext(world.container))
        stale.bringUp(to: before)
        #expect(stale.mismatches(against: before).isEmpty, "a patch built from these facts disagreed with them")
        // A presenter spelled exactly like a room the fixture always has (its feed break rows play Willow Barn), which
        // no row's presenter is: a new presenter key, and a room name brand.
        let row = try #require(try world.rows().first { $0.presenter != "Willow Barn" })
        row.presenter = "Willow Barn"
        try world.context.save()
        let fresh = try FactStore.extractAll(from: ModelContext(world.container))
        let verdict = QueueEngineVerifier.compare(snapshot(fresh, stale, generation: 7), with: fresh,
                                                  derivation: EngineDerivations.counts())
        #expect(verdict == .patchMismatch(fields: ["producerTables.venuesByPresenter", "producerTables.venueBrands"],
                                          generation: 7), "\(verdict)")
        // Brought up to the same facts, the same patch agrees, so the verdict was about T4 and nothing else.
        var current = stale
        current.noteChanged(row.persistentModelID)
        current.bringUp(to: fresh)
        #expect(current.mismatches(against: fresh).isEmpty)
        #expect(QueueEngineVerifier.compare(snapshot(fresh, current, generation: 8), with: fresh,
                                            derivation: EngineDerivations.counts()) == .match(generation: 8))
    }

    // An override changes no show, so nothing is pending: the bring-up must still reach T4 by comparing the overrides,
    // and the verifier must name a T4 that missed one.
    @Test func aPromotionReachesT4WithNoShowPendingAndAStaleOneIsNamed() throws {
        let world = try Phase0cWorld(size: 60, seed: 4362_0005, models: AppSchema.models, presenters: true)
        var patches = QueueEnginePatches()
        let before = try FactStore.extractAll(from: ModelContext(world.container))
        patches.bringUp(to: before)
        let stale = patches
        // A presenter the containment arm refuses (a brand that is not a room name), which promotion relaxes.
        let verdicts = Phase0cT4Check.oracleOutputs(ProducerTablesHarnessTerm.shows(try world.rows()), overrides: .none)
        let key = try #require(verdicts.filter { $0.value.brand && !$0.value.room }.keys.sorted().first)
        world.context.insert(PromotedProducer(orgKey: key))
        try world.context.save()
        let fresh = try FactStore.extractAll(from: ModelContext(world.container))
        #expect(stale.mismatches(against: fresh) == ["producerTables.venueBrands"])
        #expect(patches.pending.isEmpty, "an override noted a show, so this does not test the overrides route")
        patches.bringUp(to: fresh)
        #expect(patches.mismatches(against: fresh).isEmpty, "the bring-up did not carry the promotion into T4")
        #expect(patches.producerTables?.verdict(key)?.brand == false)
    }

    // A resolution reaches T4 at once: a deleted show's presenter and venue leave it before any pass.
    @Test func aDeletionResolvedThroughTheEngineLeavesT4BeforeAnyPass() throws {
        let world = try Phase0cWorld(size: 60, seed: 4362_0006, models: AppSchema.models, presenters: true)
        var patches = QueueEnginePatches()
        let facts = try FactStore.extractAll(from: ModelContext(world.container))
        patches.bringUp(to: facts)
        // A row whose presenter no other row carries, so the deletion takes its key out of the corpus.
        let rows = try world.rows()
        let counts = Dictionary(rows.compactMap { ProducerGate.key($0.presenter) }.map { ($0, 1) }, uniquingKeysWith: +)
        let lone = try #require(rows.first { ProducerGate.key($0.presenter).map { counts[$0] == 1 } ?? false }
                                ?? rows.first { $0.presenter != nil })
        var resolution = QueueEngineResolution()
        resolution.deletedIDs = [lone.persistentModelID]
        resolution.deletedKeys = [lone.naturalKey]
        var remaining = facts.shows
        remaining[lone.persistentModelID] = nil
        patches.resolve(resolution, shows: remaining)
        #expect(patches.pending.isEmpty)
        var pruned = facts
        pruned.shows = remaining
        #expect(patches.mismatches(against: pruned).isEmpty, "T4 after the resolution is not the oracle's")
    }

    private func snapshot(_ facts: FactStore, _ patches: QueueEnginePatches,
                          generation: Int) -> QueueEngineSnapshot<EngineDerivations.Counts> {
        QueueEngineSnapshot(saveCount: 1, generation: generation, facts: facts, viewInputs: QueueEngineViewInputs(),
                            context: EngineHarness.noSignals, now: EngineStore.baseNow,
                            value: EngineDerivations.Counts(shows: facts.shows.count), clean: true, patches: patches)
    }
}

// MARK: - The cost probe (opt in)

// Plan v7 section 13: T4's per change budget line at 5,376 is 5 ms, and a term whose measured MAX at 5,376 exceeds
// twice that with no fix inside its PR stops the plan. Section 4: the max is over EVERY real key of each kind (0c.3's
// kinds: every venue key leaving and coming back, every presenter's '<presenter> Theatre' edit, every venue key as a
// presenter, every one-room presenter moving to a second room, every presenter key promoted, the adversarial venue
// and the repeated one), with p99 and median beside it, never the worst of a few chosen changes (L147). Beside it the
// cold arm (the patch built from nothing with complete witness sets against today's cold build, which the engine paid
// on every pass before this) and the engine's whole pass with and without the patches, alternated (#4617).
@MainActor
@Suite("#4362 T4 producer tables patched: cost per change over the live clone (opt in)", .serialized)
final class PatchableProducerTablesCostProbeTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["MEASURE_4362"] != nil }

    static let budgetMs = 5.0
    static var stopMs: Double { 2 * budgetMs }

    typealias Patch = PatchableProducerTables<Phase0cKey>

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func perChangeCostAtOneAndFourTimesTheStore() throws {
        guard Self.enabled else {
            print("patch-4362 cost: not measured. Set TEST_RUNNER_MEASURE_4362=1 to run it.")
            return
        }
        let dir = try sandboxes.make(named: "patch-4362")
        guard let clone = try LiveStoreClone.makeClone(in: dir) else {
            throw LiveStoreClone.Refusal.backupFailed("no live store on this machine")
        }
        var failures: [String] = []
        var maxAt4x: Double?
        for (label, url) in [("live clone", clone), ("4x", try Phase0.scaledCopy(of: clone, factor: 4, in: dir))] {
            let all = try cost(label: label, url: url, failures: &failures)
            if label == "4x" { maxAt4x = all.count > 0 ? all.max : nil }
        }
        let verdict: String
        if !failures.isEmpty {
            verdict = "FAIL (mismatches)"
        } else if let maxAt4x {
            verdict = maxAt4x <= Self.stopMs
                ? (maxAt4x <= Self.budgetMs ? "WITHIN BUDGET" : "OVER BUDGET, UNDER THE STOP")
                : "STOP (over twice the budget line)"
        } else {
            verdict = "UNMEASURED (no change was timed at 4x)"
        }
        let maxText = maxAt4x.map { String(format: "%.3f ms", $0) } ?? "none"
        print("patch-4362 VERDICT \(verdict): mismatches \(failures.count), max per change at 4x \(maxText) "
              + String(format: "(budget %.0f ms, stop %.0f ms at 5,376)", Self.budgetMs, Self.stopMs))
        if !failures.isEmpty { print("patch-4362 FAILURES\n  " + failures.prefix(30).joined(separator: "\n  ")) }
        #expect(failures.isEmpty, "the patched producer tables disagreed with the oracle on the clone")
        #expect(maxAt4x != nil, "nothing was timed at 4x")
    }

    private func cost(label: String, url: URL, failures: inout [String]) throws -> Phase0cStats {
        let container = try Phase0.openContainer(at: url)
        let facts = try FactStore.extractAll(from: ModelContext(container))
        let shows = QueueEngineQueue.shows(facts)
        let current = facts.producerOverrides
        let load = Phase0.load()

        // The cold arm: today's build over the engine's facts (what every engine pass paid before this PR) against the
        // patch built from nothing with complete witness sets, alternated so neither carries the order effect.
        var world: [Phase0cKey: ProducerGate.Show] = [:]
        for show in shows { world[.row(show.persistentModelID)] = ProducerGate.Show(show) }
        let everyRow = shows.map { (key: Phase0cKey.row($0.persistentModelID), facts: Patch.Facts(of: $0)) }
        var patch = Patch(rows: [], overrides: current)
        let coldArms = Phase0.alternating([
            (metric: "t4-todayCold-\(label)", work: { _ = QueueModel.ProducerTables(rows: shows, overrides: current) }),
            (metric: "t4-patchCold-\(label)", work: { patch = Patch(rows: everyRow, overrides: current) }),
        ])

        // The engine's whole pass over the same facts, with no patch and with the patches brought up, the first screen's
        // cards requested as the queue requests them. Alternated.
        var patches = QueueEnginePatches()
        patches.bringUp(to: facts)
        let now = Date()
        let firstView = QueueEngineViewInputs(focusedStage: .scout, focusedKeys: nil, requestedCardKeys: [])
        let probeView = QueueEngineQueue.derive(QueueEnginePassInput(facts: facts, viewInputs: firstView, now: now,
                                                                     context: EngineHarness.noSignals))
        let viewport = Set(probeView.data.focusedRows.prefix(QueueViewportAssumption.rows).map(\.id))
        let view = QueueEngineViewInputs(focusedStage: .scout, focusedKeys: nil, requestedCardKeys: viewport)
        let plain = QueueEnginePassInput(facts: facts, viewInputs: view, now: now, context: EngineHarness.noSignals)
        let patched = QueueEnginePassInput(facts: facts, viewInputs: view, now: now, context: EngineHarness.noSignals,
                                           patches: patches)
        let fields = QueueEngineQueue.differingFields(QueueEngineQueue.derive(plain), QueueEngineQueue.derive(patched))
        if !fields.isEmpty { failures.append("\(label): the pass with the patches differs from the pass without in \(fields)") }
        let passes = Phase0.alternating([
            (metric: "t4-passNoPatch-\(label)", work: { _ = QueueEngineQueue.derive(plain) }),
            (metric: "t4-passPatched-\(label)", work: { _ = QueueEngineQueue.derive(patched) }),
        ])

        var folds: [String: String?] = [:]
        func fold(_ raw: String?) -> String? {
            guard let raw else { return nil }
            if let hit = folds[raw] { return hit }
            let key = ProducerGate.key(raw)
            folds[raw] = key
            return key
        }
        func slice(_ show: ProducerGate.Show) -> Patch.Facts {
            Patch.Facts(presenterKey: fold(show.presenter), venueKey: fold(show.venue))
        }
        var mismatches = 0, checks = 0
        func verify(_ what: String, overrides: ProducerOverrides = current) {
            checks += 1
            let oracle = QueueModel.ProducerTables(shows: Array(world.values), overrides: overrides)
            let held = patch.tables
            var differs: [String] = []
            if held.corpus.venues != oracle.corpus.venues { differs.append("venues") }
            if held.corpus.venuesByPresenter != oracle.corpus.venuesByPresenter { differs.append("venuesByPresenter") }
            if held.venueBrands != oracle.venueBrands { differs.append("venueBrands") }
            if !differs.isEmpty {
                mismatches += 1
                failures.append("\(label) \(what): the patch differs from the oracle in \(differs)")
            }
        }
        verify("cold build")

        // One change and its undo, each timed, with the witness tests each made.
        func pair(_ doIt: [(key: Phase0cKey, show: ProducerGate.Show?)], _ doOverrides: ProducerOverrides,
                  _ undo: [(key: Phase0cKey, show: ProducerGate.Show?)], _ undoOverrides: ProducerOverrides)
            -> (doMs: Double, doWork: Int, undoMs: Double, undoWork: Int) {
            let forward = doIt.map { (key: $0.key, facts: $0.show.map(slice)) }
            let back = undo.map { (key: $0.key, facts: $0.show.map(slice)) }
            var a = Patch.Changed(), b = Patch.Changed()
            let doMs = Phase0.time { a = patch.apply(forward, overrides: doOverrides) }
            let undoMs = Phase0.time { b = patch.apply(back, overrides: undoOverrides) }
            return (doMs, a.witnessTests, undoMs, b.witnessTests)
        }

        var kinds: [Phase0cKind] = []
        var keysByVenue: [Phase0cKey: String] = [:]
        var rowsByVenue: [String: [Phase0cKey]] = [:]
        for (key, show) in world {
            guard let v = fold(show.venue) else { continue }
            keysByVenue[key] = v
            rowsByVenue[v, default: []].append(key)
        }
        let venueKeys = rowsByVenue.keys.sorted()
        let stride = max(1, venueKeys.count / 12)

        // Every real venue key LEAVES (every row at it deleted in one change) and APPEARS again.
        let leaves = Phase0cKind("every venue key leaves (all its rows deleted), then appears again")
        for (i, v) in venueKeys.enumerated() {
            let keys = rowsByVenue[v] ?? []
            let removed = keys.map { (key: $0, show: ProducerGate.Show?.none) }
            let restored = keys.map { (key: $0, show: world[$0]) }
            if i % stride == 0 {
                patch.apply(removed.map { (key: $0.key, facts: Patch.Facts?.none) }, overrides: current)
                for key in keys { world[key] = nil }
                verify("venue \(Phase0b.hash8(v)) gone")
                for (key, show) in restored { world[key] = show }
                patch.apply(restored.map { (key: $0.key, facts: $0.show.map(slice)) }, overrides: current)
            }
            leaves.sample { pair(removed, current, restored, current) }
        }
        kinds.append(leaves)
        verify("after every venue key left and came back")

        // 0b.1's tail kind, for every presenter key: one row's venue edited to '<presenter> Theatre', and back.
        var firstRowOf: [String: Phase0cKey] = [:]
        for show in shows {
            let key = Phase0cKey.row(show.persistentModelID)
            if let p = fold(show.presenter), firstRowOf[p] == nil { firstRowOf[p] = key }
        }
        let theatre = Phase0cKind("every presenter: one row's venue edited to '<presenter> Theatre', and back")
        for (p, key) in firstRowOf.sorted(by: { $0.key < $1.key }) {
            guard let old = world[key] else { continue }
            let edited = ProducerGate.Show(presenter: old.presenter, venue: "\(old.presenter ?? p) Theatre")
            theatre.sample { pair([(key, edited)], current, [(key, old)], current) }
        }
        kinds.append(theatre)

        // Every venue key spelled as a new row's presenter: a presenter key that is also a venue key.
        let probe = Phase0cKey.probe(0)
        let asPresenter = Phase0cKind("every venue key as a new row's presenter, added and removed")
        for v in venueKeys {
            guard let first = rowsByVenue[v]?.first, let raw = world[first]?.venue else { continue }
            asPresenter.sample { pair([(probe, ProducerGate.Show(presenter: raw, venue: nil))], current, [(probe, nil)], current) }
        }
        kinds.append(asPresenter)

        // Every presenter at exactly one room with two or more rows: one row moved to the commonest room, and back.
        var rowsOf: [String: [Phase0cKey]] = [:]
        for (key, show) in world { if let p = fold(show.presenter) { rowsOf[p, default: []].append(key) } }
        let commonest = rowsByVenue.max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }
        let secondRoom = commonest.flatMap { $0.value.first }.flatMap { world[$0]?.venue }
        let oneToTwo = Phase0cKind("every one-room presenter: venue-only edit to a second room, and back")
        for (_, keys) in rowsOf.sorted(by: { $0.key < $1.key }) where keys.count >= 2 {
            let rooms = Set(keys.compactMap { keysByVenue[$0] })
            guard rooms.count == 1, let key = keys.first, let old = world[key] else { continue }
            oneToTwo.sample { pair([(key, ProducerGate.Show(presenter: old.presenter, venue: secondRoom))], current,
                                   [(key, old)], current) }
        }
        kinds.append(oneToTwo)

        // The adversarial venue (the six commonest venue words, weighted by rows) five times, and one venue key added
        // and removed twenty times running.
        var freq: [String: Int] = [:]
        for v in venueKeys {
            for w in ProducerGate.WordPostings.words(of: v) { freq[String(w), default: 0] += rowsByVenue[v]?.count ?? 0 }
        }
        let adversarial = freq.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6).map(\.key).joined(separator: " ")
        let somePresenter = firstRowOf.sorted { $0.key < $1.key }.first.flatMap { world[$0.value]?.presenter }
        let adv = Phase0cKind("adversarial venue of the six commonest words, added and removed")
        for _ in 0..<5 {
            adv.sample { pair([(probe, ProducerGate.Show(presenter: somePresenter, venue: adversarial))], current,
                              [(probe, nil)], current) }
        }
        kinds.append(adv)
        let repeated = Phase0cKind("one venue key added and removed twenty times running")
        for _ in 0..<20 {
            repeated.sample { pair([(probe, ProducerGate.Show(presenter: somePresenter, venue: "Invented Room Number Seven"))],
                                   current, [(probe, nil)], current) }
        }
        kinds.append(repeated)

        // Every presenter key promoted (or put back, if it already was), and returned.
        let promote = Phase0cKind("every presenter key promoted, and put back")
        for p in firstRowOf.keys.sorted() {
            var next = current
            if next.promoted.contains(p) { next.promoted.remove(p) } else { next.promoted.insert(p); next.demoted.remove(p) }
            promote.sample { pair([], next, [], current) }
        }
        kinds.append(promote)
        // Back where it started (every sample undoes itself), so the end state is checked whole.
        verify("end")

        var all = Phase0cStats()
        var lines: [String] = []
        for kind in kinds {
            for ms in kind.doTimes + kind.undoTimes { all.add(ms) }
            lines += kind.lines(workLabel: "witness tests", metric: "t4-\(label)")
        }
        let cold = coldArms[1], today = coldArms[0]
        let presenters = Set(world.values.compactMap { fold($0.presenter) }).count
        print("""
            patch-4362 [\(label)] \(shows.count) shows, \(presenters) presenter keys, \(venueKeys.count) venue keys, \(load)
              T4 inside today's pass (ProducerTables cold over the facts)   \(today.text)  (plan section 7: 215.3 ms over models at 5,376)
              patched value, cold build with complete witness sets         \(cold.text), ratio \(String(format: "%.2f", cold.median / max(today.median, 0.001)))
              the engine's pass, no patch (viewport cards)                 \(passes[0].text)
              the engine's pass, T1 and T4 patched (viewport cards)        \(passes[1].text)
              \(lines.joined(separator: "\n  "))
              ALL changes                                                  \(all.text("t4-all-\(label)"))
              oracle comparisons \(checks), mismatches \(mismatches)
            """)
        return all
    }
}
