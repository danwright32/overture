import Testing

// #1036: AddLeadSheet's working state used its own LiveRunLabel, a second progress surface that did not
// get the source naming #1034 added to the scout takeover. It now renders the SAME RunProgressView,
// inline, so a lead read reads like a scout read and there is one progress surface, not two that drift.
//
// Guarded by source: the swap is view wiring (the behavior of the shared component and its live snapshot
// is unit-tested in RunProgressViewStateTests and RunProgressSnapshotTests). What this pins is that
// AddLeadSheet does not quietly grow a second, divergent progress view again.
@Suite("Add-a-lead shows the shared scout progress surface (#1036)")
struct AddLeadSharedProgressGuardTests {
    private var addLead: String { SourceGuardHelper.source("Overture/UI/AddLeadSheet.swift") }

    @Test func theWorkingStateRendersTheSharedComponent() {
        #expect(!addLead.isEmpty)
        // Reuses the scout takeover's component, in its reading phase, fed by the shared live snapshot.
        #expect(addLead.contains("RunProgressView(phase: .reading"))
        #expect(addLead.contains("RunProgressView.Snapshot.liveReading()"))
    }

    @Test func theWorkingStateNoLongerHasItsOwnLiveRunLabel() {
        // The whole point is one surface: a LiveRunLabel back in the working state would be the second
        // one returning.
        #expect(!addLead.contains("LiveRunLabel("))
    }
}
