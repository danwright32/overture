import Testing
import Foundation

// #3419 / #3433: the seam that gets a blocking Apple event off the main actor.
//
// Both OmniFocus call sites drove NSAppleScript from the main actor, and both carried a comment
// asserting the opposite of what they did: OmniFocusSync.apply says it is shaped "so it can run off
// the main actor", and RootView.syncOmniFocus says "the slow AppleScript I/O runs off-main in a
// detached task" three lines above a `Task { @MainActor in }`. Built is not wired (L3).
//
// The premise that kept it there is stated at both sites: that NSAppleScript "must run on the main
// thread". That is a claim about a platform primitive, and the whole safety of the old shape rested
// on it, so it is MEASURED against the real target here rather than inherited (L82, L316). If it
// were true, `appleScriptRunsOffTheMainThread` is the test that would say so.
@MainActor
@Suite("Blocking work thread (#3419)")
struct BlockingWorkThreadTests {
    @Test func runsTheWorkOffTheMainThread() async throws {
        let worker = BlockingWorkThread(name: "test-off-main")
        let ranOnMain = try await worker.run(deadlineSeconds: 30) { Thread.isMainThread }
        #expect(ranOnMain == false)
    }

    // The measurement the two call-site comments assert the opposite of. A script needing no target
    // application, so it asks about the THREAD and not about Automation permission or OmniFocus being
    // installed: a test needing either would be measuring this Mac's TCC state instead.
    @Test func appleScriptRunsOffTheMainThread() async throws {
        let worker = BlockingWorkThread(name: "test-applescript")
        let answer = try await worker.run(deadlineSeconds: 30) { () -> String in
            guard let script = NSAppleScript(source: "return \"ok\"") else { return "did not compile" }
            var err: NSDictionary?
            let result = script.executeAndReturnError(&err)
            if let err { return "failed: \(err)" }
            return result.stringValue ?? "no value"
        }
        #expect(answer == "ok")
    }

    // A wait with no deadline cannot fail, it can only hang, and a hang is indistinguishable from
    // slowness (L110). The sleep is injected so the deadline fires without waiting for real time, and
    // so the assertion is about the OUTCOME rather than about what else the machine is running
    // (L224, L290, L524).
    @Test func workThatOutlivesItsDeadlineReportsATimeout() async throws {
        let worker = BlockingWorkThread(name: "test-deadline")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await #expect(throws: BlockingWorkError.timedOut(seconds: 60)) {
            try await worker.run(deadlineSeconds: 60, sleep: { _ in }) { release.wait() }
        }
    }

    // The next tick must not stack a second Apple event behind one already hung: the reconcile fires
    // at launch, every 30 minutes and on every Downbeat export change (#3419), so an unanswered
    // OmniFocus would otherwise queue one more every half hour for the life of the process.
    @Test func aSecondRunIsRefusedWhileOneIsStillOutstanding() async throws {
        let worker = BlockingWorkThread(name: "test-busy")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await #expect(throws: BlockingWorkError.timedOut(seconds: 60)) {
            try await worker.run(deadlineSeconds: 60, sleep: { _ in }) { release.wait() }
        }
        await #expect(throws: BlockingWorkError.busy) {
            try await worker.run(deadlineSeconds: 60, sleep: { _ in }) { true }
        }
    }

    // Busy is a state that ENDS. Without this, one hung Apple event would refuse every later sync for
    // the life of the process, which is a worse defect than the freeze it replaced: the freeze ended.
    @Test func aRefusalClearsOnceTheOutstandingWorkFinishes() async throws {
        let worker = BlockingWorkThread(name: "test-recovers")
        let release = DispatchSemaphore(value: 0)
        await #expect(throws: BlockingWorkError.timedOut(seconds: 60)) {
            try await worker.run(deadlineSeconds: 60, sleep: { _ in }) { release.wait() }
        }
        release.signal()
        _ = await waitUntil("the hung work item to return, so the worker reports itself idle again") {
            !worker.isBusy
        }
        let accepted = try await worker.run(deadlineSeconds: 30) { true }
        #expect(accepted)
    }

    // The work's OWN failure is not a timeout and not a refusal: it is the error it threw, reaching
    // the caller unwrapped, because the OmniFocus callers classify by that error (L199, L11).
    @Test func theWorksOwnErrorReachesTheCaller() async throws {
        struct Boom: Error, Equatable {}
        let worker = BlockingWorkThread(name: "test-throws")
        await #expect(throws: Boom.self) {
            try await worker.run(deadlineSeconds: 30) { throw Boom() }
        }
    }
}
