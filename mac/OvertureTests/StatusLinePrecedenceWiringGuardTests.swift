import Testing
import Foundation

// #1047: the precedence rule is only real if every writer of the center status slot actually routes
// through StatusLine.set, and the auto scout's quiet line is the one that must carry .warning. The pure
// rule can be perfect while the wire is cut (#887: a guard and its wiring are two separate claims), so
// this source guard pins the wiring the pure StatusLineTests cannot see.
@Suite("Status line precedence wiring (#1047)")
struct StatusLinePrecedenceWiringGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var rootView: String { source("Overture/App/RootView.swift") }

    // The slot is a StatusLine, not a bare String, so writers cannot bypass the precedence rule.
    @Test func theSlotIsAStatusLine() {
        #expect(rootView.contains("@State private var status = StatusLine()"))
    }

    // The unattended scout's quiet line is written as a warning: an informational write cannot erase it.
    @Test func theQuietLineIsWrittenAsAWarning() {
        #expect(rootView.contains("status.set(line, priority: .warning)"))
    }

    // Every write of the slot goes through status.set, so nothing assigns the raw text and skips the
    // precedence check. (The two `.statusMessage(for:` references are calls into summary types, not the
    // slot, so they carry no ` = ` assignment and are not matched here.)
    @Test func nothingAssignsTheSlotDirectly() {
        #expect(!rootView.isEmpty)
        #expect(!rootView.contains("statusMessage ="))
    }
}
