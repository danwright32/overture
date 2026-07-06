import Testing
import Foundation

// Regression guard for #499: SendService.releaseDueSends swallows a context.save() failure with
// a bare try?, so a drip-sent email's local record could silently fail to persist with no
// signal. Currently has no production caller (#426), but is exercised by unit tests and should
// stay correct so a future caller doesn't inherit a silent failure mode. Fixed to set
// Outcome.saveFailed. Nothing else stops a future edit from quietly reverting this back to a
// bare try?, so this scans the function body specifically for that one forbidden shape
// reappearing.
@Suite("SendService releaseDueSends save guard")
struct SendServiceReleaseDueSendsSaveGuardTests {

    private static let forbidden = "try? context.save()"

    @Test func releaseDueSendsNeverRevertsToSilentSave() throws {
        let sendService = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture/Integration/SendService.swift")
        let src = try String(contentsOf: sendService, encoding: .utf8)

        let body = try SourceGuard.functionBody(named: "releaseDueSends", in: src)
        #expect(!body.contains(Self.forbidden),
                "releaseDueSends reintroduced a bare try? context.save(): a save failure must surface via Outcome.saveFailed, not fail silently (#499).")
    }
}
