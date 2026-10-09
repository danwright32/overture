import Foundation
import SwiftData
import Testing

// #4360 (plan v7 Phase 4b(a), discussion #4267 sections 4 and 7 T1): ShowLink's patched value, proven.
//
// Three harnesses, one per thing that can be wrong, and a cost probe:
//
// 1. THE PER TERM HARNESS (`PatchPropertyHarness`). Seeded operation sequences from T1's op mix over the committed
//    synthetic fixtures of 60 and 300 rows (`Phase0cWorld`, invented containment-rich names, L155, L222). After EVERY
//    operation and every undo the product value (`PatchableShowLink`, fed from `RowFacts` exactly as the engine feeds
//    it) must equal the canonical oracle (`CanonicalOracle`, Step T0) over the store as it stands, and its ChangedKeys
//    must name every row whose answer moved. At ten sampled steps and the end, a cold build is held to the oracle
//    too, and the oracle to itself over the rows reversed. Its named mutation: skip rebuilding the bucket a row LEAVES.
// 2. THE WHOLE PASS HARNESS (`EnginePropertyHarness`). The same operations through a real queue engine with the
//    queue's own derivation: after each one the engine's published pass must equal the pass over a FRESH read with
//    no patch at all (the oracle), field by field and card by card, and the engine's verifier must agree at the end.
//    Only this one can see a hand-off: a change the engine took in and never told the patch about, which leaves the
//    per term harness green (its own named mutation drops that one line).
// 3. THE VERIFIER KIND. A patch out of step with facts that agree is `patchMismatch`, naming the tables that differ.
//
// Every failure names seed, step, operation and 8 hex digit hashes, never a title or a venue. The cost probe is
// opt in, clones the live store, and prints counts and durations only:
//
//   TEST_RUNNER_MEASURE_4360=1 mac/scripts/run-tests-locked.sh -only-testing:OvertureTests/PatchableShowLinkCostProbeTests
//
// Deep runs of the two harnesses (20 seeds by 500 operations, both fixtures) are opt in by
// TEST_RUNNER_MEASURE_4360_DEEP=1, and their output goes in the PR.

enum PatchHarnessSettings {
    nonisolated static var deep: Bool { ProcessInfo.processInfo.environment["MEASURE_4360_DEEP"] != nil }

    /// Each leg's fixture size, seeds and operations: CI settings unless the deep variable is set (L298, L353).
    static func plan(ci: [(size: Int, seeds: Int, steps: Int)]) -> [(size: Int, seeds: Int, steps: Int)] {
        deep ? [(60, 20, 500), (300, 20, 500)] : ci
    }
}

/// What one harness run did, kept apart so a green run that compared nothing reads as nothing (L98).
struct PatchHarnessOutcome {
    var checks = 0
    var skipped = 0
    var applied: [Phase0cOp: Int] = [:]
    var failures: [String] = []
    var coldChecks = 0
    var permutationChecks = 0
    /// The hand-offs into the next term, as ChangedKeys or the engine's patched tables reported them: for T1 rows whose
    /// hidden state flipped, for T4 (#4362) presenter keys whose verdict moved. The op mix must actually produce them
    /// for the harness to be about them (L159).
    var handOffs = 0

    func report(_ name: String, settings: String, ms: Double) -> String {
        let ops = applied.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }
        return """
            patch-4360 \(name) [\(settings)] \(String(format: "%.1f", ms / 1000)) s: \(checks) oracle comparisons, \
            \(coldChecks) cold builds held to the oracle, \(permutationChecks) permutation checks, \(skipped) ops skipped, \
            \(handOffs) hand-offs, mismatches \(failures.count)
              ops applied: \(ops.joined(separator: "; "))
            """ + (failures.isEmpty ? "" : "\n  FAILURES\n  " + failures.prefix(30).joined(separator: "\n  "))
    }
}

// MARK: - The per term harness

/// One patched term as the per term harness drives it, so the harness's loop is written once for every Phase 4b term.
@MainActor
protocol PatchHarnessTerm {
    /// The term's op mix (plan section 7).
    static var ops: [Phase0cOp] { get }
    /// Built cold over every row.
    init(rows: [Prospect], world: Phase0cWorld)
    /// Brought up to `rows` from the rows `changed` names. Returns what its ChangedKeys got wrong, and how many hidden
    /// (or otherwise membership) flips it reported.
    mutating func apply(_ changed: Set<PersistentIdentifier>, rows: [Prospect], world: Phase0cWorld)
        -> (failures: [String], flips: Int)
    /// The patched answer against the oracle's over `rows`: nil when they are equal, else both hashes.
    func mismatch(rows: [Prospect], world: Phase0cWorld) -> String?
    /// A COLD build over `rows` against the oracle's: nil when equal.
    static func coldMismatch(rows: [Prospect], world: Phase0cWorld) -> String?
    /// Whether the oracle gave a different answer over `rows` reversed.
    static func oracleMovesWithOrder(rows: [Prospect], world: Phase0cWorld) -> Bool
    /// #4362: the fixture the term is driven over. Every term's rows by default; a term reading a field the default
    /// fixture leaves empty (T4's presenter) builds its own.
    static func world(size: Int, seed: UInt64) throws -> Phase0cWorld
}

extension PatchHarnessTerm {
    static func world(size: Int, seed: UInt64) throws -> Phase0cWorld { try Phase0cWorld(size: size, seed: seed) }
}

@MainActor
enum PatchPropertyHarness {
    /// One seed: the world, the term built cold, then `steps` operations, checked after each and after each undo.
    static func run<Term: PatchHarnessTerm>(_: Term.Type, size: Int, seed: UInt64, steps: Int,
                                           outcome: inout PatchHarnessOutcome) throws {
        let world = try Term.world(size: size, seed: seed)
        var rows = try PatchPropertyHarness.rows(world)
        var term = Term(rows: rows, world: world)
        let sampled = Set((0..<10).map { steps * $0 / 10 })
        func check(_ step: Int, _ op: String) {
            outcome.checks += 1
            if let found = term.mismatch(rows: rows, world: world) {
                outcome.failures.append("seed \(seed) size \(size) step \(step) op \(op): \(found)")
            }
        }
        func feed(_ changed: Set<PersistentIdentifier>, _ step: Int, _ op: String) {
            let result = term.apply(changed, rows: rows, world: world)
            outcome.handOffs += result.flips
            outcome.failures += result.failures.map { "seed \(seed) size \(size) step \(step) op \(op): \($0)" }
        }
        func sampledChecks(_ step: Int) {
            outcome.coldChecks += 1
            if let found = Term.coldMismatch(rows: rows, world: world) {
                outcome.failures.append("seed \(seed) size \(size) step \(step): the cold build \(found)")
            }
            outcome.permutationChecks += 1
            if Term.oracleMovesWithOrder(rows: rows, world: world) {
                outcome.failures.append("seed \(seed) size \(size) step \(step): the canonical oracle moved with input order")
            }
        }
        check(-1, "cold build")
        for step in 0..<steps {
            let op = Term.ops[world.roll(Term.ops.count)]
            guard let edit = world.perform(op, rows: rows, fronts: frontsOf(rows)) else {
                outcome.skipped += 1
                continue
            }
            outcome.applied[op, default: 0] += 1
            let changed = try world.commit(edit)
            rows = try PatchPropertyHarness.rows(world)
            feed(changed, step, op.rawValue)
            check(step, op.rawValue)
            if op.alwaysUndone || world.roll(2) == 0 {
                let undone = try world.undo(edit)
                rows = try PatchPropertyHarness.rows(world)
                feed(undone, step, op.rawValue + " (undo)")
                check(step, op.rawValue + " (undo)")
            }
            if sampled.contains(step) { sampledChecks(step) }
        }
        check(steps, "end")
        sampledChecks(steps)
    }

    /// The world's rows in natural key order, so the op mix's picks, and so a failing seed, do not depend on the order a
    /// fetch happened to return (L343).
    static func rows(_ world: Phase0cWorld) throws -> [Prospect] {
        try world.rows().sorted(by: CanonicalOracle.byNaturalKey)
    }

    /// The oracle's fronts over `rows`, which the op mix aims its dismissals and deletions at.
    static func frontsOf(_ rows: [Prospect]) -> Set<String> {
        Set(CanonicalOracle.showLinkCollapse(rows.map(ShowLink.Row.init), drawn: ShowLinkHarnessTerm.drawn(rows))
            .fronts.keys)
    }

    /// Every seed and both fixtures.
    static func runAll<Term: PatchHarnessTerm>(_ term: Term.Type,
                                               ci: [(size: Int, seeds: Int, steps: Int)]) throws
        -> (outcome: PatchHarnessOutcome, settings: String, ms: Double) {
        let plan = PatchHarnessSettings.plan(ci: ci)
        var outcome = PatchHarnessOutcome()
        let start = Phase0.now()
        for leg in plan {
            for s in 0..<leg.seeds {
                try run(term, size: leg.size, seed: 4360_0000 + UInt64(leg.size * 100 + s), steps: leg.steps,
                        outcome: &outcome)
            }
        }
        let settings = (PatchHarnessSettings.deep ? "DEEP " : "CI ")
            + plan.map { "\($0.size) rows x \($0.seeds) seeds x \($0.steps) ops" }.joined(separator: ", ")
        return (outcome, settings, Phase0.ms(since: start))
    }
}

/// T1 as the per term harness drives it: the product value, fed from `RowFacts` as the engine feeds it.
@MainActor
struct ShowLinkHarnessTerm: PatchHarnessTerm {
    typealias Patch = PatchableShowLink<PersistentIdentifier>
    static let ops = Phase0cOp.t1

    private var patch: Patch
    /// Each row's natural key as of the last apply, so a re-keyed row's answer BEFORE is read under the key it had.
    private var keyOf: [PersistentIdentifier: String] = [:]

    /// The queue's drawn rows, by the scope's DEFINITION (every row not dismissed) rather than through the predicate
    /// the patch itself reads, so the two sides do not share it (L70).
    static func drawn(_ rows: [Prospect]) -> Set<String> {
        Set(rows.filter { $0.statusRaw != ReviewStatus.dismissed.rawValue }.map(\.naturalKey))
    }

    static func facts(_ p: Prospect) -> Patch.Facts { Patch.Facts(of: RowFacts.extract(p)) }

    static func oracle(_ rows: [Prospect]) -> String {
        let linked = rows.map(ShowLink.Row.init)
        return OracleRendering.keyed(CanonicalOracle.showLinkGroup(linked)) + " | "
            + OracleRendering.collapse(CanonicalOracle.showLinkCollapse(linked, drawn: drawn(rows)))
    }

    static func rendered(_ tables: ShowLink.Tables) -> String {
        OracleRendering.keyed(tables.group) + " | " + OracleRendering.collapse((tables.fronts, tables.hidden))
    }

    init(rows: [Prospect], world: Phase0cWorld) {
        patch = Patch(rows: rows.map { (key: $0.persistentModelID, facts: Self.facts($0)) })
        keyOf = Dictionary(rows.map { ($0.persistentModelID, $0.naturalKey) }, uniquingKeysWith: { first, _ in first })
    }

    mutating func apply(_ changed: Set<PersistentIdentifier>, rows: [Prospect],
                        world: Phase0cWorld) -> (failures: [String], flips: Int) {
        let byID = Dictionary(rows.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
        let before = patch.tables
        let result = patch.apply(changed.map { (key: $0, facts: byID[$0].map(Self.facts)) })
        let after = patch.tables
        // ChangedKeys must name every row whose answer moved, and every hidden flip among them, judged from the
        // tables themselves rather than from the patch's own bookkeeping (L70).
        var failures: [String] = []
        for row in rows {
            let id = row.naturalKey
            let pid = row.persistentModelID
            let was = keyOf[pid] ?? id
            let flipped = before.hidden.contains(was) != after.hidden.contains(id)
            let moved = flipped || before.group[was] != after.group[id] || before.fronts[was] != after.fronts[id]
            if moved && !result.keys.contains(pid) {
                failures.append("ChangedKeys missed a row whose answer moved (\(Phase0b.hash8(id)))")
            }
            if flipped && !result.hiddenFlips.contains(pid) {
                failures.append("ChangedKeys missed a hidden flip (\(Phase0b.hash8(id)))")
            }
        }
        keyOf = Dictionary(rows.map { ($0.persistentModelID, $0.naturalKey) }, uniquingKeysWith: { first, _ in first })
        return (failures, result.hiddenFlips.count)
    }

    func mismatch(rows: [Prospect], world: Phase0cWorld) -> String? {
        let want = Self.oracle(rows)
        let got = Self.rendered(patch.tables)
        return got == want ? nil : "T1 patch \(Phase0b.hash8(got)) oracle \(Phase0b.hash8(want))"
    }

    static func coldMismatch(rows: [Prospect], world: Phase0cWorld) -> String? {
        let cold = Patch(rows: rows.map { (key: $0.persistentModelID, facts: facts($0)) })
        let want = oracle(rows)
        let got = rendered(cold.tables)
        return got == want ? nil : "T1 cold \(Phase0b.hash8(got)) oracle \(Phase0b.hash8(want))"
    }

    static func oracleMovesWithOrder(rows: [Prospect], world: Phase0cWorld) -> Bool {
        oracle(rows) != oracle(Array(rows.reversed()))
    }
}

// MARK: - The whole pass harness

/// The same operations through a real queue engine (the queue's own derivation, a hand run schedule, a pinned clock),
/// its published pass held to the pass over a fresh read with no patch (plan section 4: "only this one can see a
/// hand-off between terms").
@MainActor
enum EnginePropertyHarness {
    typealias Engine = QueueEngine<QueueEnginePass>

    static func engine(_ world: Phase0cWorld, _ turns: EngineTurns) -> Engine {
        QueueEngine(context: world.context, derivation: QueueEngineQueue.derivation(freezeWatch: { nil }),
                    saves: StoreSaveCount(), clock: EngineTestClock().clock,
                    events: QueueEngineSystemEvents(workspace: NotificationCenter(), system: NotificationCenter()),
                    schedule: turns.schedule, refused: { Issue.record("a generation \($1) was refused over \($0)") },
                    verifier: QueueEngineVerifierSetup(triggers: .byHand), launch: QueueEngineLaunchSetup(reads: .inTurn),
                    contextInputs: { EngineHarness.noSignals })
    }

    /// One seed. `ops` is the term's op mix (T1's by default) and `presenters` gives every row a presenter (#4362, T4).
    static func run(size: Int, seed: UInt64, steps: Int, ops: [Phase0cOp] = ShowLinkHarnessTerm.ops,
                    presenters: Bool = false, outcome: inout PatchHarnessOutcome) async throws {
        let world = try Phase0cWorld(size: size, seed: seed, models: AppSchema.models, presenters: presenters)
        let turns = EngineTurns()
        let engine = engine(world, turns)
        var rows = try PatchPropertyHarness.rows(world)
        func requestEveryCard() {
            engine.setViewInputs(QueueEngineViewInputs(focusedStage: nil, focusedKeys: nil,
                                                       requestedCardKeys: Set(rows.map(\.naturalKey))))
        }
        // Before the start, so the first pass builds every card too and the check below compares like with like.
        requestEveryCard()
        engine.start()
        turns.run()
        var hidden = engine.patches.showLink?.tables.hidden ?? []
        var brands = engine.patches.producerTables?.tables.venueBrands
        func check(_ step: Int, _ op: String) throws {
            outcome.checks += 1
            let place = "seed \(seed) size \(size) step \(step) op \(op)"
            let fresh = try FactStore.extractAll(from: ModelContext(world.container))
            guard engine.facts == fresh else {
                outcome.failures.append("\(place): the engine's facts are not the store's, so nothing below was judged")
                return
            }
            guard let output = engine.output else {
                outcome.failures.append("\(place): nothing published")
                return
            }
            // The oracle: the queue's own pass over the fresh read, every term derived over the facts (no patch).
            let oracle = QueueEngineQueue.derive(QueueEnginePassInput(facts: fresh, viewInputs: engine.viewInputs,
                                                                     now: output.now, context: output.context))
            let fields = QueueEngineQueue.differingFields(output.value, oracle)
            if !fields.isEmpty { outcome.failures.append("\(place): the published pass differs in \(fields.sorted())") }
            let terms = engine.patches.mismatches(against: fresh)
            if !terms.isEmpty { outcome.failures.append("\(place): the patched terms differ in \(terms)") }
            let now = engine.patches.showLink?.tables.hidden ?? []
            outcome.handOffs += now.symmetricDifference(hidden).count
            hidden = now
            // #4362: T4's hand-off, the brand verdicts the cards and the ledger read, moved through the engine.
            let nowBrands = engine.patches.producerTables?.tables.venueBrands
            if nowBrands != brands { outcome.handOffs += 1 }
            brands = nowBrands
        }
        try check(-1, "start")
        for step in 0..<steps {
            let op = ops[world.roll(ops.count)]
            guard let edit = world.perform(op, rows: rows, fronts: PatchPropertyHarness.frontsOf(rows)) else {
                outcome.skipped += 1
                continue
            }
            outcome.applied[op, default: 0] += 1
            _ = try world.commit(edit)
            turns.run()
            rows = try PatchPropertyHarness.rows(world)
            try check(step, op.rawValue)
            if op.alwaysUndone || world.roll(2) == 0 {
                _ = try world.undo(edit)
                turns.run()
                rows = try PatchPropertyHarness.rows(world)
                try check(step, op.rawValue + " (undo)")
            }
            requestEveryCard()
        }
        // The engine's own verifier over the same store at the end, which holds the patched terms to their oracle on
        // its own thread and must reach a match.
        let before = engine.verifierCounts
        engine.verifyNow()
        let ended = await waitUntil("the closing verification", timeout: .seconds(60)) {
            engine.verifierCounts.ended > before.ended
        }
        let after = engine.verifierCounts
        if !ended || after.matches != before.matches + 1 {
            outcome.failures.append("seed \(seed) size \(size): the closing verification did not match: \(after)")
        }
    }

    static func runAll(ci: [(size: Int, seeds: Int, steps: Int)], ops: [Phase0cOp] = ShowLinkHarnessTerm.ops,
                       presenters: Bool = false, seedBase: UInt64 = 4360_5000) async throws
        -> (outcome: PatchHarnessOutcome, settings: String, ms: Double) {
        let plan = PatchHarnessSettings.plan(ci: ci)
        var outcome = PatchHarnessOutcome()
        let start = Phase0.now()
        for leg in plan {
            for s in 0..<leg.seeds {
                try await run(size: leg.size, seed: seedBase + UInt64(leg.size * 100 + s), steps: leg.steps, ops: ops,
                              presenters: presenters, outcome: &outcome)
            }
        }
        let settings = (PatchHarnessSettings.deep ? "DEEP " : "CI ")
            + plan.map { "\($0.size) rows x \($0.seeds) seeds x \($0.steps) ops" }.joined(separator: ", ")
        return (outcome, settings, Phase0.ms(since: start))
    }
}

// MARK: - The suite

@MainActor
@Suite("T1 ShowLink patched inside the queue engine equals its oracle (#4360, plan v7 Phase 4b(a))")
struct PatchableShowLinkTests {

    @Test func thePatchEqualsTheCanonicalOracleAfterEveryOperationAndUndo() throws {
        let result = try PatchPropertyHarness.runAll(ShowLinkHarnessTerm.self, ci: [(60, 3, 40), (300, 1, 20)])
        print(result.outcome.report("T1 per term", settings: result.settings, ms: result.ms))
        #expect(result.outcome.failures.isEmpty, "T1: the patched value disagreed with the canonical oracle")
        // Positive controls (L159): the harness compared enough to mean something, and the op mix reached the
        // hand-off into T7's membership at all.
        #expect(result.outcome.checks > 100, "T1: the harness compared too little to mean anything")
        #expect(result.outcome.handOffs > 0, "T1: no hidden state ever flipped, so ChangedKeys' hand-off was never judged")
        #expect(Set(result.outcome.applied.keys) == Set(Phase0cOp.t1),
                "T1: an op in the mix never ran: \(Set(Phase0cOp.t1).subtracting(result.outcome.applied.keys).map(\.rawValue))")
    }

    @Test func theEnginesPublishedPassEqualsThePassWithNoPatchAfterEveryOperation() async throws {
        let result = try await EnginePropertyHarness.runAll(ci: [(60, 2, 25), (300, 1, 10)])
        print(result.outcome.report("whole pass", settings: result.settings, ms: result.ms))
        #expect(result.outcome.failures.isEmpty, "the engine's pass with T1 patched disagreed with the pass without it")
        #expect(result.outcome.checks > 40, "the whole pass harness compared too little to mean anything")
        #expect(result.outcome.handOffs > 0, "no hidden state flipped through the engine, so no hand-off was judged")
    }

    // The patch answers an empty store, a single row and a deletion of the last member as the oracle does: no group,
    // no front, nothing hidden, and nothing left behind under the deleted row's id.
    @Test func aPatchEmptiedByDeletionHoldsNothing() throws {
        let world = try Phase0cWorld(size: 60, seed: 4360_0001)
        let rows = try world.rows()
        typealias Patch = ShowLinkHarnessTerm.Patch
        var patch = Patch(rows: rows.map { (key: $0.persistentModelID, facts: ShowLinkHarnessTerm.facts($0)) })
        #expect(!patch.tables.group.isEmpty && !patch.tables.hidden.isEmpty, "the fixture links nothing, so this proves nothing")
        let changed = patch.apply(rows.map { (key: $0.persistentModelID, facts: nil) })
        #expect(patch.tables == ShowLink.Tables(), "rows deleted from the patch left \(patch.tables.group.count) groups behind")
        #expect(changed.keys == Set(rows.map(\.persistentModelID)), "a deletion was missing from ChangedKeys")
        #expect(Patch(rows: []).tables == ShowLink.Tables())
    }

    // The verifier's comparison (plan v7 D7): a patch the engine kept while the store moved under it is
    // `patchMismatch`, naming the tables that differ, and the facts are compared first.
    @Test func aPatchOutOfStepWithFactsThatAgreeIsAPatchMismatch() throws {
        let world = try Phase0cWorld(size: 60, seed: 4360_0002, models: AppSchema.models)
        var stale = QueueEnginePatches()
        let before = try FactStore.extractAll(from: ModelContext(world.container))
        stale.bringUp(to: before)
        #expect(stale.mismatches(against: before).isEmpty, "a patch built from these facts disagreed with them")
        // A front with a hidden sibling dismissed: the sibling becomes the front and is no longer hidden, so the
        // collapse moves both ways and the grouping does not move at all.
        let rows = try world.rows()
        let collapsed = CanonicalOracle.showLinkCollapse(rows.map(ShowLink.Row.init),
                                                         drawn: ShowLinkHarnessTerm.drawn(rows))
        let front = try #require(rows.first { row in
            collapsed.fronts[row.naturalKey]?.contains { collapsed.hidden.contains($0) } ?? false
        })
        front.statusRaw = ReviewStatus.dismissed.rawValue
        try world.context.save()
        let fresh = try FactStore.extractAll(from: ModelContext(world.container))
        let snapshot = QueueEngineSnapshot(saveCount: 1, generation: 7, facts: fresh,
                                           viewInputs: QueueEngineViewInputs(), context: EngineHarness.noSignals,
                                           now: EngineStore.baseNow, value: EngineDerivations.Counts(), clean: true,
                                           patches: stale)
        let verdict = QueueEngineVerifier.compare(snapshot, with: fresh, derivation: EngineDerivations.counts())
        #expect(verdict == .patchMismatch(fields: ["showLink.fronts", "showLink.hidden"], generation: 7), "\(verdict)")
        // Brought up to the same facts, the same patch agrees, so the verdict was about the patch and nothing else.
        var current = stale
        current.noteChanged(front.persistentModelID)
        current.bringUp(to: fresh)
        #expect(current.mismatches(against: fresh).isEmpty)
        let healed = QueueEngineSnapshot(saveCount: 1, generation: 8, facts: fresh, viewInputs: QueueEngineViewInputs(),
                                         context: EngineHarness.noSignals, now: EngineStore.baseNow,
                                         value: EngineDerivations.Counts(shows: fresh.shows.count), clean: true,
                                         patches: current)
        #expect(QueueEngineVerifier.compare(healed, with: fresh, derivation: EngineDerivations.counts())
                == .match(generation: 8))
    }

    // A resolution reaches the patch at once: a deleted show leaves it before any pass, so no identity a resolution
    // removed is held anywhere in the engine (`EngineIdentityKeyedStateTests` cannot see inside the term).
    @Test func aDeletionResolvedThroughTheEngineLeavesThePatchBeforeAnyPass() throws {
        let world = try Phase0cWorld(size: 60, seed: 4360_0003, models: AppSchema.models)
        var patches = QueueEnginePatches()
        let facts = try FactStore.extractAll(from: ModelContext(world.container))
        patches.bringUp(to: facts)
        let rows = try world.rows()
        let grouped = try #require(rows.first { patches.showLink?.tables.group[$0.naturalKey] != nil })
        var resolution = QueueEngineResolution()
        resolution.deletedIDs = [grouped.persistentModelID]
        resolution.deletedKeys = [grouped.naturalKey]
        var remaining = facts.shows
        remaining[grouped.persistentModelID] = nil
        patches.resolve(resolution, shows: remaining)
        #expect(patches.showLink?.tables.group[grouped.naturalKey] == nil, "the deleted show still has a group")
        #expect(patches.showLink?.tables.group.values.contains { $0.contains(grouped.naturalKey) } == false,
                "the deleted show is still named as another row's sibling")
        #expect(patches.pending.isEmpty)
        var pruned = facts
        pruned.shows = remaining
        #expect(patches.mismatches(against: pruned).isEmpty, "the patch after the resolution is not the oracle's")
    }
}

// MARK: - The cost probe (opt in)

// Plan v7 section 13: T1's per change budget line at 5,376 is 3 ms, and a term whose measured MAX at 5,376 exceeds
// twice that with no fix inside its PR stops the plan. Section 4: the max is taken over EVERY real key of each kind
// (every bucket, every token, every row of the largest buckets, every front, every clustered member), with the median
// and p99 beside it, never the worst of a few chosen changes (L147). Beside it, what T1 costs inside today's pass
// (the premise this PR re-checks: plan section 7 says 567.1 ms over models at 5,376, before the engine existed), and
// the engine's whole pass with and without the patch, alternated so neither arm carries the order effect (#4617).
@MainActor
@Suite("#4360 T1 ShowLink patched: cost per change over the live clone (opt in)", .serialized)
final class PatchableShowLinkCostProbeTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["MEASURE_4360"] != nil }

    static let budgetMs = 3.0
    static var stopMs: Double { 2 * budgetMs }

    typealias Patch = PatchableShowLink<Phase0cKey>

    static func facts(_ row: ShowLink.Row, drawn: Bool) -> Patch.Facts {
        Patch.Facts(id: row.id, title: ShowLink.foldedTitle(row.groupName), venue: ShowLink.foldedVenue(row.venue),
                    nights: ShowLink.nights(of: row), tokens: Set(row.sourceURLs.compactMap(ProductionToken.inURL)),
                    stillInFeed: row.isStillInFeed, opening: row.performanceDate ?? "", drawn: drawn)
    }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func perChangeCostAtOneAndFourTimesTheStore() throws {
        guard Self.enabled else {
            print("patch-4360 cost: not measured. Set TEST_RUNNER_MEASURE_4360=1 to run it.")
            return
        }
        let dir = try sandboxes.make(named: "patch-4360")
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
        print("patch-4360 VERDICT \(verdict): mismatches \(failures.count), max per change at 4x \(maxText) "
              + String(format: "(budget %.0f ms, stop %.0f ms at 5,376)", Self.budgetMs, Self.stopMs))
        if !failures.isEmpty { print("patch-4360 FAILURES\n  " + failures.prefix(30).joined(separator: "\n  ")) }
        #expect(failures.isEmpty, "the patched ShowLink disagreed with the canonical oracle on the clone")
        #expect(maxAt4x != nil, "nothing was timed at 4x")
    }

    private func cost(label: String, url: URL, failures: inout [String]) throws -> Phase0cStats {
        let container = try Phase0.openContainer(at: url)
        let facts = try FactStore.extractAll(from: ModelContext(container))
        let shows = QueueEngineQueue.shows(facts)
        let drawnIDs = Set(QueueModel.queueScope(shows).map(\.naturalKey))
        let load = Phase0.load()

        // What T1 costs inside today's pass: the one call `QueueModel.scope` made over the engine's facts before this
        // PR, and still makes for every caller but the engine.
        let today = Phase0.median5("t1-todayInThePass-\(label)") { _ = ShowLink.tables(among: shows, drawn: drawnIDs) }

        // The engine's whole pass over the same facts, with no patch and with the patch brought up, the first screen's
        // cards requested as the queue requests them. Alternated, so neither arm carries the order effect.
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
        if !fields.isEmpty { failures.append("\(label): the pass with the patch differs from the pass without in \(fields)") }
        let passes = Phase0.alternating([
            (metric: "t1-passNoPatch-\(label)", work: { _ = QueueEngineQueue.derive(plain) }),
            (metric: "t1-passPatched-\(label)", work: { _ = QueueEngineQueue.derive(patched) }),
        ])

        var rows: [Phase0cKey: ShowLink.Row] = [:]
        var drawn: [Phase0cKey: Bool] = [:]
        for show in shows {
            rows[.row(show.persistentModelID)] = ShowLink.Row(show)
            drawn[.row(show.persistentModelID)] = QueueModel.queueScopeHolds(show)
        }
        func slice(_ key: Phase0cKey) -> Patch.Facts? { rows[key].map { Self.facts($0, drawn: drawn[key] ?? true) } }
        var patch = Patch(rows: [])
        let everyRow = rows.keys.compactMap { key in slice(key).map { (key: key, facts: $0) } }
        let cold = Phase0.median5("t1-coldBuild-\(label)") { patch = Patch(rows: everyRow) }

        var mismatches = 0, checks = 0
        func verify(_ what: String) {
            checks += 1
            let current = Array(rows.values)
            let ids = Set(rows.filter { drawn[$0.key] ?? true }.map { $0.value.id })
            let want = OracleRendering.keyed(CanonicalOracle.showLinkGroup(current)) + " | "
                + OracleRendering.collapse(CanonicalOracle.showLinkCollapse(current, drawn: ids))
            let got = ShowLinkHarnessTerm.rendered(patch.tables)
            if want != got {
                mismatches += 1
                failures.append("\(label) \(what): patch \(Phase0b.hash8(got)) oracle \(Phase0b.hash8(want))")
            }
        }
        verify("cold build")

        var lines: [String] = []
        var all = Phase0cStats()
        func timed(_ changes: [(key: Phase0cKey, facts: Patch.Facts?)], into stats: inout Phase0cStats,
                   rebuilt: inout Int) -> Patch.Changed {
            var changed = Patch.Changed()
            stats.add(Phase0.time { changed = patch.apply(changes) })
            rebuilt = max(rebuilt, changed.rowsReevaluated)
            return changed
        }
        func stride(_ n: Int) -> Int { max(1, n / 6) }
        func byID(_ a: Phase0cKey, _ b: Phase0cKey) -> Bool { (rows[a]?.id ?? "") < (rows[b]?.id ?? "") }

        var buckets: [String: [Phase0cKey]] = [:]
        var holders: [String: [Phase0cKey]] = [:]
        for key in rows.keys {
            guard let one = slice(key) else { continue }
            buckets[one.bucket, default: []].append(key)
            for token in one.tokens { holders[token, default: []].append(key) }
        }
        let bucketList = buckets.keys.sorted()
        let sizes = buckets.values.map(\.count).sorted(by: >)
        let tokens = holders.keys.sorted()
        let idToKey = Dictionary(rows.map { ($0.value.id, $0.key) }, uniquingKeysWith: { first, _ in first })

        // A: every bucket rebuilt once (a touch of its first member).
        var touch = Phase0cStats(), touchRows = 0
        for (i, bucket) in bucketList.enumerated() {
            guard let key = buckets[bucket]?.min(by: byID) else { continue }
            _ = timed([(key, slice(key))], into: &touch, rebuilt: &touchRows)
            if i % stride(bucketList.count) == 0 { verify("bucket touch \(i)") }
        }
        lines.append("every bucket rebuilt (\(bucketList.count))            \(touch.text("t1-touch-\(label)")), most rows \(touchRows)")
        all.merge(touch)

        // B: every token: a row planted under another title at a holder's venue (a poison flip), then removed.
        var poisonOn = Phase0cStats(), poisonOff = Phase0cStats(), poisonRows = 0
        for (i, token) in tokens.enumerated() {
            guard let holder = holders[token]?.min(by: byID), let base = rows[holder] else { continue }
            let key = Phase0cKey.probe(i)
            rows[key] = ShowLink.Row(id: "patch-4360-poison-\(i)", groupName: "Patch Probe Invented Bill \(i)",
                                     venue: base.venue, performanceDate: base.performanceDate,
                                     sourceURLs: [Phase0cFixture.url(token)])
            drawn[key] = true
            _ = timed([(key, slice(key))], into: &poisonOn, rebuilt: &poisonRows)
            if i % stride(tokens.count) == 0 { verify("poison on \(i)") }
            rows[key] = nil
            drawn[key] = nil
            _ = timed([(key, nil)], into: &poisonOff, rebuilt: &poisonRows)
        }
        verify("after every poison flip")
        lines.append("poison a token (\(tokens.count))                  \(poisonOn.text("t1-poisonOn-\(label)")), most rows \(poisonRows)")
        lines.append("unpoison it                               \(poisonOff.text("t1-poisonOff-\(label)"))")
        all.merge(poisonOn)
        all.merge(poisonOff)

        // C: every row of the five largest buckets moved out (a scout rename) and back.
        var moveOut = Phase0cStats(), moveBack = Phase0cStats(), moveRows = 0, moved = 0
        let largest = buckets.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        for (_, keys) in largest.prefix(5) {
            for key in keys.sorted(by: byID) {
                guard let original = rows[key] else { continue }
                var out = original
                out.groupName = "Patch Probe Moved Bill \(moved)"
                rows[key] = out
                _ = timed([(key, slice(key))], into: &moveOut, rebuilt: &moveRows)
                if moved % 7 == 0 { verify("move out \(moved)") }
                rows[key] = original
                _ = timed([(key, slice(key))], into: &moveBack, rebuilt: &moveRows)
                moved += 1
            }
        }
        verify("after the largest buckets moved and back")
        lines.append("move out of the 5 largest (\(moved) rows)     \(moveOut.text("t1-moveOut-\(label)")), most rows \(moveRows)")
        lines.append("move back                                 \(moveBack.text("t1-moveBack-\(label)"))")
        all.merge(moveOut)
        all.merge(moveBack)

        // D: every front dismissed (no longer drawn) and restored: the hand-off into T7's membership.
        var dismiss = Phase0cStats(), undismiss = Phase0cStats(), frontRows = 0, flips = 0
        let frontIDs = patch.tables.fronts.keys.sorted()
        for (i, id) in frontIDs.enumerated() {
            guard let key = idToKey[id] else { continue }
            drawn[key] = false
            flips = max(flips, timed([(key, slice(key))], into: &dismiss, rebuilt: &frontRows).hiddenFlips.count)
            if i % stride(frontIDs.count) == 0 { verify("front dismissed \(i)") }
            drawn[key] = true
            _ = timed([(key, slice(key))], into: &undismiss, rebuilt: &frontRows)
        }
        verify("after every front dismissed and back")
        lines.append("front dismissed (\(frontIDs.count))                \(dismiss.text("t1-dismiss-\(label)")), most hidden flips \(flips)")
        lines.append("front undismissed                         \(undismiss.text("t1-undismiss-\(label)"))")
        all.merge(dismiss)
        all.merge(undismiss)

        // E: every clustered member leaves the feed (missedScoutCount 0 to 1) and returns.
        var miss = Phase0cStats(), missRows = 0
        let members = patch.tables.group.keys.sorted()
        for (i, id) in members.enumerated() {
            guard let key = idToKey[id], let original = rows[key] else { continue }
            var out = original
            out.isStillInFeed.toggle()
            rows[key] = out
            _ = timed([(key, slice(key))], into: &miss, rebuilt: &missRows)
            if i % stride(members.count) == 0 { verify("feed miss \(i)") }
            rows[key] = original
            _ = timed([(key, slice(key))], into: &miss, rebuilt: &missRows)
        }
        verify("after every clustered member's feed flip")
        lines.append("feed miss flip and back (\(members.count))         \(miss.text("t1-miss-\(label)"))")
        all.merge(miss)

        let largestText = sizes.prefix(5).map(String.init).joined(separator: ", ")
        print("""
            patch-4360 [\(label)] \(rows.count) rows, \(bucketList.count) buckets (largest \(largestText)), \
            \(members.count) rows in groups, \(patch.tables.hidden.count) hidden, \(tokens.count) distinct tokens, \(load)
              T1 inside today's pass (ShowLink.tables over the facts)   \(today.text)  (plan section 7: 567.1 ms over models at 5,376)
              the engine's pass, no patch (viewport cards)              \(passes[0].text)
              the engine's pass, T1 patched (viewport cards)            \(passes[1].text)
              patched value, cold build                                 \(cold.text)
              \(lines.joined(separator: "\n  "))
              ALL changes                                               \(all.text("t1-all-\(label)"))
              oracle comparisons \(checks), mismatches \(mismatches)
            """)
        return all
    }
}
