import Testing
import Foundation

// #1015: the runner, not the model, owns the scout-extract progress count. Asking the model to
// self-report it invites it to be confidently wrong about the one thing the record exists to
// establish; on 2026-07-16 it simply never touched progress.json, and the toolbar sat at "0 of 20"
// through a run that was doing real work. The count is now derived by the SCRIPT, counting entries
// in the results file it already trusts (progress-watcher.sh's update_progress_from_results),
// exactly the same "the script knows, so the script should write it" reasoning as record_model in
// models.sh.
@Suite("The runner derives scout-extract progress itself (#1015)")
struct RunProgressWiringGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var runner: String { source("scripts/scout-extract-run.sh") }

    // Matches a real sourcing LINE, not merely a mention: every runner also names its lib files in
    // header comments, so a bare `contains("progress-watcher.sh")` would stay green even if the
    // actual `.` line were deleted (the exact mistake DetachedRunCeremonyGuardTests guards against
    // for runner-setup.sh).
    private func sources(_ libName: String, in body: String) -> Bool {
        body.split(separator: "\n").contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), t.contains(libName) else { return false }
            return t.hasPrefix(". ") || t.hasPrefix("source ")
        }
    }

    @Test func theRunnerSourcesTheProgressWatcher() {
        #expect(sources("progress-watcher.sh", in: runner))
    }

    // The real guard: the heartbeat loop (the only thing ticking while claude is alive) actually
    // CALLS the deriving function, not just sources the file that defines it. A guard and its wiring
    // are two separate claims (#887); sourcing the file proves nothing about whether it is used.
    // #1053 decoupled the cancel poll (a few seconds) from the 60s marker work, so the derive now sits
    // behind marker_due deeper in the loop body; the window is generous enough to reach it while still
    // ending well before the post-claude final derive hundreds of lines later.
    @Test func theHeartbeatLoopDerivesProgressEachTick() throws {
        // #2106: scoped to the heartbeat loop's own body rather than a fixed character
        // count after its header. The count was a proxy for the loop, and it expired the
        // way a proxy does: it had 34 characters of headroom, so an edit INSIDE the loop
        // pushed the guarded call past it while the wiring was untouched (L63).
        guard let nearby = SourceGuardHelper.between("while :; do", and: "done )", in: runner) else {
            Issue.record("heartbeat loop not found in scout-extract-run.sh")
            return
        }
        #expect(nearby.contains("update_progress_from_results"))
    }

    // A final derive after claude exits, so the last stretch of work between the previous tick and
    // process exit is not left showing a stale count once the run is over.
    @Test func aFinalDeriveRunsAfterClaudeExits() throws {
        guard let claudeRange = runner.range(of: "\"$CLAUDE\" -p") else {
            Issue.record("claude invocation not found in scout-extract-run.sh")
            return
        }
        let after = runner[claudeRange.upperBound...]
        #expect(after.contains("update_progress_from_results"))
    }

    // The model is never asked to touch progress.json itself anymore: an instruction it can simply
    // forget (as it did on 2026-07-16) is worth nothing once the script derives the truth on its own.
    @Test func theModelIsNeverAskedToUpdateProgressItself() {
        #expect(!runner.contains("Update $PROGRESS"))
        #expect(!runner.contains(#"Update \$PROGRESS"#))
    }
}

// #1427: the "~X remaining" estimate's two wires that no unit test can see, because they live inside the
// RootView view. The pure prediction and copy are proven in RunDurationHistoryTests/RunProgressViewStateTests;
// these guard that the view actually READS the history into the reading modal and WRITES it on completion.
@Suite("The Reading-calendars remaining estimate is wired in RootView (#1427)")
struct ReadingRemainingWiringGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var root: String { source("Overture/App/RootView.swift") }

    // The reading takeover feeds the learned history into the modal so it can predict; nothing else does.
    @Test func theReadingModalIsGivenTheDurationHistory() {
        #expect(root.contains("durationHistory: readingStartedAt != nil ? { RunDurationHistoryStore.load() }"))
    }

    // A normal completion records this run's pace. Guarded that record is reached only from the helper (so
    // the stall/timeout gate cannot be bypassed) and that the helper is called on the ingested path.
    @Test func aNormallyFinishedReadRecordsItsPace() {
        #expect(root.contains("RunDurationHistoryStore.record(sources: readingSourceCount, seconds: elapsed)"))
        #expect(root.contains("recordReadingRun(elapsed: readingElapsed)"))
    }

    // The gate that keeps a stalled/timed-out run out of the average: the helper refuses anything at or past
    // the reading timeout. Without this a hung 10-minute run would be recorded as real per-source pace.
    @Test func aStalledRunIsExcludedFromThePace() {
        #expect(root.contains("elapsed < RunTimeouts.scoutExtract"))
    }
}
