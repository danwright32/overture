import AppKit
import Foundation
import SwiftData
import Testing

// #4358 (plan v2 Phase 4 step 4, L51, L524): the queue engine's clock. One deadline after each pass, at the
// earlier of the output's own next change and a 60 second floor, on a clock the test moves by hand; and a pass
// on wake, on a change to the system clock or time zone, and on a new calendar day, each heard on the centre it
// is really posted to. A floor-only pass that changes the output is recorded by the fields it changed, which is
// the floor's named cost (L93).
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
        let engine: QueueEngine<EngineDerivations.Counts>
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
        let asked = await waitUntil("the floor asked for a pass") { !rig.turns.queued.isEmpty }
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
        let asked = await waitUntil("the rule's deadline asked for a pass") { !rig.turns.queued.isEmpty }
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
        #expect(rig.turns.queued.count == 1, "\(event.name.rawValue) asked for no pass")
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
        await waitUntil("the floor asked for a pass") { !rig.turns.queued.isEmpty }
        rig.turns.run()
        #expect(rig.engine.floorChanges.map(\.fields) == [["minute"]])
        #expect(rig.engine.floorChanges.first?.at == rig.clock.now)
    }

    @Test func aFloorPassThatChangesNothingRecordsNothing() async throws {
        let rig = try await rig(seed: 45)
        rig.clock.advance(by: 60)
        await waitUntil("the floor asked for a pass") { !rig.turns.queued.isEmpty }
        rig.turns.run()
        #expect(rig.engine.output?.reasons == [.clockFloor])
        #expect(rig.engine.floorChanges.isEmpty)
    }

    // A pass the floor shares with a real change is not the floor's doing, so it records nothing even when the
    // output moved.
    @Test func aFloorPassThatAlsoTookInAChangeIsNotTheFloorsCost() async throws {
        let rig = try await rig(EngineDerivations.counts(readsTheMinute: true), seed: 46)
        rig.clock.advance(by: 60)
        await waitUntil("the floor asked for a pass") { !rig.turns.queued.isEmpty }
        // A change lands in the same turn as the floor's pass, so that pass takes both in.
        rig.store.addShow()
        try rig.store.context.save()
        rig.turns.run()
        #expect(rig.engine.output?.reasons == [.clockFloor, .factsChanged])
        #expect(rig.engine.floorChanges.isEmpty)
    }
}
