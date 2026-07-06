import Testing
import Foundation

// Regression guard for #499: these RootView DEBUG-menu helpers (dev-only staging/reset tools,
// never run in a real Dan session) each swallow a context.save() failure with a bare try?, so a
// dev seed/reset could silently fail to persist. Fixed to surface the failure via the same
// statusMessage signal these helpers already use for their other failure paths (see
// debugSeedFromLive/debugSeedGmailFromLive in the same file). Nothing else stops a future edit
// from quietly reverting one of these back to a bare try?, so this scans each function body
// specifically for that one forbidden shape reappearing.
@Suite("RootView DEBUG save guard")
struct RootViewDebugSaveGuardTests {

    private static let guardedFunctions = [
        "debugClearDevData", "debugStageFirstAsSent", "debugStageReminderLead",
        "debugStageSelfSendLead", "debugStageMultiRecipientSelfSendLead", "debugClearDebugLeads",
    ]
    private static let forbidden = "try? context.save()"

    @Test func debugMenuHandlersNeverRevertToSilentSave() throws {
        let rootView = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture/App/RootView.swift")
        let src = try String(contentsOf: rootView, encoding: .utf8)

        for name in Self.guardedFunctions {
            let body = try SourceGuard.functionBody(named: name, in: src)
            #expect(!body.contains(Self.forbidden),
                    "\(name) reintroduced a bare try? context.save(): a save failure must surface via statusMessage, not fail silently (#499).")
        }
    }
}
