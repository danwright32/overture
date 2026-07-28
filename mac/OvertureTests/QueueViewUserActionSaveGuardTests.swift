import Testing
import Foundation

// Regression guard for #499: these QueueView handlers each mutate a prospect on Dan's action
// and swallow a context.save() failure with a bare try?, so a keep/dismiss, draft edit, manual
// outcome, or booking confirm could silently fail to persist with no signal. Fixed to surface
// the failure via ActionFeedback instead. Nothing else stops a future edit from quietly
// reverting one of these back to a bare try?, so this scans each function body specifically for
// that one forbidden shape reappearing.
@Suite("QueueView user-action save guard")
struct QueueViewUserActionSaveGuardTests {

    private static let guardedFunctions = [
        "toggleVoiceLearning", "dismissReply", "markContact", "dismissContactReply", "dismissContactBounce",
        "draftReply", "editReplyDraft", "copyReply", "setStatus", "saveDraft",
        "correctClassification", "setRecipientConversationState",
        "confirmRecipientConversationState", "remindRecipientLater", "confirmBooking",
        "dismissBookingSuggestion", "rejectBooking", "setLostReason",
    ]
    private static let forbidden = "try? context.save()"

    @Test func userActionHandlersNeverRevertToSilentSave() throws {
        let queueView = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture/UI/ProspectMutations.swift")
        let src = try String(contentsOf: queueView, encoding: .utf8)

        for name in Self.guardedFunctions {
            let body = try SourceGuard.functionBody(named: name, in: src)
            #expect(!body.contains(Self.forbidden),
                    "\(name) reintroduced a bare try? context.save(): a save failure must surface via ActionFeedback, not fail silently (#499).")
        }
    }
}
