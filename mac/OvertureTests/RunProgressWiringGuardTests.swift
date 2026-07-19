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
        guard let heartbeatRange = runner.range(of: "while :; do") else {
            Issue.record("heartbeat loop not found in scout-extract-run.sh")
            return
        }
        let nearby = runner[heartbeatRange.lowerBound...].prefix(800)
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
