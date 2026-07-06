import Testing
import Foundation

// Regression guard for #499: ReconcileScheduler.reconcileBookings swallows a context.save()
// failure with a bare try?, so a booking detected while Dan is away could silently fail to
// persist with no signal, distinct from the "nothing was due" no-op case #285 already handles.
// Fixed to report the failure back through ReconcileSummary.saveFailed, surfaced via both the
// manual reconcile ack and the while-away notification. Nothing else stops a future edit from
// quietly reverting this back to a bare try?, so this scans the function body specifically for
// that one forbidden shape reappearing.
@Suite("ReconcileScheduler save guard")
struct ReconcileSchedulerSaveGuardTests {

    private static let forbidden = "try? context.save()"

    @Test func reconcileBookingsNeverRevertsToSilentSave() throws {
        let reconcileScheduler = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OvertureTests/
            .deletingLastPathComponent()   // mac/
            .appendingPathComponent("Overture/App/ReconcileScheduler.swift")
        let src = try String(contentsOf: reconcileScheduler, encoding: .utf8)

        let body = try SourceGuard.functionBody(named: "reconcileBookings", in: src)
        #expect(!body.contains(Self.forbidden),
                "reconcileBookings reintroduced a bare try? context.save(): a save failure must surface via ReconcileSummary.saveFailed, not fail silently (#499).")
    }
}
