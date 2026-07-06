import Testing
import Foundation

// Regression guard for #499: DismissedView.restore swallows a context.save() failure with a
// bare try?, so restoring a prospect to the queue could silently fail to persist while still
// telling Dan it worked. Fixed to surface the failure via ActionFeedback instead of the normal
// "restored" acknowledgment. Nothing else stops a future edit from quietly reverting this back
// to a bare try?, so this scans the function body specifically for that one forbidden shape
// reappearing.
@Suite("DismissedView restore save guard")
struct DismissedViewRestoreSaveGuardTests {

    private static let forbidden = "try? context.save()"

    @Test func restoreNeverRevertsToSilentSave() throws {
        let dismissedView = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture/UI/DismissedView.swift")
        let src = try String(contentsOf: dismissedView, encoding: .utf8)

        let body = try SourceGuard.functionBody(named: "restore", in: src)
        #expect(!body.contains(Self.forbidden),
                "restore reintroduced a bare try? context.save(): a save failure must surface via ActionFeedback, not fail silently (#499).")
    }
}
