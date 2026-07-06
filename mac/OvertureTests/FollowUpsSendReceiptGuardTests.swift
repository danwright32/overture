import Testing
import Foundation

// Regression guard for #499: FollowUpsView.performNudge and performConversationNudge send a
// follow-up/nudge over Gmail, then swallow the local receipt of that fact with a bare try?
// context.save(), the same risk #477 fixed in QueueView.performSend/sendReply. Nothing else
// stops a future edit from quietly reverting either do/catch block back to that bare try?, so
// this scans the two function bodies specifically (not the whole file, which still uses a bare
// try? context.save() legitimately in every other handler) for that one forbidden shape
// reappearing.
@Suite("FollowUps send receipt save guard")
struct FollowUpsSendReceiptGuardTests {

    private static let guardedFunctions = ["performNudge", "performConversationNudge"]
    private static let forbidden = "try? context.save()"

    @Test func performNudgeAndPerformConversationNudgeNeverRevertToSilentSave() throws {
        let followUpsView = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture/UI/FollowUpsView.swift")
        let src = try String(contentsOf: followUpsView, encoding: .utf8)

        for name in Self.guardedFunctions {
            let body = try SourceGuard.functionBody(named: name, in: src)
            #expect(!body.contains(Self.forbidden),
                    "\(name) reintroduced a bare try? context.save(): a save failure after a send must surface via ActionFeedback, not fail silently (#499).")
        }
    }
}
