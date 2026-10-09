import Foundation
import SwiftData
import Testing

// #4363 (plan v7 Phase 4b(d), discussion #4267 section 7 T7 and T10): the queue's per show entries, patched, proven.
//
// Four harnesses, one per thing that can be wrong, and a cost probe:
//
// 1. THE PER TERM HARNESS. Seeded operation sequences from T7's op mix (`Phase0cRowsFixture.Kind`: every stage move,
//    sentAt, reprep, a reply, the clock across a send timeout, a stall timeout, midnight, an opening night and the
//    lead-time edge, the reply run flag, a geography refusal, presenter respelling, inquiry edits, a collapsed front
//    dismissed, an organisation refusal, recipient flags, an insert, a date move, a producer correction, a draft edit)
//    over the committed synthetic stores of 60 and 300 rows (invented names, L155, L222). After EVERY operation and
//    every undo the product value (`PatchableRowEntries`, fed `RowFacts` as the engine feeds it) must equal today's
//    whole-store functions over the store as it stands (`mismatches(against:inquiries:)`, the verifier's comparison),
//    and at sampled steps a cold build must too. Its named mutation: skip subtracting an entry's old contribution.
// 2. THE CLOCK ARM (T10). One value carried forward through 50 instants that cross every kind of deadline the op mix
//    holds (20 of DueWork's next moments in a row, each bracketed a second either side, midnights, send timeouts, owed
//    moments), rebuilding only the entries whose `validUntil` passed, equal to the oracle at every one. Its named
//    mutation: `TimeProbe` drops a recorded boundary. Beside it, the context reads: a field's change rebuilds exactly
//    the entries that consulted it.
// 3. THE WHOLE PASS HARNESS. The same op mix through a real queue engine (the store's own small tables, its clock and
//    its signals): after each operation the engine's published pass must equal the pass over a FRESH read with no
//    patch, field by field. Only this one sees the joins the pass makes onto an entry (the inherited answer, the
//    collapse); its named mutation drops the inherited join, which leaves the per term harness green.
// 4. THE VERIFIER KIND. T7 out of step with facts that agree is `patchMismatch`, naming `rowEntries.<table>`.
//
// Every failure names seed, step and operation, never a title or a venue. The cost probe is opt in, clones the live
// store, and prints counts and durations only:
//
//   TEST_RUNNER_MEASURE_4363=1 mac/scripts/run-tests-locked.sh -only-testing:OvertureTests/PatchableRowEntriesCostProbeTests
//
// Deep runs of harnesses 1 and 3 are opt in by TEST_RUNNER_MEASURE_4363_DEEP=1, sized to hold the shared test lock
// for about 20 minutes, and their output goes in the PR.

enum RowEntriesHarnessSettings {
    nonisolated static var deep: Bool { ProcessInfo.processInfo.environment["MEASURE_4363_DEEP"] != nil }

    static func plan(ci: [(size: Int, seeds: Int, steps: Int)], deep deepPlan: [(size: Int, seeds: Int, steps: Int)])
        -> [(size: Int, seeds: Int, steps: Int)] {
        deep ? deepPlan : ci
    }

    static func text(_ plan: [(size: Int, seeds: Int, steps: Int)]) -> String {
        (deep ? "DEEP " : "CI ") + plan.map { "\($0.size) rows x \($0.seeds) seeds x \($0.steps) ops" }
            .joined(separator: ", ")
    }
}

/// What one harness run did, kept apart so a green run that compared nothing reads as nothing (L98).
struct RowEntriesHarnessOutcome {
    var checks = 0
    var coldChecks = 0
    var skipped = 0
    var applied: [Phase0cRowsFixture.Kind: Int] = [:]
    var failures: [String] = []
    /// Entries rebuilt, and entries left standing, over every bring-up: the patch did patch (L159).
    var rebuilt = 0
    var carried = 0

    func report(_ name: String, settings: String, ms: Double) -> String {
        let ops = applied.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value)" }
        return """
            patch-4363 \(name) [\(settings)] \(String(format: "%.1f", ms / 1000)) s: \(checks) oracle comparisons, \
            \(coldChecks) cold builds held to the oracle, \(skipped) ops skipped, entries rebuilt \(rebuilt), \
            left standing \(carried), mismatches \(failures.count)
              ops applied: \(ops.joined(separator: "; "))
            """ + (failures.isEmpty ? "" : "\n  FAILURES\n  " + failures.prefix(30).joined(separator: "\n  "))
    }
}

@MainActor
enum RowEntriesHarness {
    /// The fixture's shows as the engine holds them.
    static func shows(_ fx: Phase0cRowsFixture) -> [PersistentIdentifier: RowFacts] {
        Dictionary(fx.rows.map { ($0.persistentModelID, RowFacts.extract($0)) }, uniquingKeysWith: { first, _ in first })
    }

    static func context(_ fx: Phase0cRowsFixture) -> RowEntryContext {
        RowEntryContext(geo: fx.geo, clients: .none, replyRunAlive: fx.replyRunAlive)
    }

    static func inquiries(_ fx: Phase0cRowsFixture) -> [InquiryRecord] { fx.inquiries.map(InquiryRecord.init(copying:)) }

    /// The patch's disagreements with the oracle, and a cold build's, by table name.
    static func mismatches(_ patch: PatchableRowEntries, _ fx: Phase0cRowsFixture) -> [String] {
        patch.mismatches(against: shows(fx), inquiries: inquiries(fx))
    }

    /// One seed: the fixture, the value built cold, then `steps` operations, checked after each and after each undo.
    static func run(size: Int, seed: UInt64, steps: Int, outcome: inout RowEntriesHarnessOutcome) throws {
        let fx = try Phase0cRowsFixture(size: size, seed: seed)
        var patch = PatchableRowEntries(shows: shows(fx), context: context(fx), now: fx.now)
        let sampled = Set((0..<5).map { steps * $0 / 5 })
        func check(_ step: Int, _ op: String) {
            outcome.checks += 1
            let found = mismatches(patch, fx)
            if !found.isEmpty { outcome.failures.append("seed \(seed) size \(size) step \(step) op \(op): \(found)") }
        }
        func feed(_ changed: Set<PersistentIdentifier>) {
            let total = fx.rows.count
            let rebuilt = patch.bringUp(changed: changed, shows: shows(fx), now: fx.now, context: context(fx))
            outcome.rebuilt += rebuilt
            outcome.carried += max(0, total - rebuilt)
        }
        check(0, "cold build")
        for step in 1...steps {
            // Every kind once, in order, first, so each is exercised whatever the seed draws; then at random.
            let every = Phase0cRowsFixture.Kind.allCases
            let kind = step <= every.count ? every[step - 1] : fx.pickKind()
            guard let op = try fx.perform(kind) else {
                outcome.skipped += 1
                continue
            }
            outcome.applied[kind, default: 0] += 1
            feed(op.changed)
            check(step, op.label)
            if fx.coin(0.4) {
                feed(try op.undo())
                check(step, op.label + " (undo)")
            }
            if sampled.contains(step) {
                outcome.coldChecks += 1
                let cold = PatchableRowEntries(shows: shows(fx), context: context(fx), now: fx.now)
                let found = mismatches(cold, fx)
                if !found.isEmpty {
                    outcome.failures.append("seed \(seed) size \(size) step \(step): the cold build \(found)")
                }
            }
            if outcome.failures.count >= 10 { break }
        }
    }

    static func runAll(ci: [(size: Int, seeds: Int, steps: Int)], deep: [(size: Int, seeds: Int, steps: Int)]) throws
        -> (outcome: RowEntriesHarnessOutcome, settings: String, ms: Double) {
        let plan = RowEntriesHarnessSettings.plan(ci: ci, deep: deep)
        var outcome = RowEntriesHarnessOutcome()
        let start = Phase0.now()
        for leg in plan {
            for s in 0..<leg.seeds {
                try run(size: leg.size, seed: 4363_0000 + UInt64(leg.size * 100 + s), steps: leg.steps,
                        outcome: &outcome)
            }
        }
        return (outcome, RowEntriesHarnessSettings.text(plan), Phase0.ms(since: start))
    }

    /// The instants the clock arm crosses, chosen from the ORACLE's own answers rather than from the patch's recorded
    /// deadlines, so a deadline the patch failed to record is still crossed (L70): twenty of `DueWork.nextChange`'s
    /// moments in a row, each a second either side; every contact's owed moment and send timeout ahead of `start`, a
    /// second either side; and four Eastern midnights. Ascending, at most `limit`.
    static func instants(_ fx: Phase0cRowsFixture, from start: Date, limit: Int = 50) -> [Date] {
        let all = Array(shows(fx).values)
        let theirs: (RowFacts) -> [RecipientRecord] = { $0.factContacts }
        var out: Set<Date> = []
        var t = start
        for _ in 0..<20 {
            guard let next = DueWork.nextChange(from: all, contacts: theirs, now: t, replyRunAlive: fx.replyRunAlive)
            else { break }
            out.insert(next.addingTimeInterval(-1))
            out.insert(next.addingTimeInterval(1))
            t = next.addingTimeInterval(1)
        }
        var owed: [Date] = []
        for p in all where QueueModel.queueScopeHolds(p) {
            let show = ReachedOutQueue.Show(p, contacts: p.factContacts)
            for r in p.factContacts {
                if let m = ReachedOutQueue.nextActionableMoment(for: r, of: show, now: start), m > start { owed.append(m) }
                if r.sendState == .sending, let claimed = r.sendClaimedAt {
                    owed.append(claimed.addingTimeInterval(RunTimeouts.send))
                }
            }
        }
        for m in owed.sorted().prefix(4) {
            out.insert(m.addingTimeInterval(-1))
            out.insert(m.addingTimeInterval(1))
        }
        var midnight = start
        for _ in 0..<4 {
            midnight = TimeProbe.nextEasternMidnight(after: midnight)
            out.insert(midnight.addingTimeInterval(1))
        }
        return Array(out.filter { $0 > start }.sorted().prefix(limit))
    }
}

// MARK: - The whole pass harness

/// The signals the harness's engine reads, held where the closure it hands the engine can see the latest.
@MainActor
final class RowEntriesSignals {
    var inputs = QueueEngineContextInputs(clients: .none)
}

/// T7's op mix through a real queue engine, its published pass held to the pass over a fresh read with no patch.
@MainActor
enum RowEntriesEngineHarness {
    /// The fixture's own values that live outside the store (the clock, the reply run's flag, the geography and
    /// organisation refusals, the producer corrections) written into the store's tables and the engine's inputs,
    /// then saved, as the app writes them.
    static func mirror(_ fx: Phase0cRowsFixture, signals: RowEntriesSignals, clock: EngineTestClock) throws {
        let ctx = fx.context
        let towns = try ctx.fetch(FetchDescriptor<ExcludedTown>())
        if Set(towns.map(\.town)) != fx.excludedTowns {
            towns.forEach(ctx.delete)
            for town in fx.excludedTowns.sorted() { ctx.insert(ExcludedTown(town: town, addedAt: fx.now)) }
        }
        func rowText(_ r: ContactRefusal.Ledger.Row) -> String { "\(r.scopeRaw)|\(r.scopeId)|\(r.handleKey)" }
        let refused = try ctx.fetch(FetchDescriptor<RefusedContactAddress>())
        if Set(refused.map { "\($0.scopeRaw)|\($0.scopeId)|\($0.handleKey)" }) != Set(fx.refusalRows.map(rowText)) {
            refused.forEach(ctx.delete)
            for (i, r) in fx.refusalRows.enumerated() {
                ctx.insert(RefusedContactAddress(id: "refusal-4363-\(i)-\(r.handleKey)", scopeRaw: r.scopeRaw,
                                                 scopeId: r.scopeId, handleKey: r.handleKey, refusedAt: fx.now))
            }
        }
        let promoted = try ctx.fetch(FetchDescriptor<PromotedProducer>())
        if Set(promoted.map(\.orgKey)) != fx.overrides.promoted {
            promoted.forEach(ctx.delete)
            for key in fx.overrides.promoted.sorted() { ctx.insert(PromotedProducer(orgKey: key, addedAt: fx.now)) }
        }
        let demoted = try ctx.fetch(FetchDescriptor<DemotedHouse>())
        if Set(demoted.map(\.orgKey)) != fx.overrides.demoted {
            demoted.forEach(ctx.delete)
            for key in fx.overrides.demoted.sorted() { ctx.insert(DemotedHouse(orgKey: key, addedAt: fx.now)) }
        }
        try ctx.save()
        signals.inputs = QueueEngineContextInputs(clients: .none, replyRunAlive: fx.replyRunAlive)
        let delta = fx.now.timeIntervalSince(clock.now)
        if delta != 0 { clock.advance(by: delta) }
    }

    static func run(size: Int, seed: UInt64, steps: Int, outcome: inout RowEntriesHarnessOutcome) async throws {
        let fx = try Phase0cRowsFixture(size: size, seed: seed, models: AppSchema.models)
        // The organisation answers the fixture keeps beside its store, written into it, so the pass inherits them.
        for answer in fx.answers { fx.context.insert(answer) }
        try fx.context.save()
        let turns = EngineTurns()
        let clock = EngineTestClock(fx.now)
        let signals = RowEntriesSignals()
        let engine = QueueEngine(context: fx.context, derivation: QueueEngineQueue.derivation(freezeWatch: { nil }),
                                 saves: StoreSaveCount(), clock: clock.clock,
                                 events: QueueEngineSystemEvents(workspace: NotificationCenter(),
                                                                 system: NotificationCenter()),
                                 schedule: turns.schedule,
                                 refused: { Issue.record("a generation \($1) was refused over \($0)") },
                                 verifier: QueueEngineVerifierSetup(triggers: .byHand),
                                 launch: QueueEngineLaunchSetup(reads: .inTurn), contextInputs: { signals.inputs })
        func requestEveryCard() {
            engine.setViewInputs(QueueEngineViewInputs(focusedStage: nil, focusedKeys: nil,
                                                       requestedCardKeys: Set(fx.rows.map(\.naturalKey))))
        }
        requestEveryCard()
        engine.start()
        turns.run()
        func settle() throws {
            try mirror(fx, signals: signals, clock: clock)
            // A pass at the clock's instant whatever the operation was, so a move of the clock or a signal alone is
            // a pass too, as the floor and the signals make one in the app.
            engine.sourceFired("rowEntriesHarness")
            turns.run()
        }
        func check(_ step: Int, _ op: String) throws {
            outcome.checks += 1
            let place = "seed \(seed) size \(size) step \(step) op \(op)"
            let fresh = try FactStore.extractAll(from: ModelContext(fx.container))
            guard engine.facts == fresh else {
                outcome.failures.append("\(place): the engine's facts are not the store's, so nothing below was judged")
                return
            }
            guard let output = engine.output, output.now == clock.now else {
                outcome.failures.append("\(place): no pass was published at the clock's instant")
                return
            }
            guard let entries = engine.patches.rowEntries, entries.now == clock.now else {
                outcome.failures.append("\(place): T7 was not brought up to the pass's instant, so it served nothing")
                return
            }
            outcome.rebuilt += entries.lastRebuilt
            outcome.carried += max(0, entries.entries.count - entries.lastRebuilt)
            let oracle = QueueEngineQueue.derive(QueueEnginePassInput(facts: fresh, viewInputs: engine.viewInputs,
                                                                     now: output.now, context: output.context))
            let fields = QueueEngineQueue.differingFields(output.value, oracle)
            if !fields.isEmpty { outcome.failures.append("\(place): the published pass differs in \(fields.sorted())") }
            let terms = engine.patches.mismatches(against: fresh)
            if !terms.isEmpty { outcome.failures.append("\(place): the patched terms differ in \(terms)") }
        }
        try check(-1, "start")
        for step in 1...steps {
            let every = Phase0cRowsFixture.Kind.allCases
            let kind = step <= every.count ? every[step - 1] : fx.pickKind()
            guard let op = try fx.perform(kind) else {
                outcome.skipped += 1
                continue
            }
            outcome.applied[kind, default: 0] += 1
            try settle()
            try check(step, op.label)
            if fx.coin(0.4) {
                _ = try op.undo()
                try settle()
                try check(step, op.label + " (undo)")
            }
            requestEveryCard()
            if outcome.failures.count >= 10 { break }
        }
        // The engine's own verifier over the same store at the end, which holds T7 to its oracle on its own thread.
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

    static func runAll(ci: [(size: Int, seeds: Int, steps: Int)], deep: [(size: Int, seeds: Int, steps: Int)])
        async throws -> (outcome: RowEntriesHarnessOutcome, settings: String, ms: Double) {
        let plan = RowEntriesHarnessSettings.plan(ci: ci, deep: deep)
        var outcome = RowEntriesHarnessOutcome()
        let start = Phase0.now()
        for leg in plan {
            for s in 0..<leg.seeds {
                try await run(size: leg.size, seed: 4363_5000 + UInt64(leg.size * 100 + s), steps: leg.steps,
                              outcome: &outcome)
            }
        }
        return (outcome, RowEntriesHarnessSettings.text(plan), Phase0.ms(since: start))
    }
}

// MARK: - The suite

@MainActor
@Suite("T7 per show entries patched inside the queue engine equal their oracles (#4363, plan v7 Phase 4b(d))")
struct PatchableRowEntriesTests {

    @Test func theEntriesEqualTheirOraclesAfterEveryOperationAndUndo() throws {
        let result = try RowEntriesHarness.runAll(ci: [(60, 3, 40), (300, 1, 25)],
                                                  deep: [(60, 20, 300), (300, 4, 150)])
        print(result.outcome.report("T7 per term", settings: result.settings, ms: result.ms))
        #expect(result.outcome.failures.isEmpty, "T7: the patched entries disagreed with today's whole-store terms")
        // Positive controls (L159): enough was compared to mean something, every op kind ran, and the value really
        // patched (left most entries standing) rather than rebuilding everything on every change.
        #expect(result.outcome.checks > 100, "T7: the harness compared too little to mean anything")
        #expect(result.outcome.coldChecks > 0)
        #expect(Set(result.outcome.applied.keys) == Set(Phase0cRowsFixture.Kind.allCases),
                "T7: an op never ran: \(Set(Phase0cRowsFixture.Kind.allCases).subtracting(result.outcome.applied.keys).map(\.rawValue))")
        // Three to one, not more: the op mix moves the clock across midnight, which rightly rebuilds every show the
        // scope holds (about 85% of these fixtures), and that is most of what gets rebuilt (measured 2026-10-09: 1,822
        // rebuilt against 16,637 left standing).
        #expect(result.outcome.carried > 3 * result.outcome.rebuilt,
                "T7: \(result.outcome.rebuilt) entries rebuilt against \(result.outcome.carried) left standing")
    }

    @Test func theEnginesPublishedPassEqualsThePassWithNoPatchAfterEveryOperation() async throws {
        let result = try await RowEntriesEngineHarness.runAll(ci: [(60, 2, 25), (300, 1, 10)],
                                                              deep: [(60, 10, 150), (300, 2, 60)])
        print(result.outcome.report("whole pass", settings: result.settings, ms: result.ms))
        #expect(result.outcome.failures.isEmpty, "the engine's pass with T7 patched disagreed with the pass without it")
        #expect(result.outcome.checks > 40, "the whole pass harness compared too little to mean anything")
        #expect(result.outcome.carried > 0, "the engine rebuilt every entry on every pass, so T7 patched nothing")
    }

    // T10's clock arm: one value carried forward through 50 instants on `validUntil` alone, equal to the oracle at every
    // one, and the carrying is real (most instants rebuild few entries) while every deadline kind is crossed.
    @Test func anEntryLeftStandingUntilItsValidUntilAnswersAsTheOracleDoesAtFiftyInstants() throws {
        let fx = try Phase0cRowsFixture(size: 300, seed: 4363_0101)
        let start = fx.now
        var patch = PatchableRowEntries(shows: RowEntriesHarness.shows(fx), context: RowEntriesHarness.context(fx),
                                        now: start)
        let instants = RowEntriesHarness.instants(fx, from: start)
        #expect(instants.count >= 40, "the fixture offered only \(instants.count) instants, so the arm proves little")
        var failures: [String] = []
        var rebuiltPer: [Int] = []
        for (i, t) in instants.enumerated() {
            fx.now = t
            rebuiltPer.append(patch.bringUp(changed: [], shows: RowEntriesHarness.shows(fx), now: t,
                                            context: RowEntriesHarness.context(fx)))
            let found = RowEntriesHarness.mismatches(patch, fx)
            if !found.isEmpty { failures.append("instant \(i) (+\(Int(t.timeIntervalSince(start))) s): \(found)") }
        }
        print("patch-4363 clock arm: \(instants.count) instants, entries rebuilt per instant \(rebuiltPer), "
              + "mismatches \(failures.count)")
        #expect(failures.isEmpty, "an entry left standing on its validUntil disagreed with the oracle:\n\(failures.joined(separator: "\n"))")
        #expect(rebuiltPer.contains(0), "every instant rebuilt something, so no entry was ever carried")
        #expect(rebuiltPer.contains { $0 > 0 }, "no instant rebuilt anything, so no deadline was ever crossed")
        #expect((rebuiltPer.max() ?? 0) < fx.rows.count, "some instant rebuilt every entry")
    }

    // Who reads the day (#4291's tail: midnight rebuilt every row): a dismissed show nobody was pitched reads no clock
    // and no context at all, so neither midnight nor any signal ever rebuilds it, while a show the scope holds does.
    @Test func aDismissedShowWithNoContactReadsNoClockAndNoContext() throws {
        let fx = try Phase0cRowsFixture(size: 300, seed: 4363_0102)
        let patch = PatchableRowEntries(shows: RowEntriesHarness.shows(fx), context: RowEntriesHarness.context(fx),
                                        now: fx.now)
        let quiet = fx.rows.filter { $0.statusRaw == ReviewStatus.dismissed.rawValue && $0.recipients.isEmpty }
        let held = fx.rows.filter { $0.statusRaw != ReviewStatus.dismissed.rawValue }
        #expect(!quiet.isEmpty && !held.isEmpty, "the fixture holds no show of one kind, so this proves nothing")
        for p in quiet {
            let entry = try #require(patch.entries[p.persistentModelID])
            #expect(entry.validUntil == nil && entry.consulted.isEmpty, "a dismissed show with no contact read a clock or a field")
        }
        for p in held {
            let entry = try #require(patch.entries[p.persistentModelID])
            #expect(entry.validUntil != nil, "a show the scope holds read no clock, though its stages read the day")
            #expect(entry.consulted.isSuperset(of: [.geo, .clients]), "a show the scope holds did not record its stages' reads")
        }
    }

    // T10's context reads: a field's change rebuilds exactly the entries that consulted it, and nothing else.
    @Test func aContextFieldsChangeRebuildsExactlyTheEntriesThatConsultedIt() throws {
        let fx = try Phase0cRowsFixture(size: 300, seed: 4363_0103)
        var patch = PatchableRowEntries(shows: RowEntriesHarness.shows(fx), context: RowEntriesHarness.context(fx),
                                        now: fx.now)
        let shows = RowEntriesHarness.shows(fx)
        func bring() -> Int {
            patch.bringUp(changed: [], shows: RowEntriesHarness.shows(fx), now: fx.now,
                          context: RowEntriesHarness.context(fx))
        }
        // An entry that reads the clock continuously (a reply with no arrival instant is dated at `now`) is rebuilt on
        // every bring-up however little changed; every other entry only when something it read moved.
        let continuous = Set(patch.entries.filter { $0.value.validUntil == $0.value.builtAt }.keys)
        #expect(bring() == continuous.count, "nothing changed and an entry that reads no moving clock was rebuilt")
        // The reply run's flag: only shows with a reply draft asked for read it.
        let asking = Set(shows.filter { $0.value.factContacts.contains { $0.awaitedReplyDraftRequestedAt != nil } }.keys)
        #expect(!asking.isEmpty, "no show in the fixture asked for a reply draft")
        fx.replyRunAlive.toggle()
        #expect(bring() == asking.union(continuous).count)
        #expect(RowEntriesHarness.mismatches(patch, fx).isEmpty)
        // A geography refusal: every show the scope holds reads it, through its stages.
        let held = Set(shows.filter { QueueModel.queueScopeHolds($0.value) }.keys)
        fx.excludedTowns = [Phase0cRowsFixture.refusableTown]
        #expect(bring() == held.union(continuous).count)
        #expect(RowEntriesHarness.mismatches(patch, fx).isEmpty)
    }

    // The verifier's comparison (plan v7 D7): T7 left at facts the store has since moved past is `patchMismatch`,
    // naming the tables that differ, and the same value brought up agrees.
    @Test func aRowEntriesValueOutOfStepWithFactsThatAgreeIsAPatchMismatch() throws {
        let world = try Phase0cWorld(size: 60, seed: 4363_0002, models: AppSchema.models)
        var stale = QueueEnginePatches()
        let before = try FactStore.extractAll(from: ModelContext(world.container))
        stale.bringUp(to: before, now: EngineStore.baseNow, context: EngineHarness.noSignals)
        #expect(stale.mismatches(against: before).isEmpty, "a value built from these facts disagreed with them")
        // A drawn show moved from approved to drafted, which moves its stages and the pills and nothing ShowLink reads.
        let row = try #require(try world.rows().first { $0.status == .approved })
        row.status = .drafted
        try world.context.save()
        let fresh = try FactStore.extractAll(from: ModelContext(world.container))
        let snapshot = QueueEngineSnapshot(saveCount: 1, generation: 9, facts: fresh,
                                           viewInputs: QueueEngineViewInputs(), context: EngineHarness.noSignals,
                                           now: EngineStore.baseNow, value: EngineDerivations.Counts(), clean: true,
                                           patches: stale)
        let verdict = QueueEngineVerifier.compare(snapshot, with: fresh, derivation: EngineDerivations.counts())
        guard case .patchMismatch(let fields, let generation) = verdict else {
            Issue.record("expected a patchMismatch, got \(verdict)")
            return
        }
        #expect(generation == 9)
        #expect(fields.contains("rowEntries.rows") && fields.contains("rowEntries.focuses"), "\(fields)")
        #expect(!fields.contains { $0.hasPrefix("showLink.") }, "a status move inside the scope moved ShowLink: \(fields)")
        var current = stale
        current.noteChanged(row.persistentModelID)
        current.bringUp(to: fresh.shows)
        #expect(current.mismatches(against: fresh).isEmpty, "brought up to the same facts, T7 still disagreed")
    }
}

// MARK: - The cost probe (opt in)

// Plan v7 section 13: per-row entries and affected cards share a per change budget line of 5 ms at 5,376, and a term
// whose measured MAX at 5,376 exceeds twice that with no fix inside its PR stops the plan. Section 4: the max is over
// EVERY real key of its kind, here every show (a change rebuilds its one entry), with p99 and median beside it. Beside
// it, what T7 costs inside today's pass (#4623 measured 91.5 ms optimised at 4x plus 13.6 for DueWork), the cold build,
// the bulk kinds (midnight, the reply run's flag, a geography refusal), and the engine's pass with and without the
// patch, alternated so neither arm carries the order effect (#4617).
@MainActor
@Suite("#4363 T7 per show entries patched: cost per change over the live clone (opt in)", .serialized)
final class PatchableRowEntriesCostProbeTests {
    private let sandboxes = TemporarySandboxes()

    nonisolated static var enabled: Bool { ProcessInfo.processInfo.environment["MEASURE_4363"] != nil }

    static let budgetMs = 5.0
    static var stopMs: Double { 2 * budgetMs }

    @Test(.enabled(if: Phase0.liveStoreExists, "no live store on this machine"))
    func perChangeCostAtOneAndFourTimesTheStore() throws {
        guard Self.enabled else {
            print("patch-4363 cost: not measured. Set TEST_RUNNER_MEASURE_4363=1 to run it.")
            return
        }
        let dir = try sandboxes.make(named: "patch-4363")
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
        print("patch-4363 VERDICT \(verdict): mismatches \(failures.count), max per change at 4x \(maxText) "
              + String(format: "(budget %.0f ms, stop %.0f ms at 5,376)", Self.budgetMs, Self.stopMs))
        if !failures.isEmpty { print("patch-4363 FAILURES\n  " + failures.prefix(30).joined(separator: "\n  ")) }
        #expect(failures.isEmpty, "the patched entries disagreed with today's terms on the clone")
        #expect(maxAt4x != nil, "nothing was timed at 4x")
    }

    private func cost(label: String, url: URL, failures: inout [String]) throws -> Phase0cStats {
        let container = try Phase0.openContainer(at: url)
        let facts = try FactStore.extractAll(from: ModelContext(container))
        let shows = QueueEngineQueue.shows(facts)
        let inquiries = Array(facts.inquiries.values)
        let load = Phase0.load()
        let now = Date()
        let signals = EngineHarness.noSignals
        let context = RowEntryContext(facts: facts, signals: signals)
        let theirs: (RowFacts) -> [RecipientRecord] = { $0.factContacts }

        // What T7 costs inside today's pass over the engine's facts: the row loop's rows, the placement, the Reached out
        // list, the pills, the organisation counts and the next due moment, each over every show as the pass asks them.
        let inScope = QueueModel.queueScope(shows)
        let stage = StageContext(now: now, geo: context.geo, clients: context.clients).resolvingPlaces(of: inScope)
        let today = Phase0.median5("t7-todayInThePass-\(label)") {
            _ = inScope.map { QueueScopeRow($0, facts: RecipientFacts.of($0, contacts: $0.factContacts)) }
            let placement = StageNavigation.placements(of: inScope, contacts: theirs, context: stage)
            let reached = ReachedOutQueue.activeWithDates(from: inScope, contacts: theirs, now: now)
            _ = AgentInputs.from(prospects: inScope, allProspects: shows, contacts: theirs, inquiries: inquiries,
                                 context: stage, gmailConnected: false, runInFlight: nil, replyRunAlive: false,
                                 placement: placement, reachedOut: reached)
            _ = QueueModel.organisationRowCounts(among: shows)
            _ = DueWork.nextChange(from: shows, contacts: theirs, now: now, replyRunAlive: false)
        }

        var patch = PatchableRowEntries(shows: [:], context: context, now: now)
        let cold = Phase0.median5("t7-coldBuild-\(label)") {
            patch = PatchableRowEntries(shows: facts.shows, context: context, now: now)
        }
        var checks = 0
        func verify(_ what: String) {
            checks += 1
            let found = patch.mismatches(against: facts.shows, inquiries: inquiries)
            if !found.isEmpty { failures.append("\(label) \(what): \(found)") }
        }
        verify("cold build")

        // The engine's whole pass over the same facts, with no patch and with every patch brought up, the first screen's
        // cards requested as the queue requests them. Alternated, so neither arm carries the order effect.
        var patches = QueueEnginePatches()
        patches.bringUp(to: facts, now: now, context: signals)
        let firstView = QueueEngineViewInputs(focusedStage: .scout, focusedKeys: nil, requestedCardKeys: [])
        let probeView = QueueEngineQueue.derive(QueueEnginePassInput(facts: facts, viewInputs: firstView, now: now,
                                                                     context: signals))
        let viewport = Set(probeView.data.focusedRows.prefix(QueueViewportAssumption.rows).map(\.id))
        let view = QueueEngineViewInputs(focusedStage: .scout, focusedKeys: nil, requestedCardKeys: viewport)
        let plain = QueueEnginePassInput(facts: facts, viewInputs: view, now: now, context: signals)
        let patched = QueueEnginePassInput(facts: facts, viewInputs: view, now: now, context: signals, patches: patches)
        let fields = QueueEngineQueue.differingFields(QueueEngineQueue.derive(plain), QueueEngineQueue.derive(patched))
        if !fields.isEmpty { failures.append("\(label): the pass with the patches differs from the pass without in \(fields)") }
        let passes = Phase0.alternating([
            (metric: "t7-passNoPatch-\(label)", work: { _ = QueueEngineQueue.derive(plain) }),
            (metric: "t7-passPatched-\(label)", work: { _ = QueueEngineQueue.derive(patched) }),
        ])

        // Every show changed once (its entry rebuilt): every real key of the kind.
        var all = Phase0cStats()
        let ids = facts.shows.keys.sorted()
        for (i, id) in ids.enumerated() {
            all.add(Phase0.time { patch.bringUp(changed: [id], shows: facts.shows, now: now, context: context) })
            if i % max(1, ids.count / 4) == 0 { verify("row change \(i)") }
        }
        verify("after every row changed")
        // The bulk kinds, each once, then back.
        let midnight = TimeProbe.nextEasternMidnight(after: now).addingTimeInterval(1)
        var rebuiltAtMidnight = 0
        let rollover = Phase0.time {
            rebuiltAtMidnight = patch.bringUp(changed: [], shows: facts.shows, now: midnight, context: context)
        }
        verify("after midnight")
        var flipped = context
        flipped.replyRunAlive.toggle()
        var rebuiltOnFlag = 0
        let flag = Phase0.time {
            rebuiltOnFlag = patch.bringUp(changed: [], shows: facts.shows, now: midnight, context: flipped)
        }
        var refused = flipped
        refused.geo = GeoRefusals(userExcludedTowns: context.geo.userExcludedTowns.union(["patch-4363-probe-town"]),
                                  allowedSeedTowns: context.geo.allowedSeedTowns)
        var rebuiltOnGeo = 0
        let geo = Phase0.time {
            rebuiltOnGeo = patch.bringUp(changed: [], shows: facts.shows, now: midnight, context: refused)
        }
        print("""
            patch-4363 [\(label)] \(shows.count) shows, \(inScope.count) in the queue's scope, \(load)
              T7 inside today's pass (the per show terms over the facts)   \(today.text)  (#4623: 91.5 ms optimised at 4x, plus 13.6 for DueWork)
              the engine's pass, no patch (viewport cards)                 \(passes[0].text)
              the engine's pass, T1 and T7 patched (viewport cards)        \(passes[1].text)
              patched value, cold build                                    \(cold.text)
              a show changed, every show                                   \(all.text("t7-rowChange-\(label)"))
              midnight rollover                                            \(String(format: "%.1f ms", rollover)), \(rebuiltAtMidnight) entries rebuilt
              reply run flag flipped                                       \(String(format: "%.1f ms", flag)), \(rebuiltOnFlag) entries rebuilt
              a geography refusal added                                    \(String(format: "%.1f ms", geo)), \(rebuiltOnGeo) entries rebuilt
              oracle comparisons \(checks), mismatches \(failures.count)
            """)
        return all
    }
}
