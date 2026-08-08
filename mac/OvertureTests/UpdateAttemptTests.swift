import Testing
import Foundation

// #2188: what Overture makes of a press of the Update button.
//
// The button opens a Terminal window and forgets it, so until now a refused update and a successful one
// were the same thing from inside the app: nothing. Dan pressed Update on 2026-08-06, the run refused
// because another session had work in progress in the checkout, and the app said nothing for the rest of
// the launch, having already dismissed its own out of date panel on the press. He read that as "nothing
// to update".
//
// The run now leaves a record and this decides what it means. Pure, so every state is reachable from a
// test without a Terminal window, a build, or a 90 second wait.
@Suite("What Overture makes of an update it asked for (#2188)")
struct UpdateAttemptTests {
    private func record(press: String, outcome: String, reason: String? = nil) -> UpdateAttemptRecord {
        UpdateAttemptRecord(press: press, outcome: outcome, reason: reason)
    }

    // MARK: - The three answers

    @Test func aRunThatSaysItFailedIsReportedWithItsReason() {
        let p = UpdateAttempt.progress(record: record(press: "abc", outcome: "failed",
                                                      reason: "There is unsaved work in progress in the code folder."),
                                       press: "abc", elapsed: 5)
        #expect(p == .failed(reason: "There is unsaved work in progress in the code folder."))
    }

    @Test func aRunStillGoingIsNotAFailure() {
        #expect(UpdateAttempt.progress(record: record(press: "abc", outcome: "running"),
                                       press: "abc", elapsed: 45) == .running)
    }

    // The install takes about ninety seconds and the record appears within one, so the only thing an
    // absence can mean once the grace period is up is that the run never started: the file was never
    // opened, Terminal never ran it. Reporting that as a failure of the update would be claiming more
    // than was measured (L11), and they are different things to fix.
    @Test func nothingAtAllAfterTheGracePeriodIsARunThatNeverStarted() {
        #expect(UpdateAttempt.progress(record: nil, press: "abc",
                                       elapsed: UpdateAttempt.graceSeconds + 1) == .neverStarted)
    }

    @Test func nothingYetInsideTheGracePeriodIsNotYetAnything() {
        #expect(UpdateAttempt.progress(record: nil, press: "abc",
                                       elapsed: UpdateAttempt.graceSeconds - 1) == .waiting)
    }

    // MARK: - Whose outcome it is

    // The load-bearing one. A record from an earlier press must never answer for this one: a refusal
    // yesterday would otherwise be shown over a working update today, and the person reading it has no
    // way to tell which run it came from.
    @Test func aRecordFromAnotherPressIsNotThisPressesOutcome() {
        let p = UpdateAttempt.progress(record: record(press: "old", outcome: "failed", reason: "yesterday"),
                                       press: "new", elapsed: 5)
        #expect(p == .waiting)
    }

    @Test func andAnotherPressesRecordStillLeavesThisOneAsNeverStartedOnceTheGraceIsUp() {
        let p = UpdateAttempt.progress(record: record(press: "old", outcome: "failed", reason: "yesterday"),
                                       press: "new", elapsed: UpdateAttempt.graceSeconds + 1)
        #expect(p == .neverStarted)
    }

    // MARK: - Records that do not say enough

    // A failure with no reason is still a failure. It must not decay into "running" or into silence,
    // which are the two answers that would leave Dan with a copy that did not update and nothing on
    // screen. The sentence says only what is known: it failed, and it did not say why.
    @Test func aFailureWithNoReasonSaysThatRatherThanInventingOne() {
        #expect(UpdateAttempt.progress(record: record(press: "abc", outcome: "failed", reason: ""),
                                       press: "abc", elapsed: 5)
                == .failed(reason: UpdateAttemptCopy.unexplained))
        #expect(UpdateAttempt.progress(record: record(press: "abc", outcome: "failed", reason: nil),
                                       press: "abc", elapsed: 5)
                == .failed(reason: UpdateAttemptCopy.unexplained))
    }

    // An outcome this app does not recognise means the two halves disagree about their own contract, and
    // the safe reading is the one that shows something: success is expressed by REMOVING the record, so
    // a record that is present and unreadable can never be a success.
    @Test func anOutcomeItDoesNotUnderstandIsTreatedAsAFailure() {
        #expect(UpdateAttempt.progress(record: record(press: "abc", outcome: "banana"),
                                       press: "abc", elapsed: 5)
                == .failed(reason: UpdateAttemptCopy.unexplained))
    }

    // MARK: - Reading the file

    @Test func itReadsARecordFromDisk() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("update-attempt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(UpdateAttempt.record(in: dir) == nil)

        try #"{"version":1,"press":"abc","outcome":"failed","reason":"no","at":"2026-08-06T14:00:00Z"}"#
            .write(to: dir.appendingPathComponent(UpdateAttempt.recordFilename),
                   atomically: true, encoding: .utf8)
        #expect(UpdateAttempt.record(in: dir) == UpdateAttemptRecord(press: "abc", outcome: "failed", reason: "no"))
    }

    // A half written or corrupt file reads as absent, which lands on "never started" rather than on a
    // claim about an outcome nobody could read.
    @Test func anUnreadableRecordReadsAsNoRecord() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("update-attempt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{not json".write(to: dir.appendingPathComponent(UpdateAttempt.recordFilename),
                              atomically: true, encoding: .utf8)
        #expect(UpdateAttempt.record(in: dir) == nil)
    }

    // The record lives in the same folder as the handoff files, which is swept at launch (#821). The
    // sweep is name-first and must not own this one, or a press would lose its own outcome.
    @Test func theLaunchSweepDoesNotOwnTheRecord() {
        #expect(HandoffCleanup.owns(UpdateAttempt.recordFilename) == false)
    }

    // MARK: - Against what the writer really writes

    // The reader and the writer are in different languages with no run in between, so the shape is only
    // as pinned as the sample it is checked against. These two files were PRODUCED BY
    // `mac/scripts/lib/update-result.sh`, not typed out here (L48, L52): a hand-written sample can only
    // confirm the assumption of whoever wrote it, and a key renamed on the shell side would leave this
    // suite green while the app read every real record as absent and called every refusal a run that
    // never started. `mac/scripts/update-overture.test.sh` holds the other half, and fails if the writer
    // stops producing what is committed here.
    private func contractFixture(_ name: String) throws -> UpdateAttemptRecord {
        let url = RepoRoot.url
            .appendingPathComponent("fixtures/update-result").appendingPathComponent(name)
        return try JSONDecoder().decode(UpdateAttemptRecord.self, from: Data(contentsOf: url))
    }

    @Test func aRefusalTheWriterWroteIsReadAsARefusal() throws {
        let record = try contractFixture("refused.json")
        let p = UpdateAttempt.progress(record: record, press: "press-fixture", elapsed: 5)

        #expect(p == .failed(reason: record.reason ?? ""))
        #expect(record.reason?.contains("unsaved work in progress") == true)
        // And it is NOT read as the unexplained fallback, which is what a reason that failed to decode
        // would land on: the sentence would still be honest and the run's own words would be lost.
        #expect(p != .failed(reason: UpdateAttemptCopy.unexplained))
    }

    @Test func aRunningRecordTheWriterWroteIsReadAsRunning() throws {
        let record = try contractFixture("running.json")
        #expect(UpdateAttempt.progress(record: record, press: "press-fixture", elapsed: 5) == .running)
        // Its empty reason must not turn it into a failure on the way through.
        #expect(UpdateAttempt.progress(record: record, press: "press-fixture",
                                       elapsed: UpdateAttempt.graceSeconds + 1) == .running)
    }

    // MARK: - What it says

    @Test func eachStateSaysItsOwnThing() {
        #expect(UpdateAttemptCopy.body(.failed(reason: "Overture did not update: because."))
                == "Overture did not update: because.")
        #expect(UpdateAttemptCopy.body(.neverStarted) == "The update never started. Ask Claude to look.")
        // The two quiet states have no panel and so no sentence, rather than a cheerful one that would
        // sit in the copy inventory as something Overture can say while being unreachable.
        #expect(UpdateAttemptCopy.body(.running) == "")
        #expect(UpdateAttemptCopy.body(.waiting) == "")
    }

    @Test func onlyTheTwoStatesWorthInterruptingHimShowAPanel() {
        #expect(UpdateAttempt.shouldShow(.failed(reason: "x")))
        #expect(UpdateAttempt.shouldShow(.neverStarted))
        // Nothing is wrong yet, and the Terminal window is on screen showing the run. A panel here
        // would interrupt him to say the thing he just asked for is happening.
        #expect(UpdateAttempt.shouldShow(.running) == false)
        #expect(UpdateAttempt.shouldShow(.waiting) == false)
    }
}
