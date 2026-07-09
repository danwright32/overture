import Testing
import Foundation

// #469: OmniFocus sync had no "syncing now / still working" state, unlike scout/prep/connect/send,
// which all show a LiveRunLabel driven by a start-time @State. A SourceGuard test (not runtime),
// matching this project's convention for RootView's UI-coupled functions: syncOmniFocus touches
// AppleScriptOmniFocusClient, a live singleton, so it isn't unit-testable in isolation, the same
// reason ToolbarConsolidationGuardTests scans RootView's raw source instead.
@Suite("OmniFocus sync liveness (#469)")
struct OmniFocusSyncLivenessGuardTests {
    private var rootView: String { SourceGuardHelper.source("Overture/App/RootView.swift") }

    @Test func syncOmniFocusStampsAStartTimeBeforeItRuns() throws {
        let body = try SourceGuard.functionBody(named: "syncOmniFocus", in: rootView)
        #expect(body.contains("omniFocusSyncStartedAt = Date()"))
    }

    // Must clear on the FAILURE path too, not only after a successful sync, or a sync that
    // errors would leave the toolbar stuck reading "Syncing…" forever. Checked by position: the
    // clear must sit after the catch block's own opening brace (and, since it's not inside an
    // early return, after the catch block's contents run too), not only inside the do branch
    // before catch is ever reached.
    @Test func syncOmniFocusClearsTheStartTimeOnBothSuccessAndFailurePaths() throws {
        let body = try SourceGuard.functionBody(named: "syncOmniFocus", in: rootView)
        guard let catchRange = body.range(of: "} catch {") else {
            Issue.record("expected a catch block in syncOmniFocus")
            return
        }
        let afterCatchOpens = body[catchRange.upperBound...]
        #expect(afterCatchOpens.contains("omniFocusSyncStartedAt = nil"))
    }

    @Test func theOmniFocusToolbarLabelShowsALiveRunLabelWhileSyncing() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("LiveRunLabel(base: \"Syncing\""))
        #expect(rootView.contains("if let since = omniFocusSyncStartedAt"))
    }
}
