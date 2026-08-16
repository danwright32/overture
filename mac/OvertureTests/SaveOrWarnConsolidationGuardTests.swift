import Testing
import Foundation

// Regression guard for #622: #618 (PR #621) collapsed 21 hand-rolled
// `do { try context.save() } catch { feedback.acknowledge(ActionAck.saveFailed(org:), tone: .warning) }`
// blocks across QueueView, FollowUpsView, and DismissedView into the single
// `ModelContext.saveOrWarn(org:feedback:)` helper. The existing #499 guards
// (QueueViewUserActionSaveGuardTests, FollowUpsViewUserActionSaveGuardTests,
// DismissedViewRestoreSaveGuardTests) only catch a silent bare `try? context.save()`
// reappearing, not a hand-rolled do/catch that would still warn correctly but defeat the
// consolidation. This scans the same handler functions for that specific forbidden shape
// reappearing instead of a call to saveOrWarn.
@Suite("saveOrWarn consolidation guard (#618)")
struct SaveOrWarnConsolidationGuardTests {

    private static let forbidden = "ActionAck.saveFailed(org:"

    private static let queueViewFunctions = [
        "toggleVoiceLearning", "dismissReply", "markContact", "dismissContactReply", "dismissContactBounce",
        "draftReply", "editReplyDraft", "copyReply", "setStatus", "saveDraft",
        "correctClassification", "recordOutcome", "reopenOutcome",
        "remindRecipientLater", "confirmBooking",
        "dismissBookingSuggestion", "rejectBooking", "setLostReason",
    ]
    // #2710: `closeOut` went with the closing note it declined to send.
    private static let followUpsViewFunctions = ["standDown", "pushOut"]
    private static let dismissedViewFunctions = ["restore"]

    private func assertHandlersUseSaveOrWarn(
        file relativeFromMac: String, functions: [String],
        sourceFile: StaticString = #filePath
    ) throws {
        let src = SourceGuardHelper.source(relativeFromMac, file: sourceFile)
        #expect(!src.isEmpty)
        for name in functions {
            let body = try SourceGuard.functionBody(named: name, in: src)
            #expect(!body.contains(Self.forbidden),
                    "\(name) reintroduced a hand-rolled do/catch around context.save() instead of calling saveOrWarn(org:feedback:), re-duplicating the block #618 collapsed.")
            #expect(body.contains("saveOrWarn("),
                    "\(name) no longer calls saveOrWarn(org:feedback:); a save-failure path must go through the shared helper, not its own do/catch.")
        }
    }

    @Test func queueViewHandlersUseSaveOrWarn() throws {
        try assertHandlersUseSaveOrWarn(file: "Overture/UI/ProspectMutations.swift", functions: Self.queueViewFunctions)
    }

    @Test func followUpsViewHandlersUseSaveOrWarn() throws {
        try assertHandlersUseSaveOrWarn(file: "Overture/UI/FollowUpsView.swift", functions: Self.followUpsViewFunctions)
    }

    @Test func dismissedViewHandlerUsesSaveOrWarn() throws {
        try assertHandlersUseSaveOrWarn(file: "Overture/UI/ArchiveView.swift", functions: Self.dismissedViewFunctions)
    }
}
