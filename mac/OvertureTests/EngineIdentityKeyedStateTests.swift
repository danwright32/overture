import Foundation
import SwiftData
import Testing

// #4358 (plan v2 Phase 4 step 1, the resolve step over a DERIVED list, L96, L38).
//
// The resolve step purges and re-keys exactly the structures `QueueEngine.identityKeyedState` names. A list
// written by hand would check only what somebody remembered to write down, so this walks what the engine
// really holds, by Mirror, and fails on any dictionary, set or array keyed by a `PersistentIdentifier` or a
// `String` that the list does not name, and on any line in the list that names nothing. Seen to fail by adding
// an unregistered `[PersistentIdentifier: Int]` to the engine.
//
// Then one test per delete kind (a show and its contacts, a lone contact, an inquiry, a small table row): after
// the delete is saved and the pass has run, every identity-keyed structure the walk finds is free of the
// deleted identities and natural keys, and the facts equal a fresh read of the store. The walk, not the list,
// decides where to look, so a structure the list forgot is searched too (L70).
@Suite("Every identity keyed structure in the queue engine is resolved (#4358)")
@MainActor
struct EngineIdentityKeyedStateTests {

    typealias Engine = QueueEngine<EngineDerivations.Counts>

    private func started(_ store: EngineStore, _ turns: EngineTurns) -> Engine {
        let engine = EngineHarness.engine(store, EngineDerivations.counts(), turns: turns)
        engine.start()
        turns.run()
        return engine
    }

    /// The registry's paths that cover a whole subtree rather than one structure.
    private var wholeSubtrees: Set<String> {
        Set(Engine.identityKeyedState.compactMap { entry in
            if case .replacedAtEveryPublish = entry.disposition { return entry.path }
            return nil
        })
    }

    @Test func everyIdentityKeyedStructureIsRegisteredAndNothingElseIs() throws {
        let store = try EngineStore(shows: 3, seed: 1)
        let turns = EngineTurns()
        let engine = started(store, turns)
        let (leaves, paths) = EngineIdentityWalk.walk(engine, stoppingAt: wholeSubtrees)
        let registered = Set(Engine.identityKeyedState.map(\.path))
        // The positive control: the walk reaches the facts, so an empty finding is a reading, not a blind walk.
        #expect(leaves.contains { $0.path == "facts.shows" } && leaves.count > 10,
                "the walk found \(leaves.count) structures, so it did not reach the engine's state")
        let unregistered = leaves.map(\.path).filter { !registered.contains($0) }.sorted()
        #expect(unregistered.isEmpty, """
                these structures are keyed by identity and the resolve step does not know them, so a deleted or \
                re-keyed row would stay in them: \(unregistered.joined(separator: ", ")). Register each in \
                QueueEngine.identityKeyedState with what the resolve step does to it.
                """)
        let stale = registered.subtracting(paths).sorted()
        #expect(stale.isEmpty, "identityKeyedState names structures the engine does not hold: \(stale.joined(separator: ", "))")
        #expect(Set(Engine.identityKeyedState.map(\.path)).count == Engine.identityKeyedState.count,
                "a structure is registered twice")
    }

    // The detector itself, on shapes it must catch and must leave alone.
    @Test func theDetectorTellsIdentityKeyedShapesFromOthers() {
        let id: [PersistentIdentifier: Int] = [:]
        let keys: Set<String> = []
        let names: [String]? = []
        #expect(EngineIdentityWalk.isIdentityKeyed(id))
        #expect(EngineIdentityWalk.isIdentityKeyed(keys))
        #expect(EngineIdentityWalk.isIdentityKeyed(names as Any))
        #expect(!EngineIdentityWalk.isIdentityKeyed([1, 2]))
        #expect(!EngineIdentityWalk.isIdentityKeyed([QueueEnginePassReason.first: 1]))
    }

    /// Every identity and natural key the engine still holds anywhere the walk reaches.
    private func held(by engine: Engine) -> (ids: Set<PersistentIdentifier>, strings: Set<String>) {
        var ids: Set<PersistentIdentifier> = []
        var strings: Set<String> = []
        for leaf in EngineIdentityWalk.walk(engine, stoppingAt: wholeSubtrees).leaves {
            let found = EngineIdentityWalk.contents(of: leaf.value)
            ids.formUnion(found.ids)
            strings.formUnion(found.strings)
        }
        return (ids, strings)
    }

    /// Runs `delete`, saves, runs the pass, and asserts nothing the engine holds names `ids` or `keys`.
    private func expectGone(_ ids: Set<PersistentIdentifier>, keys: Set<String>, store: EngineStore, turns: EngineTurns,
                            engine: Engine, _ delete: () -> Void) throws {
        let before = held(by: engine)
        // The positive control: the engine held every one of them before the delete, so absence afterwards is
        // the resolve step's doing and not a structure that never had them (L159).
        #expect(ids.isSubset(of: before.ids), "the engine did not hold the rows before they were deleted")
        #expect(keys.isSubset(of: before.strings), "the engine did not hold the keys before they were deleted")
        delete()
        try store.context.save()
        turns.run()
        let after = held(by: engine)
        let leftIDs = ids.intersection(after.ids)
        let leftKeys = keys.intersection(after.strings)
        #expect(leftIDs.isEmpty, "\(leftIDs.count) deleted identities are still held after the resolve step")
        #expect(leftKeys.isEmpty, "\(leftKeys.count) deleted natural keys are still held after the resolve step")
        #expect(try engine.facts == store.freshFacts(), "the facts differ from a fresh read after the delete")
    }

    @Test func aShowDeletedWithItsContactsLeavesNothingBehind() throws {
        let store = try EngineStore(shows: 6, seed: 2)
        let show = store.addShow(contacts: 2)
        try store.context.save()
        let turns = EngineTurns()
        let engine = started(store, turns)
        engine.setViewInputs(QueueEngineViewInputs(focusedKeys: [show.naturalKey], requestedCardKeys: [show.naturalKey]))
        turns.run()
        let ids = Set([show.persistentModelID] + show.recipients.map(\.persistentModelID))
        try expectGone(ids, keys: [show.naturalKey], store: store, turns: turns, engine: engine) {
            store.context.delete(show)
        }
    }

    @Test func aContactDeletedOnItsOwnLeavesNothingBehind() throws {
        let store = try EngineStore(shows: 6, seed: 3)
        let show = store.addShow(contacts: 2)
        try store.context.save()
        let turns = EngineTurns()
        let engine = started(store, turns)
        let contact = try #require(show.recipients.first)
        try expectGone([contact.persistentModelID], keys: [], store: store, turns: turns, engine: engine) {
            store.context.delete(contact)
        }
    }

    @Test func anInquiryDeletedLeavesNothingBehind() throws {
        let store = try EngineStore(shows: 2, inquiries: 3, seed: 4)
        let turns = EngineTurns()
        let engine = started(store, turns)
        let inquiry = try #require(try store.context.fetch(FetchDescriptor<Inquiry>()).first)
        try expectGone([inquiry.persistentModelID], keys: [], store: store, turns: turns, engine: engine) {
            store.context.delete(inquiry)
        }
    }

    @Test func aSmallTableRowDeletedLeavesNothingBehind() throws {
        let store = try EngineStore(shows: 2, smallRows: 2, seed: 5)
        let turns = EngineTurns()
        let engine = started(store, turns)
        let answer = try #require(try store.context.fetch(FetchDescriptor<OrgReachabilityAnswer>()).first)
        let town = try #require(try store.context.fetch(FetchDescriptor<ExcludedTown>()).first)
        try expectGone([answer.persistentModelID, town.persistentModelID], keys: [], store: store, turns: turns,
                       engine: engine) {
            store.context.delete(answer)
            store.context.delete(town)
        }
    }
}

// The engine knows a row has never been saved by its identifier carrying no store identifier. Pinned here,
// with a saved row as the positive control, because the re-key rests on it.
@Suite("A temporary identifier carries no store identifier (#4358)")
@MainActor
struct EngineTemporaryIdentifierTests {
    @Test func onlyAnUnsavedRowLacksAStoreIdentifier() throws {
        let store = try EngineStore(shows: 1, seed: 6)
        let saved = try #require(try store.shows().first)
        let fresh = store.addShow()
        #expect(saved.persistentModelID.storeIdentifier != nil, "a saved row carries no store identifier")
        #expect(fresh.persistentModelID.storeIdentifier == nil, "an unsaved row already carries a store identifier")
        let temporary = fresh.persistentModelID
        try store.context.save()
        #expect(fresh.persistentModelID != temporary && fresh.persistentModelID.storeIdentifier != nil)
    }
}
