import Testing
import Foundation

// #268 / Phase 4: the unattended OmniFocus push must (a) pre-check Automation permission silently and
// SKIP the AppleScript when not granted — so a windowless background process never posts a TCC modal
// into the void — and (b) surface a not-granted (or failed) outcome as a notification, exactly once
// per episode rather than every tick. The native permission probe and the real notifier are thin
// untestable shims; this exercises the decision between them.
@MainActor
@Suite("OmniFocus sync runner (#268)")
struct OmniFocusSyncRunnerTests {
    private func freshDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "of-runner-\(UUID().uuidString)")!
        return d
    }

    private final class FakeClient: OmniFocusClient, @unchecked Sendable {
        var existingCalled = false
        var throwOnExisting = false
        func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] {
            existingCalled = true
            if throwOnExisting { throw NSError(domain: "of", code: 1) }
            return []
        }
        func completedOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
        func create(_ task: OmniFocusSync.DesiredTask) throws {}
        func complete(_ task: OmniFocusSync.ExistingTask) throws {}
    }

    private final class FakeNotifier: OmniFocusNotifier {
        var permissionNeeded = 0
        var failed = 0
        func notifyPermissionNeeded() { permissionNeeded += 1 }
        func notifySyncFailed(_ message: String) { failed += 1 }
    }

    @Test func notGrantedSkipsTheClientAndNotifiesOnce() async {
        let d = freshDefaults(); let client = FakeClient(); let note = FakeNotifier()
        await OmniFocusSyncRunner.run(desired: [], permission: .notGranted, client: client,
                                notifier: note, now: Date(), defaults: d)
        #expect(client.existingCalled == false)                       // never fired the AppleScript
        #expect(OmniFocusSyncStatus.isPermissionNeeded(from: d))
        #expect(note.permissionNeeded == 1)
    }

    @Test func repeatedDenialNotifiesExactlyOnce() async {
        let d = freshDefaults(); let note = FakeNotifier()
        for _ in 0..<3 {
            await OmniFocusSyncRunner.run(desired: [], permission: .notGranted, client: FakeClient(),
                                    notifier: note, now: Date(), defaults: d)
        }
        #expect(note.permissionNeeded == 1)                           // one per episode, not per tick
    }

    @Test func grantedRunsTheClientAndClearsState() async {
        let d = freshDefaults(); let client = FakeClient(); let note = FakeNotifier()
        await OmniFocusSyncRunner.run(desired: [], permission: .notGranted, client: FakeClient(),
                                notifier: note, now: Date(), defaults: d)   // get into denied episode first
        await OmniFocusSyncRunner.run(desired: [], permission: .granted, client: client,
                                notifier: note, now: Date(), defaults: d)
        #expect(client.existingCalled)
        #expect(OmniFocusSyncStatus.isPermissionNeeded(from: d) == false)
        #expect(OmniFocusSyncStatus.lastFailure(from: d) == nil)
        #expect(note.failed == 0)
    }

    @Test func grantedButFailingRecordsAndNotifies() async {
        let d = freshDefaults(); let client = FakeClient(); client.throwOnExisting = true
        let note = FakeNotifier()
        await OmniFocusSyncRunner.run(desired: [], permission: .granted, client: client,
                                notifier: note, now: Date(), defaults: d)
        #expect(OmniFocusSyncStatus.lastFailure(from: d) != nil)
        #expect(note.failed == 1)
    }
}
