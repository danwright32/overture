import Testing
import Foundation

// #3419 / #3433: where the OmniFocus sync's two halves RUN.
//
// The Apple event half blocked the main actor, so the whole window stopped drawing and stopped taking
// clicks for its duration, on a tick that fires at launch, every 30 minutes and on every Downbeat
// export change. The model half must stay on the main actor, because that is where SwiftData lives.
// Both facts are asserted here rather than left to a comment, because the comments at both call sites
// already claimed the first one while the code did the opposite (L3).
@Suite("OmniFocus sync runs off the main actor (#3419)")
struct OmniFocusSyncOffTheMainActorTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "of-offmain-\(UUID().uuidString)")!
    }

    private final class ThreadRecordingClient: OmniFocusClient, @unchecked Sendable {
        var readOnMainActor: Bool?
        func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] {
            readOnMainActor = Thread.isMainThread
            return []
        }
        func completedOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
        func create(_ task: OmniFocusSync.DesiredTask) throws {}
        func complete(_ task: OmniFocusSync.ExistingTask) throws {}
    }

    private final class BlockedClient: OmniFocusClient, @unchecked Sendable {
        let held = DispatchSemaphore(value: 0)
        func existingOvertureTasks() throws -> [OmniFocusSync.ExistingTask] {
            held.wait()
            return []
        }
        func completedOvertureTasks() throws -> [OmniFocusSync.ExistingTask] { [] }
        func create(_ task: OmniFocusSync.DesiredTask) throws {}
        func complete(_ task: OmniFocusSync.ExistingTask) throws {}
    }

    private final class SilentNotifier: OmniFocusNotifier {
        var failed: [String] = []
        func notifyPermissionNeeded() {}
        func notifySyncFailed(_ message: String) { failed.append(message) }
    }

    @Test @MainActor func theAppleEventHalfDoesNotRunOnTheMainActor() async {
        let client = ThreadRecordingClient()
        _ = await OmniFocusSyncRunner.run(desired: [], permission: .granted, client: client,
                                          notifier: SilentNotifier(), now: Date(),
                                          defaults: freshDefaults(),
                                          worker: BlockingWorkThread(name: "test-runner-offmain"))
        #expect(client.readOnMainActor == false)
    }

    // The other half of the same split. `recordCompletions` writes the SwiftData model, so moving the
    // whole runner off the main actor would have swapped a freeze for a data race.
    @Test @MainActor func theModelWriteBackStaysOnTheMainActor() async {
        var recordedOnMainActor: Bool?
        _ = await OmniFocusSyncRunner.run(desired: [], permission: .granted,
                                          client: ThreadRecordingClient(),
                                          notifier: SilentNotifier(), now: Date(),
                                          defaults: freshDefaults(),
                                          worker: BlockingWorkThread(name: "test-runner-writeback"),
                                          recordCompletions: { _ in
                                              recordedOnMainActor = Thread.isMainThread
                                              return 0
                                          })
        #expect(recordedOnMainActor == true)
    }

    // A tick that gave up waiting did not sync. Recording it as a success would put a fresh "Synced
    // just now" on the toolbar over an OmniFocus that answered nothing (L12, L98).
    @Test @MainActor func aTickThatGaveUpWaitingIsRecordedAsAFailure() async {
        let defaults = freshDefaults()
        let notifier = SilentNotifier()
        let client = BlockedClient()
        defer { client.held.signal() }
        let result = await OmniFocusSyncRunner.run(desired: [], permission: .granted, client: client,
                                                   notifier: notifier, now: Date(), defaults: defaults,
                                                   worker: BlockingWorkThread(name: "test-runner-deadline"),
                                                   deadlineSeconds: 0)
        #expect(result.tasks == 0)
        #expect(OmniFocusSyncStatus.lastSuccessAt(from: defaults) == nil)
        #expect(OmniFocusSyncStatus.lastFailure(from: defaults) != nil)
        #expect(notifier.failed.count == 1)
    }

    // The next tick arrives while the hung one is still out. It must not queue a second Apple event,
    // and it must not read as the same fault: "OmniFocus never answered" and "the previous sync has
    // not come back yet" are different sentences to whoever is looking at the masthead (L11).
    @Test @MainActor func aTickArrivingWhileOneIsOutstandingIsRefusedRatherThanQueued() async {
        let worker = BlockingWorkThread(name: "test-runner-busy")
        let occupier = DispatchSemaphore(value: 0)
        defer { occupier.signal() }
        await #expect(throws: BlockingWorkError.timedOut(seconds: 0)) {
            try await worker.run(deadlineSeconds: 0) { occupier.wait() }
        }
        let defaults = freshDefaults()
        let client = ThreadRecordingClient()
        let result = await OmniFocusSyncRunner.run(desired: [], permission: .granted, client: client,
                                                   notifier: SilentNotifier(), now: Date(),
                                                   defaults: defaults, worker: worker)
        #expect(result.tasks == 0)
        #expect(client.readOnMainActor == nil)          // never submitted at all
        #expect(OmniFocusSyncStatus.lastFailure(from: defaults) != nil)
    }

    // Distinct causes get distinct messages (L11), through the classifier that already owns what an
    // OmniFocus failure IS, rather than a second reading of the stored text somewhere else (L35).
    @Test func theTwoWaitingFailuresClassifyApartFromEachOtherAndFromEverythingElse() {
        let didNotAnswer = OmniFocusFailureKind.of(message: OmniFocusFailureKind.didNotAnswerMarker,
                                                   permissionNeeded: false)
        let stillRunning = OmniFocusFailureKind.of(message: OmniFocusFailureKind.stillRunningMarker,
                                                   permissionNeeded: false)
        #expect(didNotAnswer == .didNotAnswer)
        #expect(stillRunning == .stillRunning)
        #expect(didNotAnswer.line(reason: "") != stillRunning.line(reason: ""))
        #expect(didNotAnswer.help(reason: "") != stillRunning.help(reason: ""))
        // Neither may be shown as the catch-all, which is the sentence that says nothing was measured.
        #expect(didNotAnswer.line(reason: "") != OmniFocusFailureKind.unexplained.line(reason: ""))
        #expect(stillRunning.line(reason: "") != OmniFocusFailureKind.unexplained.line(reason: ""))
    }

    // The marker is a token the writer and the classifier share, not a sentence: it must never reach
    // the masthead as though it were Overture's own words (L199).
    @Test func neitherMarkerLeaksIntoWhatDanIsShown() {
        for kind in [OmniFocusFailureKind.didNotAnswer, .stillRunning] {
            #expect(!kind.line(reason: OmniFocusFailureKind.didNotAnswerMarker)
                .contains(OmniFocusFailureKind.didNotAnswerMarker))
            #expect(!kind.help(reason: OmniFocusFailureKind.stillRunningMarker)
                .contains(OmniFocusFailureKind.stillRunningMarker))
        }
    }

    // The forced sync's own alert is the other surface the marker could reach: it reports the stored
    // text directly, so a token written for the classifier would be shown to Dan as a sentence.
    @Test func theForcedSyncsAlertNeverShowsAMarkerEither() {
        for waiting in [BlockingWorkError.timedOut(seconds: 120), .busy] {
            let sentence = OmniFocusFailureKind.reportedSentence(for: waiting)
            #expect(!sentence.contains(OmniFocusFailureKind.didNotAnswerMarker))
            #expect(!sentence.contains(OmniFocusFailureKind.stillRunningMarker))
            #expect(!sentence.isEmpty)
        }
        // An ordinary failure keeps the wording it has always had, so this narrowing did not quietly
        // reword every other OmniFocus alert on the way past.
        struct Ordinary: Error, CustomStringConvertible { var description: String { "a plain fault" } }
        #expect(OmniFocusFailureKind.reportedSentence(for: Ordinary())
            == OmniFocusSync.failureMessage(reason: "a plain fault"))
    }
}
