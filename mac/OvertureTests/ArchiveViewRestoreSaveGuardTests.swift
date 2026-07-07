import Testing
import Foundation

// Regression guard for #499 (originally on DismissedView, moved here with the view): restore
// mutates a prospect on Dan's action and must never swallow a context.save() failure with a bare
// try?, so a restore could silently fail to persist while still telling Dan it worked.
@Suite("ArchiveView restore save guard")
struct ArchiveViewRestoreSaveGuardTests {
    private static let forbidden = "try? context.save()"

    @Test func restoreNeverRevertsToSilentSave() throws {
        let src = SourceGuardHelper.source("Overture/UI/ArchiveView.swift")
        #expect(!src.isEmpty)
        let body = try SourceGuard.functionBody(named: "restore", in: src)
        #expect(!body.contains(Self.forbidden),
                "restore reintroduced a bare try? context.save(): a save failure must surface via ActionFeedback, not fail silently (#499).")
        #expect(body.contains("saveOrWarn("),
                "restore no longer calls saveOrWarn(org:feedback:); a save failure path must go through the shared helper (#618).")
    }
}
