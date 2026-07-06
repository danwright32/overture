import Testing
import Foundation

// Regression guard for #499: ScoutService.runScout and ScoutService.apply each swallow a
// context.save() failure with a bare try?, so a full scout run (extract, classify, upsert) could
// silently fail to persist with no signal, distinct from Outcome.warning's existing feed/client
// warnings. Fixed to set Outcome.saveFailed, surfaced through RootView's existing
// warningMessage flow. Nothing else stops a future edit from quietly reverting either back to a
// bare try?, so this scans each function body specifically for that one forbidden shape
// reappearing.
@Suite("ScoutService save guard")
struct ScoutServiceSaveGuardTests {

    private static let guardedFunctions = ["runScout", "apply"]
    private static let forbidden = "try? context.save()"

    @Test func runScoutAndApplyNeverRevertToSilentSave() throws {
        let scoutService = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture/Integration/ScoutService.swift")
        let src = try String(contentsOf: scoutService, encoding: .utf8)

        for name in Self.guardedFunctions {
            let body = try SourceGuard.functionBody(named: name, in: src)
            #expect(!body.contains(Self.forbidden),
                    "\(name) reintroduced a bare try? context.save(): a save failure must surface via Outcome.saveFailed, not fail silently (#499).")
        }
    }
}
