import Testing
import Foundation

// Dan (2026-07-18): the "too far" location filter lived in the window's own NSToolbar, which macOS
// keeps visible even while Archive/Sources/Days off/Patterns/Voice guidance are open as sheets over
// the same window, so it read as clutter that showed up "everywhere" rather than only on the queue
// it actually filters. QueueView is a SwiftUI view and isn't unit-testable in isolation, the same
// reason OmniFocusSyncLivenessGuardTests scans raw source instead of rendering the view, so this
// guards the shape of the source rather than runtime output.
@Suite("The location filter lives in the queue, not the window toolbar")
struct LocationFilterInQueueOnlyGuardTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    @Test func thereIsNoStandaloneTooFarToolbarAnymore() {
        #expect(!queueView.contains("tooFarToolbar"))
        #expect(!queueView.contains("location.slash"))
    }

    // QueueFilterBar only ever renders inside `if pipeline == .toSend`, so putting the chip there
    // (rather than back in a `.toolbar` modifier) is what makes it show only while Dan is actually
    // looking at the To send queue.
    @Test func theTooFarChipLivesInsideQueueFilterBar() {
        guard let body = SourceGuardHelper.propertyBody(
            "private struct QueueFilterBar: View {", in: queueView) else {
            Issue.record("expected to find QueueFilterBar's body")
            return
        }
        #expect(body.contains("tooFarCount"))
        #expect(body.contains("showTooFarOnly"))
        #expect(body.contains("QueueModel.chipIsShown(count: tooFarCount, showingOnly: showTooFarOnly)"))
    }

    @Test func pipelineContentOnlyBuildsTheFilterBarForToSend() {
        guard let ifRange = queueView.range(of: "if pipeline == .toSend {") else {
            Issue.record("expected pipelineContent's `if pipeline == .toSend` branch")
            return
        }
        let afterIf = queueView[ifRange.upperBound...]
        guard let elseRange = afterIf.range(of: "} else {") else {
            Issue.record("expected the matching `} else {` for the reached-out branch")
            return
        }
        let toSendBranch = afterIf[..<elseRange.lowerBound]
        #expect(toSendBranch.contains("QueueFilterBar("))
        #expect(toSendBranch.contains("tooFarCount: tooFar"))
    }
}
