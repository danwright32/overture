import Foundation
import SwiftData
import Testing

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
// E4) gives the engine that derivation.
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

    var needsInquiries: Bool { [.inquiryInsert, .inquiryEdit, .inquiryDelete].contains(self) }
    var needsSmallTables: Bool { [.smallTableInsert, .smallTableEdit, .smallTableDelete].contains(self) }
}

@Suite("The queue engine's change-kind equality matrix at 1, 60 and 300 rows (#4358)")
@MainActor
final class QueueEngineChangeKindMatrixTests {

    static let sizes = [1, 60, 300]
    static let seed: UInt64 = 4358

    typealias Engine = QueueEngine<EngineDerivations.Counts>

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
        let store = try EngineStore(shows: total + 40, inquiries: kind.needsInquiries ? total + 10 : 5,
                                    smallRows: kind.needsSmallTables ? total + 10 : 3, seed: Self.seed)
        // Every show carries a contact, so a contact kind at 300 has 300 to touch.
        for show in try store.shows() where show.recipients.isEmpty {
            show.setRecipients([Recipient(id: "\(show.naturalKey)-only@example.org",
                                          email: "\(show.naturalKey)-only@example.org", provenance: .act)])
        }
        try store.context.save()
        let turns = EngineTurns()
        let saves = StoreSaveCount()
        let engine = EngineHarness.engine(store, EngineDerivations.counts(), turns: turns, saves: saves)
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
            let fresh = try store.freshFacts()
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

    /// Which tables differ, by name and count only (L222).
    static func differing(_ a: FactStore, _ b: FactStore) -> String {
        let (changed, gone) = a.differences(to: b)
        return "\(changed) rows differ, \(gone.count) held and not in the read"
    }

    private func pick<T>(_ items: [T], _ count: Int, rng: inout SeededGenerator) -> [T] {
        Array(items.shuffled(using: &rng).prefix(count))
    }

    /// Applies `kind` to `rows` rows, runs the passes it causes, and returns how many derivations the gate
    /// should have taken.
    private func apply(_ kind: EngineChangeKind, rows n: Int, store: EngineStore, engine: Engine, turns: EngineTurns,
                       touched: inout Set<PersistentIdentifier>, rng: inout SeededGenerator) async throws -> Int {
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
            await waitUntil("the foreign save asked for a pass") { !turns.queued.isEmpty }
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
