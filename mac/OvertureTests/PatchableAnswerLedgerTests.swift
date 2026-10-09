import Foundation
import SwiftData
import Testing

// #4364 (plan v7 Phase 4b(e), discussion #4267 sections 4 and 7 T5): the answer ledger's patched value, proven.
//
// The same three harnesses T1 (#4360) and T4 (#4362) are held to, on T5's op mix (plan section 7: presenter
// respelling within and across org keys, a venue-only edit taking a presenter from one room to two, promote and demote,
// an answer arriving, expiring and replaced at an equal probedAt, a row gaining its own answer, a held key, a refusal
// striking one of two addresses, then the last, then lifted; plus a deletion, an insert and a re-key, and the CLOCK
// moved across an answer's expiry in BOTH directions, L497):
//
// 1. THE PER TERM HARNESS (`PatchPropertyHarness`, `LedgerHarnessTerm`). Seeded operation sequences over the committed
//    synthetic fixtures of 60 and 300 rows with invented presenters, answers and addresses (`Phase0cLedgerFixture`).
//    T4 and T5 are fed from `RowFacts` as the engine feeds them, T5 handed T4's ChangedKeys. After EVERY operation and
//    every undo T5's published answer and its answer per row must equal the canonical oracle
//    (`CanonicalOracle.inheritedAnswers`, `QueueModel.inheritedAnswers` with its inputs in one order) over the store as
//    it stands, at the world's clock and held keys; its indexes must equal their DEFINITIONS (plan v7 correction 2 of
//    2026-09-27, which replaced the dropped email index and its mutation with this check); and ChangedKeys must name
//    exactly the rows whose inherited answer moved.
// 2. THE WHOLE PASS HARNESS (`EnginePropertyHarness` with `ledger: true`): the engine's published pass held to the pass
//    over a fresh read with no patch, with the engine's clock following the world's, so an answer or a refusal the engine
//    took in and never handed T5 (neither changes a show), or a clock move it never brought T5 up to, is seen.
// 3. THE VERIFIER KIND: a T5 out of step with facts that agree is `patchMismatch`, naming `ledger.inherited`.
//
// Failures name seed, step, operation and 8 hex digit hashes, never a name or an address. The cost probe is opt in,
// clones the live store, and prints counts and durations only:
//
//   TEST_RUNNER_MEASURE_4364=1 mac/scripts/run-tests-locked.sh \
//     -only-testing:OvertureTests/PatchableAnswerLedgerCostProbeTests
//
// Deep runs of the two harnesses share T1's switch, TEST_RUNNER_MEASURE_4360_DEEP=1 (20 seeds by 500 operations).

/// T5's synthetic inputs over a fixture's rows: an answer for about three in four organisations, a fifth of them
/// carrying no address, their checks spread over 150 days so about two in five are stale at the fixture's clock; a row
/// in six with its own answer; and a third of the two address answers with one address struck at the organisation.
/// Invented names and addresses only (L155, L222).
enum Phase0cLedgerFixture {
    /// The world's clock at the start, the engine harness's too.
    static let now = EngineStore.baseNow
    static let day: TimeInterval = 86_400

    @MainActor
    static func seed(_ context: ModelContext, seed: UInt64) throws {
        var rng = SeededGenerator(seed: seed &+ 4364)
        func roll(_ n: Int) -> Int { n <= 1 ? 0 : Int(rng.next() % UInt64(n)) }
        let rows = try context.fetch(FetchDescriptor<Prospect>()).sorted { $0.naturalKey < $1.naturalKey }
        let orgKeys = Set(rows.compactMap { OrgKey.stored(for: $0.presenter) }).sorted()
        var serial = 0
        for orgKey in orgKeys where roll(4) != 0 {
            serial += 1
            let answer = Self.answer(orgKey: orgKey, serial: serial, now: now, roll: roll)
            context.insert(answer)
            let emails = answer.foundEmails
            if emails.count == 2, roll(3) == 0, let handle = ContactRefusal.key(for: emails[0]) {
                context.insert(refusal(orgKey: orgKey, handle: handle, at: now))
            }
        }
        for row in rows where roll(6) == 0 { row.reachabilityProbedAt = now.addingTimeInterval(-Double(roll(30)) * day) }
        // Every arm of the rule, whatever the seed rolled (L159): the first two organisations whose producer qualifies
        // and that hold two rows or more get, the first, a fresh two address answer with one row carrying its own answer
        // (which blocks that row only), and the second, a stale answer its other rows would take before its expiry.
        let tables = QueueModel.ProducerTables(rows: rows, overrides: .none)
        var rowsOf: [String: [Prospect]] = [:]
        for row in rows { if let orgKey = OrgKey.stored(for: row.presenter) { rowsOf[orgKey, default: []].append(row) } }
        let qualifying = rowsOf.keys.sorted().filter { orgKey in
            guard let members = rowsOf[orgKey], members.count >= 2, let key = ProducerGate.key(members[0].presenter)
            else { return false }
            return ProducerGate.qualifies(presenterKey: key, in: tables.corpus)
        }
        let answers = try context.fetch(FetchDescriptor<OrgReachabilityAnswer>())
        for (index, orgKey) in qualifying.prefix(2).enumerated() {
            let fresh = index == 0
            let probedAt = now.addingTimeInterval((fresh ? -10 : -120) * day)
            let emails = fresh ? ["first\(index)@invented.test", "second\(index)@invented.test"] : ["only\(index)@invented.test"]
            if let answer = answers.first(where: { $0.orgKey == orgKey }) {
                answer.resultRaw = Reachability.ProbeResult.emailFound.rawValue
                answer.probedAt = probedAt
                answer.foundEmailsRaw = emails.joined(separator: "\n")
            } else {
                context.insert(OrgReachabilityAnswer(orgKey: orgKey, result: .emailFound, probedAt: probedAt,
                                                     sourceNaturalKey: "src-arm-\(index)", sourceGroupName: "Invented Source Bill",
                                                     presenterName: "Invented Asked Name Arm \(index)", foundEmails: emails))
            }
            let members = (rowsOf[orgKey] ?? []).sorted { $0.naturalKey < $1.naturalKey }
            for (i, row) in members.enumerated() {
                row.reachabilityProbedAt = fresh && i == 0 ? now.addingTimeInterval(-day) : nil
            }
        }
    }

    /// One invented answer for `orgKey`, checked up to 150 days before `now`.
    static func answer(orgKey: String, serial: Int, now: Date, roll: (Int) -> Int) -> OrgReachabilityAnswer {
        let kind = roll(10)
        let result: Reachability.ProbeResult = kind < 8 ? .emailFound : (kind == 8 ? .contactFormOnly : .weakContactOnly)
        let emails = result != .emailFound ? []
            : (roll(2) == 0 ? ["desk\(serial)@invented.test"] : ["a\(serial)@invented.test", "b\(serial)@invented.test"])
        let probedAt = now.addingTimeInterval(-Double(roll(150)) * day - Double(roll(86_400)))
        return OrgReachabilityAnswer(orgKey: orgKey, result: result, probedAt: probedAt, sourceNaturalKey: "src-\(serial)",
                                     sourceGroupName: "Invented Source Bill", presenterName: "Invented Asked Name \(serial)",
                                     foundEmails: emails)
    }

    static func refusal(orgKey: String, handle: String, at: Date) -> RefusedContactAddress {
        RefusedContactAddress(
            id: ContactRefusal.rowId(scopeRaw: ContactRefusal.Scope.organisationRaw, scopeId: orgKey, handleKey: handle),
            scopeRaw: ContactRefusal.Scope.organisationRaw, scopeId: orgKey, handleKey: handle, refusedAt: at)
    }
}

/// T5 as the per term harness drives it: T4 and T5 fed from `RowFacts` as the engine feeds them.
@MainActor
struct LedgerHarnessTerm: PatchHarnessTerm {
    typealias Ledger = PatchableAnswerLedger<PersistentIdentifier>
    typealias Producers = PatchableProducerTables<PersistentIdentifier>
    typealias Inherited = OrgAnswerLedger.Inherited
    static let ops = Phase0cOp.t5
    static let models: [any PersistentModel.Type] = [Prospect.self, Recipient.self, PromotedProducer.self,
                                                     DemotedHouse.self, OrgReachabilityAnswer.self,
                                                     RefusedContactAddress.self]

    private var producers: Producers
    private var ledger: Ledger
    /// The answers T5 was last handed, and the oracle's answer and each row's name as of the last apply, for judging
    /// ChangedKeys.
    private var answersHeld: [PersistentIdentifier: OrgAnswerLedger.Answer]
    private var lastOracle: [String: Inherited]
    private var nameOf: [PersistentIdentifier: String]

    static func world(size: Int, seed: UInt64) throws -> Phase0cWorld {
        try Phase0cWorld(size: size, seed: seed, models: models, presenters: true, ledger: true)
    }

    static func facts(_ p: Prospect) -> Ledger.Facts { Ledger.Facts(of: RowFacts.extract(p)) }

    /// Every stored answer flattened as the engine flattens its records (nil for an unreadable result, which T5 reads
    /// as no answer).
    static func flatAnswers(_ world: Phase0cWorld) throws -> [PersistentIdentifier: OrgAnswerLedger.Answer] {
        var out: [PersistentIdentifier: OrgAnswerLedger.Answer] = [:]
        for answer in try world.answers() { out[answer.persistentModelID] = OrgAnswerLedger.Answer(answer) }
        return out
    }

    static func refusalRows(_ world: Phase0cWorld) throws -> Set<ContactRefusal.Ledger.Row> {
        Set(try world.refusals().map {
            ContactRefusal.Ledger.Row(scopeRaw: $0.scopeRaw, scopeId: $0.scopeId, handleKey: $0.handleKey)
        })
    }

    /// The canonical oracle over `rows` and `answers` as given, at the world's clock and held keys.
    static func oracle(rows: [Prospect], answers: [OrgReachabilityAnswer], world: Phase0cWorld) throws -> [String: Inherited] {
        CanonicalOracle.inheritedAnswers(answers, corpus: rows, overrides: try world.overrides(),
                                         refusals: ContactRefusal.ledger(from: try world.refusals()),
                                         heldKeys: world.held, now: world.ledgerNow)
    }

    static func oracle(rows: [Prospect], world: Phase0cWorld) throws -> [String: Inherited] {
        try oracle(rows: rows, answers: try world.answers(), world: world)
    }

    /// Both terms built cold over the world as it stands.
    static func cold(rows: [Prospect], world: Phase0cWorld) throws -> (Producers, Ledger) {
        let producers = Producers(rows: rows.map { (key: $0.persistentModelID, facts: Producers.Facts(of: RowFacts.extract($0))) },
                                  overrides: try world.overrides())
        let ledger = Ledger(rows: rows.map { (key: $0.persistentModelID, facts: facts($0)) },
                            answers: try flatAnswers(world).map { (key: $0.key, answer: Optional($0.value)) },
                            refusals: try refusalRows(world), heldKeys: world.held, now: world.ledgerNow,
                            qualifies: { producers.verdict($0)?.qualifies ?? false })
        return (producers, ledger)
    }

    /// What differs between `ledger` and the oracle over `rows`, by hash and by index name, or nil.
    static func differences(_ ledger: Ledger, rows: [Prospect], world: Phase0cWorld) -> [String] {
        guard let want = try? oracle(rows: rows, world: world), let answers = try? world.answers() else {
            return ["the store could not be read"]
        }
        var found: [String] = []
        if ledger.inherited != want {
            found.append("T5 patch \(Phase0b.hash8(OracleRendering.inherited(ledger.inherited))) "
                         + "oracle \(Phase0b.hash8(OracleRendering.inherited(want)))")
        }
        if let row = rows.first(where: { ledger.inheritedByRow[$0.persistentModelID] != want[$0.naturalKey] }) {
            found.append("the answer by row differs for \(Phase0b.hash8(row.naturalKey))")
        }
        // The indexes against their DEFINITIONS, folded here from the models rather than through `RowKeys` (L70).
        func grouped(_ key: (Prospect) -> String?) -> [String: Set<PersistentIdentifier>] {
            var out: [String: Set<PersistentIdentifier>] = [:]
            for row in rows { if let k = key(row) { out[k, default: []].insert(row.persistentModelID) } }
            return out
        }
        if ledger.rowsByOrgKey != grouped({ OrgKey.stored(for: $0.presenter) }) {
            found.append("the org key index is not its definition")
        }
        if ledger.rowsByProducerKey != grouped({ ProducerGate.key($0.presenter) }) {
            found.append("the producer key index is not its definition")
        }
        var byOrg: [String: Set<PersistentIdentifier>] = [:]
        for answer in answers where answer.result != nil { byOrg[answer.orgKey, default: []].insert(answer.persistentModelID) }
        if ledger.answersByOrgKey != byOrg { found.append("the answer index is not its definition") }
        return found
    }

    init(rows: [Prospect], world: Phase0cWorld) {
        // A read that fails here leaves empty terms, which the first comparison then reports as a mismatch.
        let built = try? Self.cold(rows: rows, world: world)
        producers = built?.0 ?? Producers(rows: [], overrides: .none)
        ledger = built?.1 ?? Ledger(rows: [], answers: [], refusals: [], heldKeys: [], now: world.ledgerNow,
                                    qualifies: { _ in false })
        answersHeld = (try? Self.flatAnswers(world)) ?? [:]
        lastOracle = (try? Self.oracle(rows: rows, world: world)) ?? [:]
        nameOf = Dictionary(rows.map { ($0.persistentModelID, $0.naturalKey) }, uniquingKeysWith: { first, _ in first })
    }

    mutating func apply(_ changed: Set<PersistentIdentifier>, rows: [Prospect],
                        world: Phase0cWorld) -> (failures: [String], flips: Int) {
        guard let overrides = try? world.overrides(), let answers = try? Self.flatAnswers(world),
              let refusals = try? Self.refusalRows(world), let now = try? Self.oracle(rows: rows, world: world) else {
            return (["the store could not be read"], 0)
        }
        let byID = Dictionary(rows.map { ($0.persistentModelID, $0) }, uniquingKeysWith: { first, _ in first })
        let moved = producers.apply(changed.map { (key: $0, facts: byID[$0].map { Producers.Facts(of: RowFacts.extract($0)) }) },
                                    overrides: overrides)
        var answerChanges: [(key: PersistentIdentifier, answer: OrgAnswerLedger.Answer?)] = []
        for id in Set(answersHeld.keys).union(answers.keys) where answersHeld[id] != answers[id] {
            answerChanges.append((key: id, answer: answers[id]))
        }
        answersHeld = answers
        let tables = producers
        let result = ledger.apply(rows: changed.map { (key: $0, facts: byID[$0].map(Self.facts)) }, answers: answerChanges,
                                  refusals: refusals, heldKeys: world.held, now: world.ledgerNow,
                                  verdictsMoved: moved.presenterKeys, qualifies: { tables.verdict($0)?.qualifies ?? false })
        // ChangedKeys must name EXACTLY the rows whose inherited answer moved, judged from the oracle before and after
        // rather than from the patch's own bookkeeping (L70).
        let names = Dictionary(rows.map { ($0.persistentModelID, $0.naturalKey) }, uniquingKeysWith: { first, _ in first })
        var failures: [String] = []
        for id in Set(nameOf.keys).union(names.keys) {
            let before = nameOf[id].flatMap { lastOracle[$0] }
            let after = names[id].flatMap { now[$0] }
            let named = result.rows.contains(id)
            if before != after && !named {
                failures.append("ChangedKeys missed a row whose inherited answer moved (\(Phase0b.hash8(names[id] ?? nameOf[id] ?? "")))")
            }
            if before == after && named {
                failures.append("ChangedKeys named a row whose inherited answer did not move (\(Phase0b.hash8(names[id] ?? nameOf[id] ?? "")))")
            }
        }
        nameOf = names
        lastOracle = now
        return (failures, result.rows.count)
    }

    func mismatch(rows: [Prospect], world: Phase0cWorld) -> String? {
        let found = Self.differences(ledger, rows: rows, world: world)
        return found.isEmpty ? nil : found.prefix(5).joined(separator: "; ")
    }

    static func coldMismatch(rows: [Prospect], world: Phase0cWorld) -> String? {
        guard let built = try? cold(rows: rows, world: world) else { return "the store could not be read" }
        let found = differences(built.1, rows: rows, world: world)
        return found.isEmpty ? nil : "T5 cold build: " + found.prefix(5).joined(separator: "; ")
    }

    static func oracleMovesWithOrder(rows: [Prospect], world: Phase0cWorld) -> Bool {
        guard let answers = try? world.answers(),
              let forward = try? oracle(rows: rows, answers: answers, world: world),
              let reversed = try? oracle(rows: Array(rows.reversed()), answers: Array(answers.reversed()), world: world)
        else { return true }
        return forward != reversed
    }
}

// MARK: - The suite

@MainActor
@Suite("T5 answer ledger patched inside the queue engine equals its oracle (#4364, plan v7 Phase 4b(e))")
struct PatchableAnswerLedgerTests {

    typealias Ledger = LedgerHarnessTerm.Ledger
    typealias Producers = LedgerHarnessTerm.Producers

    @Test func thePatchEqualsTheOracleAndItsIndexesTheirDefinitionsAfterEveryOperationAndUndo() throws {
        let result = try PatchPropertyHarness.runAll(LedgerHarnessTerm.self, ci: [(60, 3, 40), (300, 1, 20)])
        print(result.outcome.report("T5 per term", settings: result.settings, ms: result.ms))
        #expect(result.outcome.failures.isEmpty, "T5: the patched value disagreed with the oracle or its definitions")
        // Positive controls (L159): enough comparisons, an inherited answer that moved, and every op in the mix applied.
        #expect(result.outcome.checks > 100, "T5: the harness compared too little to mean anything")
        #expect(result.outcome.handOffs > 0, "T5: no row's inherited answer ever moved, so ChangedKeys was never judged")
        #expect(Set(result.outcome.applied.keys) == Set(Phase0cOp.t5),
                "T5: an op in the mix never ran: \(Set(Phase0cOp.t5).subtracting(result.outcome.applied.keys).map(\.rawValue))")
    }

    @Test func theEnginesPublishedPassEqualsThePassWithNoPatchAfterEveryOperation() async throws {
        let result = try await EnginePropertyHarness.runAll(ci: [(60, 2, 25), (300, 1, 10)], ops: Phase0cOp.t5,
                                                            presenters: true, ledger: true, seedBase: 4364_5000)
        print(result.outcome.report("T5 whole pass", settings: result.settings, ms: result.ms))
        #expect(result.outcome.failures.isEmpty, "the engine's pass with T5 patched disagreed with the pass without it")
        #expect(result.outcome.checks > 40, "the whole pass harness compared too little to mean anything")
        #expect(result.outcome.handOffs > 0, "no inherited answer moved through the engine, so no hand-off was judged")
    }

    // The fixture reaches every arm of the rule, or the harnesses prove the patch over a store that never asks the hard
    // question (L159): a row that inherits, a candidate the clock has made stale, a row whose own answer blocks an
    // inheritance it would otherwise take, and an address struck at an organisation.
    @Test func theFixtureReachesEveryArmOfTheRule() throws {
        let world = try LedgerHarnessTerm.world(size: 60, seed: 4364_0001)
        let rows = try world.rows()
        let (_, ledger) = try LedgerHarnessTerm.cold(rows: rows, world: world)
        #expect(!ledger.inherited.isEmpty, "no row inherits an answer")
        #expect(ledger.candidates.keys.contains { ledger.usable($0) == nil }, "no organisation's answer is stale")
        #expect(rows.contains { row in
            row.reachabilityProbedAt != nil && OrgKey.stored(for: row.presenter).flatMap { ledger.usable($0) } != nil
        }, "no row with its own answer belongs to an organisation with a usable one")
        #expect(!(try world.refusals()).isEmpty, "no address is struck at an organisation")
    }

    // The clock, both ways (plan section 7 T5 (f), L497): moved past a usable answer's expiry the rows under it stop
    // inheriting, moved back they inherit again, and a stale answer is usable again before its own expiry. Each state
    // held to the oracle at that instant.
    @Test func theClockMovesAnInheritedAnswerOutAndBackIn() throws {
        let world = try LedgerHarnessTerm.world(size: 60, seed: 4364_0002)
        let rows = try world.rows()
        let built = try LedgerHarnessTerm.cold(rows: rows, world: world)
        let producers = built.0
        var ledger = built.1
        let start = world.ledgerNow
        let inherits = try #require(rows.first { ledger.inherited[$0.naturalKey] != nil })
        let orgKey = try #require(OrgKey.stored(for: inherits.presenter))
        let expiry = try #require(ledger.candidates[orgKey]).probedAt.addingTimeInterval(Reachability.probeFreshness)
        func move(to instant: Date) -> Ledger.Changed {
            world.ledgerNow = instant
            return ledger.apply(rows: [], answers: [], refusals: ledger.refusals, heldKeys: ledger.heldKeys, now: instant,
                                verdictsMoved: [], qualifies: { producers.verdict($0)?.qualifies ?? false })
        }
        let forward = move(to: expiry.addingTimeInterval(1))
        #expect(ledger.inherited[inherits.naturalKey] == nil, "the answer outlived its expiry")
        #expect(forward.rows.contains(inherits.persistentModelID))
        #expect(LedgerHarnessTerm.differences(ledger, rows: rows, world: world).isEmpty)
        let back = move(to: start)
        #expect(ledger.inherited[inherits.naturalKey] != nil, "the clock set back did not bring the answer back")
        #expect(back.rows.contains(inherits.persistentModelID))
        #expect(LedgerHarnessTerm.differences(ledger, rows: rows, world: world).isEmpty)
        // A candidate already stale at the start whose rows WOULD take it before its expiry (found by a cold build at
        // that instant): set back to one second before its expiry, they inherit it.
        var revivable: (orgKey: String, instant: Date)?
        for (key, candidate) in ledger.candidates.sorted(by: { $0.key < $1.key }) where ledger.usable(key) == nil {
            let instant = candidate.probedAt.addingTimeInterval(Reachability.probeFreshness - 1)
            world.ledgerNow = instant
            let probe = try LedgerHarnessTerm.cold(rows: rows, world: world).1
            if (probe.rowsByOrgKey[key] ?? []).contains(where: { probe.inheritedByRow[$0] != nil }) {
                revivable = (key, instant)
                break
            }
        }
        world.ledgerNow = start
        let stale = try #require(revivable, "no stale answer has a row that would take it, so the back half proves nothing")
        let revived = move(to: stale.instant)
        #expect(ledger.usable(stale.orgKey) != nil)
        #expect(!revived.rows.isEmpty, "the clock set back before a stale answer's expiry moved no row")
        #expect(LedgerHarnessTerm.differences(ledger, rows: rows, world: world).isEmpty)
    }

    // The engine's own pass READS T5's answers rather than deriving them (L3): handed patches brought up to a store
    // that still held an answer, the pass shows that answer on a card the same pass with no patch does not.
    @Test func theEnginesPassReadsThePatchedLedger() throws {
        let world = try Phase0cWorld(size: 60, seed: 4364_0003, models: AppSchema.models, presenters: true, ledger: true)
        let facts = try FactStore.extractAll(from: ModelContext(world.container))
        var patches = QueueEnginePatches()
        patches.bringUp(to: facts, now: world.ledgerNow)
        let inherited = try #require(patches.ledger?.inherited)
        // A row the queue draws, so its card is built.
        let drawn = facts.shows.values.filter { $0.statusRaw != ReviewStatus.dismissed.rawValue }
        let key = try #require(inherited.keys.sorted().first { key in drawn.contains { $0.naturalKey == key } })
        let orgKey = try #require(drawn.first { $0.naturalKey == key }.flatMap { OrgKey.stored(for: $0.presenter) })
        var without = facts
        for (id, answer) in facts.orgAnswers where answer.orgKey == orgKey { without.orgAnswers[id] = nil }
        let view = QueueEngineViewInputs(focusedStage: nil, focusedKeys: nil,
                                         requestedCardKeys: Set(facts.shows.values.map(\.naturalKey)))
        let plain = QueueEnginePassInput(facts: without, viewInputs: view, now: world.ledgerNow,
                                         context: EngineHarness.noSignals)
        var patched = plain
        patched.patches = patches
        #expect(QueueEngineQueue.derive(plain).builtCards.cards[key]?.inheritedReachability == nil,
                "the pass with no patch still found the answer, so this proves nothing")
        #expect(QueueEngineQueue.derive(patched).builtCards.cards[key]?.inheritedReachability != nil,
                "the engine's pass derived the ledger although it was handed T5's")
    }

    // The verifier's comparison: T5 kept while an answer was deleted under it (which changes no show, so only T5 can
    // be named) is `patchMismatch` naming `ledger.inherited`; brought up to the same facts it agrees.
    @Test func aStaleT5IsAPatchMismatchNamingIt() throws {
        let world = try Phase0cWorld(size: 60, seed: 4364_0004, models: AppSchema.models, presenters: true, ledger: true)
        var stale = QueueEnginePatches()
        let before = try FactStore.extractAll(from: ModelContext(world.container))
        stale.bringUp(to: before, now: world.ledgerNow)
        #expect(stale.mismatches(against: before).isEmpty, "a patch built from these facts disagreed with them")
        let key = try #require(stale.ledger?.inherited.keys.sorted().first)
        let row = try #require(try world.rows().first { $0.naturalKey == key })
        let orgKey = try #require(OrgKey.stored(for: row.presenter))
        for answer in try world.answers() where answer.orgKey == orgKey { world.context.delete(answer) }
        try world.context.save()
        let fresh = try FactStore.extractAll(from: ModelContext(world.container))
        let verdict = QueueEngineVerifier.compare(snapshot(fresh, stale, generation: 7), with: fresh,
                                                  derivation: EngineDerivations.counts())
        #expect(verdict == .patchMismatch(fields: ["ledger.inherited"], generation: 7), "\(verdict)")
        var current = stale
        current.bringUp(to: fresh, now: world.ledgerNow)
        #expect(current.mismatches(against: fresh).isEmpty, "the bring-up did not carry the deleted answer into T5")
        #expect(QueueEngineVerifier.compare(snapshot(fresh, current, generation: 8), with: fresh,
                                            derivation: EngineDerivations.counts()) == .match(generation: 8))
    }

    // A struck address reaches T5 with no show pending: the bring-up compares the refusals, and the verifier names a T5
    // that missed one. Struck down to the last address, the organisation's answer stops being inheritable at all.
    @Test func aRefusalReachesT5WithNoShowPendingAndAStaleOneIsNamed() throws {
        let world = try Phase0cWorld(size: 60, seed: 4364_0005, models: AppSchema.models, presenters: true, ledger: true)
        var patches = QueueEnginePatches()
        let before = try FactStore.extractAll(from: ModelContext(world.container))
        patches.bringUp(to: before, now: world.ledgerNow)
        let stale = patches
        let key = try #require(patches.ledger?.inherited.keys.sorted().first)
        let row = try #require(try world.rows().first { $0.naturalKey == key })
        let orgKey = try #require(OrgKey.stored(for: row.presenter))
        let answer = try #require(try world.answers().first { $0.orgKey == orgKey })
        for email in answer.foundEmails {
            guard let handle = ContactRefusal.key(for: email),
                  !(try world.refusals()).contains(where: { $0.scopeId == orgKey && $0.handleKey == handle }) else { continue }
            world.context.insert(Phase0cLedgerFixture.refusal(orgKey: orgKey, handle: handle, at: world.ledgerNow))
        }
        try world.context.save()
        let fresh = try FactStore.extractAll(from: ModelContext(world.container))
        #expect(stale.mismatches(against: fresh) == ["ledger.inherited"])
        #expect(patches.pending.isEmpty, "a refusal noted a show, so this does not test the refusals route")
        patches.bringUp(to: fresh, now: world.ledgerNow)
        #expect(patches.mismatches(against: fresh).isEmpty, "the bring-up did not carry the refusals into T5")
        #expect(patches.ledger?.inherited[key] == nil, "an organisation with every address struck still lends its answer")
    }

    // A resolution reaches T5 at once: a deleted answer leaves it before any pass.
    @Test func aDeletedAnswerResolvedThroughTheEngineLeavesT5BeforeAnyPass() throws {
        let world = try Phase0cWorld(size: 60, seed: 4364_0006, models: AppSchema.models, presenters: true, ledger: true)
        var patches = QueueEnginePatches()
        let facts = try FactStore.extractAll(from: ModelContext(world.container))
        patches.bringUp(to: facts, now: world.ledgerNow)
        let key = try #require(patches.ledger?.inherited.keys.sorted().first)
        let orgKey = try #require(facts.shows.values.first { $0.naturalKey == key }.flatMap { OrgKey.stored(for: $0.presenter) })
        let id = try #require(facts.orgAnswers.first { $0.value.orgKey == orgKey }?.key)
        var resolution = QueueEngineResolution()
        resolution.deletedIDs = [id]
        var resolved = facts
        resolved.orgAnswers[id] = nil
        patches.resolve(resolution, facts: resolved)
        #expect(patches.ledger?.inherited[key] == nil, "the deleted answer is still lent")
        #expect(patches.mismatches(against: resolved).isEmpty, "T5 after the resolution is not the oracle's")
    }

    // A change to anything T5 does not read (a dismissal) costs it nothing: no org key re-derived, no row re-judged.
    @Test func aChangeToNothingT5ReadsIsNoWork() throws {
        let world = try LedgerHarnessTerm.world(size: 60, seed: 4364_0007)
        let rows = try world.rows()
        var (producers, ledger) = try LedgerHarnessTerm.cold(rows: rows, world: world)
        let row = try #require(rows.first { ledger.inherited[$0.naturalKey] != nil })
        row.statusRaw = ReviewStatus.dismissed.rawValue
        let moved = producers.apply([(key: row.persistentModelID, facts: Producers.Facts(of: RowFacts.extract(row)))],
                                    overrides: try world.overrides())
        let changed = ledger.apply(rows: [(key: row.persistentModelID, facts: LedgerHarnessTerm.facts(row))], answers: [],
                                   refusals: ledger.refusals, heldKeys: ledger.heldKeys, now: ledger.now,
                                   verdictsMoved: moved.presenterKeys, qualifies: { producers.verdict($0)?.qualifies ?? false })
        #expect(changed == Ledger.Changed())
    }

    private func snapshot(_ facts: FactStore, _ patches: QueueEnginePatches,
                          generation: Int) -> QueueEngineSnapshot<EngineDerivations.Counts> {
        QueueEngineSnapshot(saveCount: 1, generation: generation, facts: facts, viewInputs: QueueEngineViewInputs(),
                            context: EngineHarness.noSignals, now: Phase0cLedgerFixture.now,
                            // The counts as the derivation makes them over these facts: this store has answers and
                            // refusals, so a value counting only the shows would be an output mismatch of its own.
                            value: EngineDerivations.counts().derive(QueueEnginePassInput(
                                facts: facts, viewInputs: QueueEngineViewInputs(), now: Phase0cLedgerFixture.now,
                                context: EngineHarness.noSignals)),
                            clean: true, patches: patches)
    }
}

// MARK: - The cost probe (opt in)

// Plan v7 section 13: T5's per change budget line at 5,376 is 2 ms, and a term whose measured MAX at 5,376 exceeds twice
// that with no fix inside its PR stops the plan. Section 7: "one orgKey group, under 2 ms for the largest organisation".
// The max is over EVERY real key of each kind, with p99 and median beside it (L147): every presenter respelled to
// another organisation's presenter and back, every answer deleted and restored, every answer replaced at an equal
// probedAt and back, every row gaining its own answer and back, every address of every answer struck at its
// organisation and lifted, the clock moved across every candidate's expiry and back, and every presenter key promoted
// and put back (T4's ChangedKeys handed to T5; only T5's apply is timed). Beside it the cold arm (the patch built from
// nothing against today's derivation inside the pass) and the engine's whole pass with and without the patches,
// alternated (#4617).
@MainActor
@Suite("#4364 T5 answer ledger patched: cost per change over the live clone (opt in)", .serialized)
final class PatchableAnswerLedgerCostProbeTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["MEASURE_4364"] != nil }

    static let budgetMs = 2.0
    static var stopMs: Double { 2 * budgetMs }

    typealias Ledger = PatchableAnswerLedger<PersistentIdentifier>
    typealias Producers = PatchableProducerTables<PersistentIdentifier>

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func perChangeCostAtOneAndFourTimesTheStore() throws {
        guard Self.enabled else {
            print("patch-4364 cost: not measured. Set TEST_RUNNER_MEASURE_4364=1 to run it.")
            return
        }
        let dir = try sandboxes.make(named: "patch-4364")
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
        print("patch-4364 VERDICT \(verdict): mismatches \(failures.count), max per change at 4x \(maxText) "
              + String(format: "(budget %.0f ms, stop %.0f ms at 5,376)", Self.budgetMs, Self.stopMs))
        if !failures.isEmpty { print("patch-4364 FAILURES\n  " + failures.prefix(30).joined(separator: "\n  ")) }
        #expect(failures.isEmpty, "the patched ledger disagreed with the oracle on the clone")
        #expect(maxAt4x != nil, "nothing was timed at 4x")
    }

    private func cost(label: String, url: URL, failures: inout [String]) throws -> Phase0cStats {
        let container = try Phase0.openContainer(at: url)
        let facts = try FactStore.extractAll(from: ModelContext(container))
        let shows = QueueEngineQueue.shows(facts)
        let overrides = facts.producerOverrides
        let refusals = facts.refusalRows
        let answerRecords = Array(facts.orgAnswers.values)
        let now = Date()
        let load = Phase0.load()

        // The cold arm: today's derivation inside the pass (the producer corpus handed in, as `scope` hands it) against
        // the patch built from nothing, alternated.
        var producers = Producers(rows: shows.map { (key: $0.persistentModelID, facts: Producers.Facts(of: $0)) },
                                  overrides: overrides)
        let corpus = producers.tables.corpus
        let rows = shows.map { (key: $0.persistentModelID, facts: Ledger.Facts(of: $0)) }
        let flat = facts.orgAnswers.map { (key: $0.key, answer: OrgAnswerLedger.Answer($0.value)) }
        let tables = producers
        var ledger = Ledger(rows: [], answers: [], refusals: [], heldKeys: [], now: now, qualifies: { _ in false })
        let coldArms = Phase0.alternating([
            (metric: "t5-todayInThePass-\(label)", work: {
                _ = QueueModel.inheritedAnswers(answerRecords, corpus: shows, overrides: overrides,
                                                refusals: facts.refusalLedger, heldKeys: [], now: now,
                                                producerCorpus: corpus)
            }),
            (metric: "t5-patchCold-\(label)", work: {
                ledger = Ledger(rows: rows, answers: flat, refusals: refusals, heldKeys: [], now: now,
                                qualifies: { tables.verdict($0)?.qualifies ?? false })
            }),
        ])

        // The engine's whole pass over the same facts, with no patch and with every patch brought up, the first screen's
        // cards requested as the queue requests them. Alternated.
        var patches = QueueEnginePatches()
        patches.bringUp(to: facts, now: now)
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
            (metric: "t5-passNoPatch-\(label)", work: { _ = QueueEngineQueue.derive(plain) }),
            (metric: "t5-passPatched-\(label)", work: { _ = QueueEngineQueue.derive(patched) }),
        ])

        // The world the oracle is asked about, kept beside the patch as each change is made.
        var world = Dictionary(uniqueKeysWithValues: shows.map { ($0.persistentModelID, $0) })
        var answers = facts.orgAnswers
        var struck = refusals
        var clock = now
        var mismatches = 0, checks = 0
        func verify(_ what: String) {
            checks += 1
            let ledgerRows = struck.sorted { ($0.scopeRaw, $0.scopeId, $0.handleKey) < ($1.scopeRaw, $1.scopeId, $1.handleKey) }
            let oracle = QueueModel.inheritedAnswers(Array(answers.values), corpus: Array(world.values),
                                                     overrides: producers.overrides,
                                                     refusals: ContactRefusal.Ledger(rows: ledgerRows),
                                                     heldKeys: [], now: clock)
            if ledger.inherited != oracle {
                mismatches += 1
                failures.append("\(label) \(what): the patch differs from the oracle")
            }
        }
        verify("cold build")

        func apply(rows: [(key: PersistentIdentifier, facts: Ledger.Facts?)] = [],
                   answers changes: [(key: PersistentIdentifier, answer: OrgAnswerLedger.Answer?)] = [],
                   verdictsMoved: Set<String> = []) -> (ms: Double, work: Int) {
            var changed = Ledger.Changed()
            let tables = producers
            let ms = Phase0.time {
                changed = ledger.apply(rows: rows, answers: changes, refusals: struck, heldKeys: [], now: clock,
                                       verdictsMoved: verdictsMoved, qualifies: { tables.verdict($0)?.qualifies ?? false })
            }
            return (ms, changed.rowsRejudged)
        }
        var kinds: [Phase0cKind] = []
        let candidates = ledger.candidates.keys.sorted()

        // Every presenter respelled ACROSS org keys: a row of each organisation with a candidate takes another
        // organisation's presenter, and back.
        let byOrg = ledger.rowsByOrgKey
        let donor = shows.first { $0.presenter != nil }
        let across = Phase0cKind("every organisation with an answer: a row's presenter respelled to another's, and back")
        for orgKey in candidates {
            guard let id = byOrg[orgKey]?.min(), let row = world[id], let other = donor, other.presenter != row.presenter
            else { continue }
            let old = Ledger.Facts(of: row)
            let moved = Ledger.Facts(naturalKey: old.naturalKey, orgKey: other.foldedKeys.orgKey,
                                     presenterKey: other.foldedKeys.presenterKey, hasOwnAnswer: old.hasOwnAnswer)
            across.sample {
                let a = apply(rows: [(id, moved)])
                let b = apply(rows: [(id, old)])
                return (a.ms, a.work, b.ms, b.work)
            }
        }
        kinds.append(across)
        verify("after every presenter moved and came back")

        // Every answer deleted and restored (an answer leaving and arriving).
        let arrive = Phase0cKind("every answer deleted, and arriving again")
        for (id, record) in facts.orgAnswers.sorted(by: { $0.key < $1.key }) {
            let answer = OrgAnswerLedger.Answer(record)
            arrive.sample {
                answers[id] = nil
                let a = apply(answers: [(id, nil)])
                answers[id] = record
                let b = apply(answers: [(id, answer)])
                return (a.ms, a.work, b.ms, b.work)
            }
        }
        kinds.append(arrive)

        // Every answer replaced at an equal probedAt (another name and one address), and back.
        let replaced = Phase0cKind("every answer replaced at an equal probedAt, and back")
        for (id, record) in facts.orgAnswers.sorted(by: { $0.key < $1.key }) {
            guard let answer = OrgAnswerLedger.Answer(record) else { continue }
            let other = OrgAnswerLedger.Answer(orgKey: answer.orgKey, result: .emailFound, probedAt: answer.probedAt,
                                               presenterName: "Invented Asked Name", emails: ["desk@invented.test"])
            replaced.sample {
                let a = apply(answers: [(id, other)])
                let b = apply(answers: [(id, answer)])
                return (a.ms, a.work, b.ms, b.work)
            }
        }
        kinds.append(replaced)
        verify("after every answer was replaced and put back")

        // Every row gaining its own answer (or losing it), and back.
        let own = Phase0cKind("every row under an organisation with an answer: its own answer toggled, and back")
        for orgKey in candidates {
            for id in (byOrg[orgKey] ?? []).sorted() {
                guard let row = world[id] else { continue }
                let old = Ledger.Facts(of: row)
                var toggled = old
                toggled.hasOwnAnswer.toggle()
                own.sample {
                    let a = apply(rows: [(id, toggled)])
                    let b = apply(rows: [(id, old)])
                    return (a.ms, a.work, b.ms, b.work)
                }
            }
        }
        kinds.append(own)

        // Every address of every answer struck at its organisation, and lifted.
        let strike = Phase0cKind("every address of every answer struck at its organisation, and lifted")
        for record in answerRecords.sorted(by: { $0.orgKey < $1.orgKey }) {
            for email in record.foundEmails {
                guard let handle = ContactRefusal.key(for: email) else { continue }
                let row = ContactRefusal.Ledger.Row(scopeRaw: ContactRefusal.Scope.organisationRaw, scopeId: record.orgKey,
                                                    handleKey: handle)
                guard !struck.contains(row) else { continue }
                strike.sample {
                    struck.insert(row)
                    let a = apply()
                    struck.remove(row)
                    let b = apply()
                    return (a.ms, a.work, b.ms, b.work)
                }
            }
        }
        kinds.append(strike)
        verify("after every strike was lifted")

        // The clock moved across every candidate's expiry, in the direction that crosses it, and back.
        let expiries = Phase0cKind("the clock across every candidate's expiry, and back")
        for orgKey in candidates {
            guard let candidate = ledger.candidates[orgKey] else { continue }
            let expiry = candidate.probedAt.addingTimeInterval(Reachability.probeFreshness)
            let across = expiry > now ? expiry.addingTimeInterval(1) : expiry.addingTimeInterval(-1)
            expiries.sample {
                clock = across
                let a = apply()
                clock = now
                let b = apply()
                return (a.ms, a.work, b.ms, b.work)
            }
        }
        kinds.append(expiries)
        verify("after the clock came back")

        // Every presenter key promoted (or put back), T4 brought up untimed and its ChangedKeys handed to T5, timed.
        let promote = Phase0cKind("every presenter key promoted and put back, T5's share")
        for presenterKey in ledger.rowsByProducerKey.keys.sorted() {
            var next = overrides
            if next.promoted.contains(presenterKey) { next.promoted.remove(presenterKey) } else {
                next.promoted.insert(presenterKey)
                next.demoted.remove(presenterKey)
            }
            promote.sample {
                let movedIn = producers.apply([], overrides: next).presenterKeys
                let a = apply(verdictsMoved: movedIn)
                let movedOut = producers.apply([], overrides: overrides).presenterKeys
                let b = apply(verdictsMoved: movedOut)
                return (a.ms, a.work, b.ms, b.work)
            }
        }
        kinds.append(promote)
        verify("end")

        var all = Phase0cStats()
        var lines: [String] = []
        for kind in kinds {
            for ms in kind.doTimes + kind.undoTimes { all.add(ms) }
            lines += kind.lines(workLabel: "rows re-judged", metric: "t5-\(label)")
        }
        let today = coldArms[0], cold = coldArms[1]
        let groups = byOrg.values.map(\.count)
        let fanOut = ledger.rowsByProducerKey.values.map(\.count)
        print("""
            patch-4364 [\(label)] \(shows.count) shows, \(facts.orgAnswers.count) answers, \(candidates.count) candidates, \
            \(byOrg.count) org keys (largest group \(groups.max() ?? 0) rows), \(ledger.rowsByProducerKey.count) producer keys \
            (largest \(fanOut.max() ?? 0) rows), \(refusals.count) struck, \(load)
              T5 inside today's pass (inheritedAnswers over the facts)      \(today.text)  (#4623: 26.3 ms optimised at 4x)
              patched value, cold build                                     \(cold.text), ratio \(String(format: "%.2f", cold.median / max(today.median, 0.001)))
              the engine's pass, no patch (viewport cards)                  \(passes[0].text)
              the engine's pass, T1, T4 and T5 patched (viewport cards)     \(passes[1].text)
              \(lines.joined(separator: "\n  "))
              ALL changes                                                   \(all.text("t5-all-\(label)"))
              oracle comparisons \(checks), mismatches \(mismatches)
            """)
        return all
    }
}
