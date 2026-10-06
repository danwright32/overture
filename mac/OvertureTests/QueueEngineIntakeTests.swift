import Foundation
import SwiftData
import Testing

// #4358 (plan v7 D2, decision 3): every way a change reaches the queue engine, each asserting the engine's facts
// against a fresh read of the store through a context of its own, never against the engine's own records (L70).
//
// Trackers see an edit the moment it is made, saved or not; `didSave` sees a write no tracker was armed for. Each
// test below is one shape of change, and several pin what #4106 probe 2 measured about SwiftData, so an SDK that
// changes it turns a test red rather than silently breaking intake.
@Suite("How a change reaches the queue engine (#4358)")
@MainActor
final class QueueEngineIntakeTests {

    typealias Engine = QueueEngine<EngineDerivations.Counts>

    private func started(_ store: EngineStore, _ turns: EngineTurns,
                         saves: StoreSaveCount = StoreSaveCount()) -> Engine {
        let engine = EngineHarness.engine(store, EngineDerivations.counts(), turns: turns, saves: saves)
        engine.start()
        turns.run()
        return engine
    }

    @Test func anUnsavedEditIsTakenInByItsTrackerAndTheSaveChangesNothingMore() throws {
        let store = try EngineStore(shows: 4, seed: 11)
        let turns = EngineTurns()
        let engine = started(store, turns)
        let show = try #require(try store.shows().first)
        let passes = engine.counters.passes
        show.fitReason = "edited, not saved"
        #expect(turns.queued.count == 1, "the edit's tracker did not ask for a pass")
        turns.run()
        #expect(engine.facts.shows[show.persistentModelID]?.fitReason == "edited, not saved")
        #expect(engine.counters.passes == passes + 1)
        try store.context.save()
        turns.run()
        // The save names the row, which reads the same as the tracker already took in: no second derivation.
        #expect(engine.counters.passes == passes + 1, "the save of an edit already taken in derived again")
        #expect(try engine.facts == store.freshFacts())
    }

    // Probe 2 measured that an equal-value write fires the row's tracker and dirties the context. The equality
    // gate is what stops that being a derivation.
    @Test func anEqualValueWriteDerivesNothing() throws {
        let store = try EngineStore(shows: 4, seed: 12)
        let turns = EngineTurns()
        let engine = started(store, turns)
        let shows = try store.shows()
        let passes = engine.counters.passes
        let equal = engine.counters.equalValueReads
        for show in shows { show.groupName = show.groupName }
        try store.context.save()
        turns.run()
        #expect(engine.counters.passes == passes, "an equal-value write derived the queue again")
        #expect(engine.counters.equalValueReads >= equal + shows.count,
                "the rows were not read again, so the gate was never asked")
    }

    @Test func aContactsEditReachesItsShow() throws {
        let store = try EngineStore(shows: 3, seed: 13)
        let show = store.addShow(contacts: 2)
        try store.context.save()
        let turns = EngineTurns()
        let engine = started(store, turns)
        let contact = try #require(show.recipients.first)
        contact.name = "Renamed"
        try store.context.save()
        turns.run()
        let held = engine.facts.shows[show.persistentModelID]?.factContacts.first { $0.persistentModelID == contact.persistentModelID }
        #expect(held?.name == "Renamed")
        #expect(try engine.facts == store.freshFacts())
    }

    // Probe 2: moving a contact fires both parents. The map is what still finds the one it LEFT when only the
    // contact's own tracker reports the move.
    @Test func aContactMovedBetweenShowsChangesBoth() throws {
        let store = try EngineStore(shows: 2, seed: 14)
        let from = store.addShow(contacts: 2)
        let to = store.addShow(contacts: 0)
        try store.context.save()
        let turns = EngineTurns()
        let engine = started(store, turns)
        let moved = try #require(from.recipients.first)
        from.recipients.removeAll { $0 === moved }
        to.recipients.append(moved)
        try store.context.save()
        turns.run()
        #expect(engine.facts.shows[to.persistentModelID]?.factContacts.map(\.persistentModelID) == [moved.persistentModelID])
        #expect(engine.facts.shows[from.persistentModelID]?.factContacts.count == 1)
        #expect(try engine.facts == store.freshFacts())
    }

    // Probe 2: inserting a show whose natural key is already stored merges it INTO the stored row, which changes
    // in place and fires no tracker. Measured for #4358 (in memory and on disk alike): the save names only the
    // newcomer's own identifier as inserted, a row the store does not hold, and never the row that changed. So
    // the engine cannot know which row moved, reads everything, and counts it as the anomaly it is: the app's
    // writers look a row up by its key before inserting (`ScoutService.upsertTarget`).
    @Test func anInsertMergedIntoAStoredRowByItsKeyIsReadInFull() throws {
        let store = try EngineStore(shows: 3, seed: 15)
        let turns = EngineTurns()
        let engine = started(store, turns)
        let held = try #require(try store.shows().first)
        let twin = Prospect(naturalKey: held.naturalKey, groupName: "Upserted", discipline: "music", venue: "Hall",
                            performanceDate: "2027-03-01", sourceListingURL: nil, priorRelationship: "none",
                            production: "presenter", profile: "strong", coverage: "likely_uncovered",
                            fitScore: 9, tier: "mid", fitReason: "r", matchedClientName: nil, possibleMatchSource: nil,
                            possibleMatchName: nil, status: .drafted, ingestedAt: EngineStore.baseNow)
        #expect(engine.counters.insertsMergedAway == .neverFired)
        store.context.insert(twin)
        try store.context.save()
        turns.run()
        #expect(engine.facts.shows[held.persistentModelID]?.groupName == "Upserted")
        #expect(try engine.facts == store.freshFacts())
        #expect(engine.counters.insertsMergedAway.times == 1)
    }

    // #4327 step 0.4: an inserted row's identifier changes at its first save, and a tracker armed before it
    // still reports the old one.
    @Test func anUnsavedInsertIsReKeyedAtItsFirstSave() throws {
        let store = try EngineStore(shows: 2, seed: 16)
        let turns = EngineTurns()
        let engine = started(store, turns)
        let fresh = store.addShow(contacts: 1)
        let temporary = fresh.persistentModelID
        engine.noteChanged(fresh)
        turns.run()
        #expect(engine.facts.shows[temporary] != nil, "the unsaved insert was not taken in")
        try store.context.save()
        turns.run()
        let permanent = fresh.persistentModelID
        #expect(permanent != temporary)
        #expect(engine.facts.shows[temporary] == nil && engine.facts.shows[permanent] != nil)
        #expect(try engine.facts == store.freshFacts())
        // The tracker armed under the temporary identifier still fires with it; the edit must still land.
        fresh.fitReason = "edited after the first save"
        try store.context.save()
        turns.run()
        #expect(engine.facts.shows[permanent]?.fitReason == "edited after the first save")
        #expect(try engine.facts == store.freshFacts())
    }

    @Test func anInsertDeletedBeforeItsSaveLeavesNothing() throws {
        let store = try EngineStore(shows: 2, seed: 17)
        let turns = EngineTurns()
        let engine = started(store, turns)
        let fresh = store.addShow(contacts: 1)
        let temporary = fresh.persistentModelID
        engine.noteChanged(fresh)
        turns.run()
        #expect(engine.facts.shows[temporary] != nil)
        store.context.delete(fresh)
        engine.noteChanged(fresh)
        try store.context.save()
        turns.run()
        #expect(engine.facts.shows[temporary] == nil)
        #expect(try engine.facts == store.freshFacts())
    }

    // A save through ANOTHER context leaves the main context's own copies stale (probe 2), so the engine reads
    // every row again, and counts it as the anomaly it is in the app.
    @Test func aSaveThroughAnotherContextIsReadInFull() async throws {
        let store = try EngineStore(shows: 4, seed: 18)
        let turns = EngineTurns()
        let saves = StoreSaveCount()
        let engine = started(store, turns, saves: saves)
        #expect(engine.counters.foreignSaves == .neverFired)
        let id = try #require(try store.shows().first).persistentModelID
        let container = store.container
        let failure: String? = await phase0OnThread("engine-foreign-save") {
            let other = ModelContext(container)
            guard let row = other.model(for: id) as? Prospect else { return "the row was not found" }
            row.fitReason = "written elsewhere"
            return Phase0.saveFailure(other)
        }
        try Phase0.requireSaved(failure, step: "the foreign save")
        #expect(saves.foreignSaveCount(for: container) == 1)
        await waitUntil("the foreign save asked for a pass") { !turns.queued.isEmpty }
        turns.run()
        #expect(engine.counters.foreignSaves.times == 1)
        #expect(engine.facts.shows[id]?.fitReason == "written elsewhere")
        #expect(try engine.facts == store.freshFacts())
    }

    @Test func aSaveIntoAnotherStoreIsNotAChangeToThisOne() throws {
        let store = try EngineStore(shows: 2, seed: 19)
        let other = try EngineStore(shows: 2, seed: 20)
        let turns = EngineTurns()
        let engine = started(store, turns)
        other.addShow()
        try other.context.save()
        #expect(turns.queued.isEmpty, "a save into another store asked this engine for a pass")
        #expect(engine.isIdle)
    }

    @Test func smallTableAndInquiryWritesAreTakenInFromTheSave() throws {
        let store = try EngineStore(shows: 2, inquiries: 2, smallRows: 2, seed: 21)
        let turns = EngineTurns()
        let engine = started(store, turns)
        store.addSmallTableRows()
        store.addInquiry()
        let answer = try #require(try store.context.fetch(FetchDescriptor<OrgReachabilityAnswer>()).first)
        answer.presenterName = "Renamed presenter"
        let inquiry = try #require(try store.context.fetch(FetchDescriptor<Inquiry>()).first)
        inquiry.notes = "a note"
        try store.context.save()
        turns.run()
        #expect(try engine.facts == store.freshFacts())
    }
}
