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

    @Test func syncOmniFocusClearsTheStartTimeWhenItFinishes() throws {
        let body = try SourceGuard.functionBody(named: "syncOmniFocus", in: rootView)
        #expect(body.contains("omniFocusSyncStartedAt = nil"))
    }

    @Test func theOmniFocusToolbarLabelShowsALiveRunLabelWhileSyncing() {
        #expect(!rootView.isEmpty)
        #expect(rootView.contains("LiveRunLabel(base: \"Syncing\""))
        #expect(rootView.contains("if let since = omniFocusSyncStartedAt"))
    }
}
