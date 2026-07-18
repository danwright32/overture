import Testing
import Foundation

// #1020: every detached run accounts for the work it was queued to do, at whichever layer owns that
// check, and this test finds the runners by DISCOVERY so a future fourth one cannot quietly skip it.
//
// The runners answer the same question (did everything I was given come back?) two ways, and the split is
// deliberate, not drift:
//
//   scout-extract: SHELL-side (ensure_every_queued_source_reported, lib/results-guard.sh). Scout's results
//     are per-source and latch a content hash, so synthesizing a not_read entry for a source nobody read
//     is meaningful and load-bearing. The check lives in the script, before the app ever sees the file.
//
//   prep and reply-classify: APP-side (HandoffShortfall.missingKeys, computed in their importer at ingest).
//     Their results have no per-item failure worth synthesizing: an invented empty prep result would CLAIM
//     the run researched a show and found nobody, about a show nobody ever looked at (#868). So the app
//     compares the queue it wrote against what came back, and never fabricates.
//
// A single shared piece across all three would be WRONG (it would force scout to stop synthesizing, or
// prep/reply to start). What must be true instead is that NONE of them silently lacks the check. That is
// what this asserts, by discovering the runner scripts rather than naming them by hand: the exact template
// StaleResultsGuardTests.everyClaudeRunnerDiscardsItsPreviousResultsFirst set for a shared mechanism that
// has to stay honestly shared.
@Suite("Every detached runner accounts for its queued work (#1020)")
struct HandoffCompletenessTests {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // OvertureTests/
        .deletingLastPathComponent()   // mac/
        .deletingLastPathComponent()   // repo root

    // Scout's completeness check is shell-side: the runner script itself calls this before it exits.
    private static let shellSideCheck = "ensure_every_queued_source_reported"
    // Prep and reply-classify's is app-side: their importer computes this at ingest.
    private static let appSideCheck = "HandoffShortfall.missingKeys"

    @Test func everyClaudeRunnerHasACompletenessCheckAtSomeLayer() throws {
        let scriptsDir = Self.repoRoot.appendingPathComponent("mac/scripts")
        let names = try FileManager.default.contentsOfDirectory(atPath: scriptsDir.path)
            .filter { $0.hasSuffix(".sh") }
            .sorted()

        var drivers: [String] = []
        for name in names {
            let body = try String(contentsOf: scriptsDir.appendingPathComponent(name), encoding: .utf8)
            guard body.contains("\"$CLAUDE\" -p") || body.contains("$CLAUDE -p") else { continue }
            drivers.append(name)

            // Layer 1: scout does it in the shell, in the script itself.
            if body.contains(Self.shellSideCheck) { continue }

            // Layer 2: otherwise the app must do it at ingest, in this runner's importer.
            let importer = Self.importerName(forRunner: name)
            let importerPath = Self.repoRoot
                .appendingPathComponent("mac/Overture/Persistence")
                .appendingPathComponent(importer)
            guard let importerBody = try? String(contentsOf: importerPath, encoding: .utf8) else {
                Issue.record("""
                    \(name) drives a headless claude but has neither a shell-side completeness check \
                    (\(Self.shellSideCheck)) nor an importer at Persistence/\(importer) to carry an \
                    app-side one. A run that comes back short would drop items in silence (#1020).
                    """)
                continue
            }
            #expect(importerBody.contains(Self.appSideCheck), """
                \(name) has no shell-side completeness check, and its importer \(importer) never computes \
                \(Self.appSideCheck), so a run that answers fewer items than it was queued drops the rest \
                silently (#876/#1018/#1020).
                """)
        }

        // A broken glob that matched nothing would pass every loop above vacuously. Anchor on the runners
        // we know exist so a rename or a move re-points this guard instead of quietly disarming it.
        #expect(drivers.contains("scout-extract-run.sh"))
        #expect(drivers.contains("prep-run.sh"))
        #expect(drivers.contains("reply-classify-run.sh"))
    }

    // "prep-run.sh" -> "PrepImporter.swift", "reply-classify-run.sh" -> "ReplyClassifyImporter.swift".
    private static func importerName(forRunner script: String) -> String {
        let stem = script.replacingOccurrences(of: "-run.sh", with: "")
        let camel = stem.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
        return "\(camel)Importer.swift"
    }
}
