import Testing
import Foundation

// #1699 part 3: the note's RULE and its WORDING are proven behaviorally in SelfBookingWorkableNightTests
// (both the pure gap and the QueueModel wiring under it). What no running test reaches is the last hop:
// that the card actually draws it. Computed and never rendered, the whole feature would be invisible
// while every one of those tests stayed green, which is the "built is not wired" failure (L3), and a
// SwiftUI view this size is not unit-testable in isolation (the same reason FocusedStageWiringGuardTests
// and MastheadGuardTests scan source).
//
// Two things are guarded, because two different edits would each silently undo the feature: the row must
// read the note at all, and it must stay in the ELSE of the warning. Promoted to its own `if`, a night
// holding both a tight clash and a workable show would stack a reassuring line under an actionable one.
@Suite("The workable same-night note reaches the card (#1699)")
struct WorkableSameNightNoteWiringGuardTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    private func rowBody() -> String? {
        SourceGuardHelper.propertyBody(
            "@ViewBuilder private func prospectRow(_ item: QueueItem, data: RenderData, isDeparting: Bool) -> some View {",
            in: queueView)
    }

    @Test func theRowAsksForTheNoteAndDrawsIt() throws {
        let body = try #require(rowBody(), "expected prospectRow's body")
        #expect(body.contains("QueueModel.selfBookingWorkableNote(for: item, among: data.items)"))
        #expect(body.contains("Text(workableNote)"))
    }

    // The warning wins: the note is drawn in the warning's else-branch, never beside it.
    @Test func theNoteOnlyDrawsWhenTheWarningDidNot() throws {
        let body = try #require(rowBody(), "expected prospectRow's body")
        #expect(body.contains("} else if let workableNote {"))
    }

    // Gold is reserved for what Dan can act on, and this line asks for nothing. A guard rather than a
    // comment because the neighbouring warning IS gold, so the two are one copy-paste apart.
    @Test func theNoteIsNotStyledAsAWarning() throws {
        let body = try #require(rowBody(), "expected prospectRow's body")
        let noteSlice = try #require(body.range(of: "} else if let workableNote {").map {
            String(body[$0.lowerBound...].prefix(400))
        }, "expected the note's own branch")
        #expect(!noteSlice.contains("OVColor.gold"))
        #expect(!noteSlice.contains("calendar.badge.exclamationmark"))
        #expect(noteSlice.contains(".foregroundStyle(.secondary)"))
    }
}
