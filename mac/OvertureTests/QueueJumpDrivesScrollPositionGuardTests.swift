import Testing
import Foundation

// #1573: the queue's scroll position has ONE owner, the scrollPosition($topGroup) binding over the
// scrollTargetLayout. Both intentional jumps (a picked search result or OmniFocus deep link via
// navigateToLead, a tapped away-alert via focusOnLeads) used to clear that binding and then ask
// ScrollViewProxy for the row's id instead. The two fought, the row jump was dropped, and clicking a
// search result for a show already in the focused stage did nothing at all.
//
// There is no runtime output to assert on here: the resolution itself is QueueModel.scrollGroupID,
// which QueueScrollTargetTests covers, and the rest is SwiftUI layout that no test can reach. What
// silently rots is the SHAPE, and reintroducing `topGroup = nil` before a jump brings the dead click
// straight back with every other test still green. That is what this pins, in the same spirit as
// QueueRenderDataGuardTests and StagePillCountMatchesNavigationTests.
@Suite("A queue jump drives the scroll binding, it does not fight it (#1573)")
struct QueueJumpDrivesScrollPositionGuardTests {
    private var queueView: String { SourceGuardHelper.source("Overture/UI/QueueView.swift") }

    // Both jumps resolve a real group id and assign it. Neither may clear the binding: that is the
    // exact line that made the jump a no-op.
    @Test func bothJumpsDriveTopGroupRatherThanClearingIt() {
        for jump in ["private func navigateToLead(_ key: String, proxy: ScrollViewProxy) {",
                     "private func focusOnLeads(_ keys: [String], proxy: ScrollViewProxy) {"] {
            guard let body = SourceGuardHelper.propertyBody(jump, in: queueView) else {
                Issue.record("expected to find the body of \(jump)")
                continue
            }
            #expect(body.contains("topGroup = QueueModel.scrollGroupID(")
                    || body.contains("QueueModel.scrollGroupID("),
                    "\(jump) should resolve the group holding the row")
            #expect(!body.contains("topGroup = nil"),
                    "\(jump) must not clear the binding that owns the scroll position")
        }
    }

    // The scroll targets are namespaced at the point they are drawn, so the show group and the hire
    // inquiry group on one date stay two distinct targets in the one layout.
    @Test func theTwoKindsOfGroupAreDrawnWithDistinctIDs() {
        #expect(queueView.contains(".id(QueueModel.showGroupScrollID(group.id))"))
        #expect(queueView.contains(".id(QueueModel.inquiryGroupScrollID(group.id))"))
    }
}
