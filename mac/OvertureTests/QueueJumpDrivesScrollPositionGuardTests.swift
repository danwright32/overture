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

    // Both jumps resolve a real group id and assign it to the channel that drives the scroll. Neither may
    // clear that channel: that is the exact line that made the jump a no-op.
    //
    // #1774 renamed the channel. The position itself moved onto QueueScrollHolder (as @State on QueueView
    // every scroll write re-derived the whole store), and the jumps now drive it through `jumpTarget`.
    //
    // This test was REWRITTEN, not merely re-anchored, because it had gone quietly toothless. Its first
    // assertion carried a fallback, `|| body.contains("QueueModel.scrollGroupID(")`, which passes whatever
    // the resolved id is assigned to, or even if it is assigned to nothing at all; and its second banned a
    // string, "topGroup = nil", that no longer occurs anywhere in the file, so it could not fail for any
    // edit whatsoever. Both survived the rename green while protecting nothing, which is the
    // a-guard-can-go-vacuous failure mode this whole suite exists to prevent.
    @Test func bothJumpsDriveTheScrollTargetRatherThanClearingIt() {
        for jump in ["private func navigateToLead(_ key: String, proxy: ScrollViewProxy) {",
                     "private func focusOnLeads(_ keys: [String], proxy: ScrollViewProxy) {"] {
            guard let body = SourceGuardHelper.propertyBody(jump, in: queueView) else {
                Issue.record("expected to find the body of \(jump)")
                continue
            }
            // No fallback clause. The resolved group id must be ASSIGNED to the jump channel, because
            // resolving it and dropping it on the floor is precisely the dead click #1573 fixed.
            #expect(body.contains("jumpTarget = ") && body.contains("QueueModel.scrollGroupID("),
                    "\(jump) should drive jumpTarget with the group holding the row")
            #expect(!body.contains("jumpTarget = nil"),
                    "\(jump) must not clear the channel that drives the scroll position")
        }
    }

    // And the channel is actually connected at the far end. Without this the two jumps could set
    // jumpTarget faithfully forever while nothing ever moved, which is the same dead click arriving by a
    // different route.
    @Test func theHolderAppliesTheJumpTargetToTheScrollPosition() {
        guard let holder = SourceGuardHelper.propertyBody("struct QueueScrollHolder<Content: View>: View {",
                                                          in: queueView) else {
            Issue.record("expected to find QueueScrollHolder")
            return
        }
        #expect(holder.contains(".onChange(of: jumpTarget)"))
        #expect(holder.contains("topGroup = target"))
    }

    // The scroll targets are namespaced at the point they are drawn, so the show group and the hire
    // inquiry group on one date stay two distinct targets in the one layout.
    @Test func theTwoKindsOfGroupAreDrawnWithDistinctIDs() {
        #expect(queueView.contains(".id(QueueModel.showGroupScrollID(group.id))"))
        #expect(queueView.contains(".id(QueueModel.inquiryGroupScrollID(group.id))"))
    }
}
