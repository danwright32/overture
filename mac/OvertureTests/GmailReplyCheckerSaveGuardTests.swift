import Testing
import Foundation

// Regression guard for #499: GmailReplyChecker.markReplies swallows a context.save() failure
// with a bare try?, so a detected reply could silently fail to persist with no signal. Fixed to
// report the failure back through its Bool return, threaded up through checkReplies into
// ReconcileScheduler's ReconcileSummary.saveFailed. Nothing else stops a future edit from
// quietly reverting this back to a bare try?, so this scans the function body specifically for
// that one forbidden shape reappearing.
@Suite("GmailReplyChecker save guard")
struct GmailReplyCheckerSaveGuardTests {

    private static let forbidden = "try? context.save()"

    @Test func markRepliesNeverRevertsToSilentSave() throws {
        let gmailReplyChecker = RepoRoot.mac
            .appendingPathComponent("Overture/Integration/GmailReplyChecker.swift")
        let src = try String(contentsOf: gmailReplyChecker, encoding: .utf8)

        let body = try SourceGuard.functionBody(named: "markReplies", in: src)
        #expect(!body.contains(Self.forbidden),
                "markReplies reintroduced a bare try? context.save(): a save failure must surface via its return value, not fail silently (#499).")
    }
}
