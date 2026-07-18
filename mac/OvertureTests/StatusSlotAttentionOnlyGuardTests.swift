import Testing
import Foundation

// Dan (2026-07-18): the toolbar's shared status slot had turned into a nagging pill ("Prep: 2
// drafted") that didn't earn its spot next to an unattended scout's real warning. RootView's
// writers into that slot (ingestPrep, ingestReplyClassifications, syncOmniFocus) touch live
// singletons (ModelContext, AppleScriptOmniFocusClient) and aren't unit-testable in isolation,
// the same reason OmniFocusSyncLivenessGuardTests scans RootView's raw source instead of calling
// these functions directly.
@Suite("Only what needs Dan's attention reaches the shared status slot")
struct StatusSlotAttentionOnlyGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    // The routine "N due, N created" receipt after a manual "Sync now" is gone: the OmniFocus
    // toolbar menu already shows "last synced" when opened, and a routine tally doesn't belong
    // beside the scout's own unattended-run warning.
    @Test func syncOmniFocusNoLongerPostsARoutineReceipt() throws {
        let body = try SourceGuard.functionBody(named: "syncOmniFocus", in: rootView)
        #expect(!body.contains("status.set("))
    }

    // Both branches here are shortfall/failure-only already (ReplyClassifyRunSummary is scoped to
    // the drop count on purpose, never a routine "N replies classified" tally), so both are
    // promoted to .warning, the same tier as the scout's own unattended-run warning, so neither
    // can be silently overwritten by a later routine .info write.
    @Test func ingestReplyClassificationsPostsBothBranchesAtWarningPriority() throws {
        let body = try SourceGuard.functionBody(named: "ingestReplyClassifications", in: rootView)
        let statusSetCalls = body.components(separatedBy: "status.set(").count - 1
        #expect(statusSetCalls == 2)
        #expect(body.contains("\"Reply-classify results couldn't save. Try again.\", priority: .warning"))
        #expect(body.contains("status.set(message, priority: .warning)"))
    }

    // ingestPrep now calls PrepRunSummary.attentionMessage (concerns only), not the old
    // statusMessage (which also carried the routine "N drafted" tally), and posts it at .warning
    // so it can't be silently overwritten by a later routine .info write either.
    @Test func ingestPrepUsesAttentionMessageAtWarningPriority() throws {
        let body = try SourceGuard.functionBody(named: "ingestPrep", in: rootView)
        #expect(body.contains("PrepRunSummary.attentionMessage("))
        #expect(!body.contains("PrepRunSummary.statusMessage("))
        #expect(body.contains("status.set(message, priority: .warning)"))
    }
}
