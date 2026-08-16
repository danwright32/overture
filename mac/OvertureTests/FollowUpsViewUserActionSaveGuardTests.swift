import Testing
import Foundation

// Regression guard for #499: these FollowUpsView handlers each mutate a prospect on Dan's
// action (snooze, set/confirm conversation state) and swallow a context.save() failure with a
// bare try?, so the change could silently fail to persist with no signal. Fixed to surface the
// failure via ActionFeedback instead. Nothing else stops a future edit from quietly reverting
// one of these back to a bare try?, so this scans each function body specifically for that one
// forbidden shape reappearing.
@Suite("FollowUpsView user-action save guard")
struct FollowUpsViewUserActionSaveGuardTests {

    // #2397: `remindLater`, `setState` and `confirm` went with the conversation-state track. These are the
    // user actions left on this sheet, and each must still surface a save failure rather than swallow it.
    // #2710: `closeOut` stood here. It was the closing note's "not sent but also done" action, and it
    // went with the note: there is nothing to decline to send any more.
    private static let guardedFunctions = ["standDown", "pushOut"]
    private static let forbidden = "try? context.save()"

    @Test func userActionHandlersNeverRevertToSilentSave() throws {
        let followUpsView = RepoRoot.mac
            .appendingPathComponent("Overture/UI/FollowUpsView.swift")
        let src = try String(contentsOf: followUpsView, encoding: .utf8)

        for name in Self.guardedFunctions {
            let body = try SourceGuard.functionBody(named: name, in: src)
            #expect(!body.contains(Self.forbidden),
                    "\(name) reintroduced a bare try? context.save(): a save failure must surface via ActionFeedback, not fail silently (#499).")
        }
    }
}
