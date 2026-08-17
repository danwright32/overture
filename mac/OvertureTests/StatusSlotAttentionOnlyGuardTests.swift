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

    // Every branch here is shortfall/failure-only (ReplyClassifyRunSummary is scoped to the drop count
    // on purpose, never a routine "N replies classified" tally), so all of them post at .warning, the
    // same tier as the scout's own unattended-run warning, so none can be silently overwritten by a
    // later routine .info write.
    //
    // #2873: this used to pin the COUNT of status.set calls at 2, which is a proxy for the rule rather
    // than the rule (L63): it failed when a third, genuinely-warning branch arrived (a results file that
    // cannot be read), and it would have passed on a routine .info write that replaced one of the two.
    // It now asserts the invariant, that EVERY write from this function is a warning, and names the
    // three sentences separately.
    @Test func ingestReplyClassificationsPostsEveryBranchAtWarningPriority() throws {
        let body = try SourceGuard.functionBody(named: "ingestReplyClassifications", in: rootView)
        let writes = body.components(separatedBy: "status.set(").dropFirst()
        #expect(!writes.isEmpty)
        for write in writes {
            #expect(write.prefix(220).contains("priority: .warning"))
        }
        #expect(body.contains("\"Reply-classify results couldn't save. Try again.\", priority: .warning"))
        #expect(body.contains("status.set(message, priority: .warning)"))
        // The unreadable-file branch, whose silence is what #2873 cost.
        #expect(body.contains("ReplyClassifyRunSummary.unreadableMessage(reason: reason), priority: .warning"))
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
