import Testing
import Foundation

// #2882: one show OmniFocus refused used to abort the whole pass. `apply` called `create` and
// `complete` per task and let any throw propagate, so every show AFTER the failing one silently got no
// reminder created or completed, and the masthead said "OmniFocus sync failing" with no hint that the
// blast radius was the rest of the run.
//
// Measured live 2026-08-17: one show ("The Pumpkin Singalong at Sakura Park") threw `Invalid index` and
// the run stopped there. Independent per-show work sharing one failure boundary makes every show's
// reliability depend on every other show's worst case (L73). The point of this sync is a reminder that
// reaches Dan away from his desk, so a missing one is invisible until the show has passed.
@Suite("One failing show stops only itself")
struct OneFailingShowStopsOnlyItselfTests {
    private func desired(_ key: String, _ recipient: String = "a@example.invalid",
                         due: Date = Date(timeIntervalSince1970: 1_780_000_000)) -> OmniFocusSync.DesiredTask {
        OmniFocusSync.DesiredTask(kind: .replyTriage, naturalKey: key, recipientId: recipient,
                                  title: "t", note: "n", deferDate: due, dueDate: due)
    }

    // Refuses whatever key it is told to refuse, and records everything it was asked to do, so a test
    // can assert the run kept going rather than merely that it did not throw.
    private final class RefusingClient: OmniFocusClient {
        let refuse: String
        let open: [OmniFocusSync.ExistingTask]
        var created: [String] = []
        var completed: [String] = []
        init(refuse: String, open: [OmniFocusSync.ExistingTask] = []) {
            self.refuse = refuse
            self.open = open
        }
        struct Refused: Error {}
        func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { open }
        func completedOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
        func create(_ task: OmniFocusSync.DesiredTask) throws {
            if task.naturalKey == refuse { throw Refused() }
            created.append(task.naturalKey)
        }
        func complete(_ task: OmniFocusSync.ExistingTask) throws {
            if task.naturalKey == refuse { throw Refused() }
            completed.append(task.naturalKey)
        }
    }

    @Test func aRefusedCreateDoesNotStopTheShowsAfterIt() throws {
        let client = RefusingClient(refuse: "middle|2026-09-04|a room")
        let result = try OmniFocusSync.apply(
            desired: [desired("first|2026-09-04|a room"), desired("middle|2026-09-04|a room"),
                      desired("last|2026-09-04|a room")],
            client: client)

        #expect(client.created == ["first|2026-09-04|a room", "last|2026-09-04|a room"])
        #expect(result.created == 2)
        #expect(result.failures.map(\.naturalKey) == ["middle|2026-09-04|a room"])
        #expect(result.failures.first?.action == .create)
    }

    // The completes are the half the live failure landed in, and they run after the creates, so a throw
    // there took every remaining stale task with it.
    @Test func aRefusedCompleteDoesNotStopTheOnesAfterIt() throws {
        let due = Date(timeIntervalSince1970: 1_780_000_000)
        let stale = ["one", "two", "three"].map {
            OmniFocusSync.ExistingTask(naturalKey: "\($0)|2026-09-04|a room", recipientId: "a@example.invalid",
                                       dueDate: due)
        }
        let client = RefusingClient(refuse: "one|2026-09-04|a room", open: stale)

        let result = try OmniFocusSync.apply(desired: [], client: client)

        #expect(client.completed == ["two|2026-09-04|a room", "three|2026-09-04|a room"])
        #expect(result.completed == 2)
        #expect(result.failures.map(\.action) == [.complete])
    }

    // L47: an item left with no trace is indistinguishable from one never attempted, so the failure
    // names the show and the contact, not just a count.
    @Test func aFailureNamesTheShowAndTheContactAndTheReason() throws {
        let client = RefusingClient(refuse: "the singalong|2026-10-25|a park")
        let result = try OmniFocusSync.apply(
            desired: [desired("the singalong|2026-10-25|a park", "booking@example.invalid")], client: client)

        let failure = try #require(result.failures.first)
        #expect(failure.naturalKey == "the singalong|2026-10-25|a park")
        #expect(failure.recipientId == "booking@example.invalid")
        #expect(!failure.reason.isEmpty)
    }

    // The counts must report what actually happened, not what was planned, or a partly failed run reads
    // as having done more than it did (L12).
    @Test func theCountsReportWhatLandedNotWhatWasPlanned() throws {
        let client = RefusingClient(refuse: "b|2026-09-04|a room")
        let result = try OmniFocusSync.apply(
            desired: [desired("a|2026-09-04|a room"), desired("b|2026-09-04|a room")], client: client)

        #expect(result.created == 1)
    }

    // A failed READ still fails the whole run, deliberately: not knowing what OmniFocus holds makes
    // every later decision guesswork, so completing and creating against a picture of nothing would be
    // worse than stopping.
    @Test func aFailedReadStillFailsTheWholeRun() {
        struct DeadClient: OmniFocusClient {
            struct Dead: Error {}
            func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { throw Dead() }
            func completedOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
            func create(_ task: OmniFocusSync.DesiredTask) throws {}
            func complete(_ task: OmniFocusSync.ExistingTask) throws {}
        }
        #expect(throws: (any Error).self) {
            try OmniFocusSync.apply(desired: [desired("a|2026-09-04|a room")], client: DeadClient())
        }
    }

    // MARK: - What Dan is told

    @Test func theMessageNamesTheShowThatWasMissedAndHowManyLanded() {
        let failures = [OmniFocusSync.TaskFailure(action: .create, naturalKey: "the singalong|2026-10-25|a park",
                                                  recipientId: "a@example.invalid", reason: "Invalid index")]
        let message = OmniFocusSync.partialFailureMessage(failures: failures, attempted: 12)
        #expect(message == "OmniFocus updated 11 of 12 reminders. It could not update the singalong.")
    }

    @Test func severalMissedShowsAreNamedTwoThenCounted() throws {
        let failures = ["a show", "b show", "c show", "d show"].map {
            OmniFocusSync.TaskFailure(action: .create, naturalKey: "\($0)|2026-10-25|a park",
                                      recipientId: "x@example.invalid", reason: "Invalid index")
        }
        let message = try #require(OmniFocusSync.partialFailureMessage(failures: failures, attempted: 10))
        #expect(message.contains("a show, b show and 2 more"))
        #expect(message.contains("6 of 10"))
    }

    // Nothing failed has no sentence, rather than one naming no show: a line Dan can never be shown
    // still sits in the copy inventory looking live (L132).
    @Test func aRunWithNoFailuresHasNoSentence() {
        #expect(OmniFocusSync.partialFailureMessage(failures: [], attempted: 4) == nil)
    }

    // Two contacts on one show is one show missed, not two, or the sentence over-reports the damage.
    @Test func twoContactsOnOneShowAreNamedOnce() {
        let failures = ["a@example.invalid", "b@example.invalid"].map {
            OmniFocusSync.TaskFailure(action: .create, naturalKey: "one show|2026-10-25|a park",
                                      recipientId: $0, reason: "Invalid index")
        }
        let message = OmniFocusSync.partialFailureMessage(failures: failures, attempted: 5)
        #expect(message == "OmniFocus updated 3 of 5 reminders. It could not update one show.")
    }
}

// A partly failed run has to stay visible. It is not a success (a reminder is missing and Dan cannot
// see an absence) and not a total failure (most of the run landed), and recording it as either loses
// one of those two facts.
@Suite("A partly failed OmniFocus run stays on the masthead")
struct PartlyFailedOmniFocusRunTests {
    private final class RefusingClient: OmniFocusClient {
        struct Refused: Error {}
        func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
        func completedOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
        func create(_ task: OmniFocusSync.DesiredTask) throws { throw Refused() }
        func complete(_ task: OmniFocusSync.ExistingTask) throws {}
    }

    private final class CountingNotifier: OmniFocusNotifier {
        var failed = 0
        func notifyPermissionNeeded() {}
        func notifySyncFailed(_ message: String) { failed += 1 }
    }

    private func scratchDefaults(_ name: String) throws -> UserDefaults {
        let d = try #require(UserDefaults(suiteName: name))
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func aPartlyFailedRunIsRecordedAsAFailureNamingTheShow() throws {
        let defaults = try scratchDefaults("omnifocus-partial-\(UUID().uuidString)")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let task = OmniFocusSync.DesiredTask(kind: .replyTriage, naturalKey: "the singalong|2026-10-25|a park",
                                             recipientId: "a@example.invalid", title: "t", note: "n",
                                             deferDate: now, dueDate: now)
        let notifier = CountingNotifier()

        _ = OmniFocusSyncRunner.run(desired: [task], permission: .granted, client: RefusingClient(),
                                    notifier: notifier, now: now, defaults: defaults)

        let failure = try #require(OmniFocusSyncStatus.lastFailure(from: defaults))
        #expect(failure.message.contains("the singalong"))
        #expect(OmniFocusSyncStatus.lastSuccessAt(from: defaults) == nil, "it did not all land, so it is not a success")
        #expect(notifier.failed == 1)
    }

    private final class WillingClient: OmniFocusClient {
        func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
        func completedOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
        func create(_ task: OmniFocusSync.DesiredTask) throws {}
        func complete(_ task: OmniFocusSync.ExistingTask) throws {}
    }

    @Test func aCleanRunAfterOneStillRecordsSuccessAndClearsTheWarning() throws {
        let defaults = try scratchDefaults("omnifocus-clean-\(UUID().uuidString)")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let task = OmniFocusSync.DesiredTask(kind: .replyTriage, naturalKey: "a show|2026-10-25|a park",
                                             recipientId: "a@example.invalid", title: "t", note: "n",
                                             deferDate: now, dueDate: now)
        _ = OmniFocusSyncRunner.run(desired: [task], permission: .granted, client: RefusingClient(),
                                    notifier: CountingNotifier(), now: now, defaults: defaults)
        #expect(OmniFocusSyncStatus.lastFailure(from: defaults) != nil)

        _ = OmniFocusSyncRunner.run(desired: [task], permission: .granted, client: WillingClient(),
                                    notifier: CountingNotifier(), now: now, defaults: defaults)

        #expect(OmniFocusSyncStatus.lastFailure(from: defaults) == nil)
        #expect(OmniFocusSyncStatus.lastSuccessAt(from: defaults) == now)
    }
}
