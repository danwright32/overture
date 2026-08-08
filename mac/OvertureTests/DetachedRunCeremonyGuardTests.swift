import Testing
import Foundation

// A detached runner inherits Dan's ~/.claude settings wholesale, which means his global Stop hooks
// (the session reflection, the issue review, the memory checkpoint) fire inside a headless run that
// has no reader. On 2026-07-16 that cost a real scout: the run wrote a SESSION REFLECTION into its
// own log, wrote a memory file into this project's store, never wrote the results file the app was
// waiting for, and exited 0. Every extracted show was lost.
//
// No CLI flag fixes it: --setting-sources drops the hooks but takes the dan-wright-brand-voice skill
// with them (prep and reply-classify draft Dan's actual emails with it), and --settings can only ADD
// hooks, never remove one. So the runners announce themselves with CLAUDE_DETACHED_RUN and the hooks
// in ~/.claude/hooks skip on it.
//
// Only HALF of that contract lives in this repo, so this is what can be guarded here: that the
// announcement is made, once, in the file every runner shares. The hook side is verified by hand
// (set the var, confirm the banner disappears; unset it, confirm it comes back).
@Suite("Detached runs suppress interactive ceremony (#1011)")
struct DetachedRunCeremonyGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var runnerSetup: String { source("scripts/lib/runner-setup.sh") }

    @Test func theSharedSetupExportsTheDetachedFlag() {
        #expect(runnerSetup.contains("export CLAUDE_DETACHED_RUN=1"))
    }

    // The flag is worth nothing unless the hooks can SEE it: a bare assignment is scoped to the
    // script, and claude's hook subprocesses would never inherit it.
    @Test func theFlagIsExportedNotJustAssigned() {
        #expect(!runnerSetup.contains("\nCLAUDE_DETACHED_RUN=1"))
    }

    // The real guard. Every script that drives a headless claude MUST come through the shared setup,
    // so a runner added later cannot quietly reintroduce this by pasting a `claude -p` call. Written
    // to FIND its instances rather than to check the three we happen to know about today: a careful
    // audit is exactly what missed them last time.
    //
    // Matches the SOURCING LINE, not the mention. Every runner also names runner-setup.sh in its
    // header comment, so a `contains("runner-setup.sh")` stays green with the actual `.` line
    // deleted; the first cut of this test did exactly that, and only a mutation caught it.
    @Test func everyClaudeRunnerSourcesTheSharedSetup() throws {
        let scripts = RepoRoot.mac
            .appendingPathComponent("scripts")

        let names = try FileManager.default.contentsOfDirectory(atPath: scripts.path)
            .filter { $0.hasSuffix(".sh") }
            .sorted()

        func sourcesSharedSetup(_ body: String) -> Bool {
            body.split(separator: "\n").contains { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard !t.hasPrefix("#"), t.contains("runner-setup.sh") else { return false }
                return t.hasPrefix(". ") || t.hasPrefix("source ")
            }
        }

        var drivers: [String] = []
        for name in names {
            let body = try String(contentsOf: scripts.appendingPathComponent(name), encoding: .utf8)
            guard body.contains("\"$CLAUDE\" -p") || body.contains("$CLAUDE -p") else { continue }
            drivers.append(name)
            #expect(sourcesSharedSetup(body),
                    "\(name) drives a headless claude but never sources runner-setup.sh, so it does not announce itself as detached and Dan's Stop hooks will fire inside it.")
        }

        // If this trips, a runner was renamed or removed: re-point the guard rather than deleting it.
        #expect(drivers.contains("scout-extract-run.sh"))
        #expect(drivers.contains("prep-run.sh"))
        #expect(drivers.contains("reply-classify-run.sh"))
    }
}
