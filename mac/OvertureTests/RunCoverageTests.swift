import Testing
import Foundation

// #3010, phase 1 of the revised #2765 plan. A run has to publish WHICH SHOWS it holds, so the other
// launch can drop the overlap instead of two paid runs both taking one show.
//
// NOT inside the in-flight marker, which is where #2765's own text put it. Measured, not assumed
// (L82): `mac/scripts/prep-run.sh` does `: > "$MARKER"` at startup, which truncates it, so anything the
// app wrote there is destroyed within seconds. The heartbeat itself (`heartbeat_touch_or_stop`,
// `run-heartbeat.sh`) uses `touch` and WOULD have preserved it, so only the startup line is the problem.
// A separate slot-scoped file needs no change to the runner and keeps liveness (the marker's mtime) and
// content (the keys) in files whose lifecycles differ.
//
// The READ returns THREE cases and never a boolean. Four states would otherwise collapse into "excludes
// nothing", which is the fail-OPEN direction on the one control that stops two paid runs colliding
// (L105, L42, L11): no live run; a live run holding keys; a covers file that cannot be read while its
// slot is LIVE; and a live slot whose covers have not been written yet. The last two are refusals, not
// permission.
@MainActor
@Suite("A run publishes which shows it holds (#3010)")
struct RunCoverageTests {

    private func dir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func makeLive(_ slot: RunSlot, in support: URL) throws {
        try Data().write(to: slot.markerURL(in: support))
    }

    // MARK: - The path belongs to RunSlot like every other one

    @Test func eachSlotOwnsItsOwnCoversFile() {
        let base = URL(fileURLWithPath: "/")
        #expect(RunSlot.prep.coversURL(in: base).lastPathComponent == "prep-covers.json")
        #expect(RunSlot.check.coversURL(in: base).lastPathComponent == "check-covers.json")
        #expect(RunSlot.prep.coversURL(in: base) != RunSlot.check.coversURL(in: base),
                "one covers file for both slots is the defect this exists to stop")
    }

    // The collision check is DERIVED from `allPaths` (L96), so a path missing from it is exempt from the
    // very guard meant to catch it.
    @Test func theCoversFileIsInTheDerivedPathList() {
        let paths = RunSlot.prep.allPaths(in: URL(fileURLWithPath: "/"))
        #expect(paths["covers"] == RunSlot.prep.coversURL(in: URL(fileURLWithPath: "/")),
                "allPaths does not name the covers file, so nothing derived from it can check the covers file")
    }

    // MARK: - The three cases

    @Test func aSlotWithNoLiveRunHoldsNothing() throws {
        let d = dir()
        // No marker at all. Not a refusal: nothing is running, so nothing is held.
        #expect(RunCoverage.read(slot: .check, in: d, now: Date()) == .noLiveRun)
    }

    @Test func aDeadSlotHoldsNothingEvenWithACoversFileLyingThere() throws {
        let d = dir()
        try RunCoverage.write(keys: ["a", "b"], slot: .check, in: d)
        // A covers file with NO live marker is a leftover from a run that ended. It must not exclude
        // anything, or last night's run silently holds shows for ever (L121, L68).
        #expect(RunCoverage.read(slot: .check, in: d, now: Date()) == .noLiveRun)
    }

    // THE POSITIVE CONTROL for both of the above, in the same fixture: the same file, with the slot LIVE,
    // really does hold its keys. Without it the two assertions above pass on a mechanism that never works.
    @Test func aLiveSlotHoldsExactlyTheKeysItPublished() throws {
        let d = dir()
        try RunCoverage.write(keys: ["a", "b"], slot: .check, in: d)
        try makeLive(.check, in: d)
        #expect(RunCoverage.read(slot: .check, in: d, now: Date()) == .holds(["a", "b"]))
    }

    @Test func aLiveSlotWhoseCoversCannotBeReadIsARefusalNotPermission() throws {
        let d = dir()
        try Data("this is not json".utf8).write(to: RunSlot.check.coversURL(in: d))
        try makeLive(.check, in: d)
        #expect(RunCoverage.read(slot: .check, in: d, now: Date()) == .unreadable,
                "an unreadable covers file under a LIVE run must refuse; treating it as 'holds nothing' is fail-open on the control that stops two paid runs taking one show")
    }

    @Test func aLiveSlotThatHasNotPublishedYetIsAlsoARefusal() throws {
        let d = dir()
        try makeLive(.check, in: d)
        // Marker live, covers absent: the launch is between taking its lock and publishing. That is a
        // real state and it is NOT "holds nothing".
        #expect(RunCoverage.read(slot: .check, in: d, now: Date()) == .unreadable)
    }

    // MARK: - Round trip

    @Test func theKeysComeBackExactlyAsWritten() throws {
        let d = dir()
        let keys: Set<String> = ["show one|2026-09-01|venue", "show two|2026-09-02|venue"]
        try RunCoverage.write(keys: keys, slot: .prep, in: d)
        try makeLive(.prep, in: d)
        #expect(RunCoverage.read(slot: .prep, in: d, now: Date()) == .holds(keys))
    }

    // The two slots do not answer for each other, which is the whole reason the file is slot-scoped.
    @Test func oneSlotsCoversNeverAnswerForTheOther() throws {
        let d = dir()
        try RunCoverage.write(keys: ["a"], slot: .check, in: d)
        try makeLive(.check, in: d)
        #expect(RunCoverage.read(slot: .prep, in: d, now: Date()) == .noLiveRun)
    }

    @Test func removingTheCoversLeavesTheSlotHoldingNothing() throws {
        let d = dir()
        try RunCoverage.write(keys: ["a"], slot: .prep, in: d)
        try makeLive(.prep, in: d)
        #expect(RunCoverage.read(slot: .prep, in: d, now: Date()) == .holds(["a"]))
        RunCoverage.clear(slot: .prep, in: d)
        // Marker still live, covers gone: the REFUSAL case, not "holds nothing". This is why the runner's
        // trap must remove the covers file AFTER the marker and never before it (#3010).
        #expect(RunCoverage.read(slot: .prep, in: d, now: Date()) == .unreadable)
    }
}
