import Testing
import Foundation

// Regression guard for #477 / PR #500: QueueView.performSend and sendReply once swallowed a
// post-send context.save() failure with a bare try?, so a send could succeed while the local
// record silently failed to persist, with no signal to Dan. PR #500 fixed both to surface the
// failure via ActionFeedback instead. Nothing else stops a future edit from quietly reverting
// either do/catch block back to that bare try?, so this scans the two function bodies
// specifically (not the whole file, which still uses a bare try? context.save() legitimately
// in every other handler) for that one forbidden shape reappearing.
@Suite("Send receipt save guard")
struct SendReceiptSaveGuardTests {

    private static let guardedFunctions = ["sendReply", "performSend"]
    private static let forbidden = "try? context.save()"

    @Test func sendReplyAndPerformSendNeverRevertToSilentSave() throws {
        let queueView = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture/UI/QueueView.swift")
        let src = try String(contentsOf: queueView, encoding: .utf8)

        for name in Self.guardedFunctions {
            let body = try SourceGuard.functionBody(named: name, in: src)
            #expect(!body.contains(Self.forbidden),
                    "\(name) reintroduced a bare try? context.save() — a save failure after send must surface via ActionFeedback, not fail silently (#477).")
        }
    }
}
