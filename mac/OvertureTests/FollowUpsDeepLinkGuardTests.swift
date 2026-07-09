import Testing
import Foundation

// #682: the Reached Out row's "Send a follow-up" button opened the whole Follow-ups sheet with no
// indication of which contact Dan clicked from, so he had to find that same recipient again in a
// possibly longer list. Threads the specific recipient through (mirroring the #236/#628 deep-link
// mechanisms that jump straight to a target), reusing ArchiveReveal's scroll-after-delay helper
// rather than a second copy. Source-guarded since these views aren't directly invokable in a test.
@Suite("Follow-ups deep link to a specific contact (#682)")
struct FollowUpsDeepLinkGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var queueView: String { source("Overture/UI/QueueView.swift") }
    private var followUpsView: String { source("Overture/UI/FollowUpsView.swift") }
    private var rootView: String { source("Overture/App/RootView.swift") }

    @Test func reachedOutRowCallsTheTargetedCallback() throws {
        #expect(!queueView.isEmpty)
        let body = try SourceGuard.functionBody(named: "reachedOutRow", in: queueView)
        #expect(body.contains("onShowFollowUpsFor(r.id)"),
                "reachedOutRow's Send-a-follow-up button doesn't thread the specific recipient through (#682).")
    }

    @Test func queueViewDeclaresTheTargetedCallback() {
        #expect(queueView.contains("var onShowFollowUpsFor:"),
                "QueueView doesn't declare an onShowFollowUpsFor callback (#682).")
    }

    // The generic Follow-ups stage pill must keep using the untargeted onShowFollowUps, not the
    // new targeted one (a pill click has no specific recipient to highlight).
    @Test func theGenericStagePillStillUsesTheUntargetedCallback() {
        #expect(queueView.contains("onShowFollowUps()"),
                "The generic Follow-ups stage pill should still call the untargeted onShowFollowUps (#682).")
    }

    @Test func followUpsViewDeclaresTheHighlightTarget() {
        #expect(followUpsView.contains("var initialHighlightRecipientId:"),
                "FollowUpsView doesn't accept an initial recipient to highlight/scroll to (#682).")
    }

    @Test func bothRowTypesTagThemselvesForScrollAndHighlight() throws {
        #expect(!followUpsView.isEmpty)
        for name in ["row", "conversationRow"] {
            let body = try SourceGuard.functionBody(named: name, in: followUpsView)
            #expect(body.contains(".id(r.id)"),
                    "FollowUpsView's \(name) doesn't tag itself with the recipient id for scrollTo (#682).")
            #expect(body.contains("highlightedRecipientId"),
                    "FollowUpsView's \(name) doesn't reflect the highlighted state (#682).")
        }
    }

    // Must reuse ArchiveReveal's cancellation-safe scroll-after-delay helper, not a second copy of
    // that timing logic.
    @Test func followUpsViewReusesArchiveReveal() {
        #expect(followUpsView.contains("ArchiveReveal.scrollAfterDelay("),
                "FollowUpsView doesn't reuse ArchiveReveal's scroll-after-delay helper (#682).")
    }

    @Test func rootViewWiresTheTargetedCallbackThroughToFollowUpsView() {
        #expect(!rootView.isEmpty)
        guard let callSite = rootView.range(of: "QueueView(deepLinkedKey:") else {
            Issue.record("QueueView call site not found in RootView")
            return
        }
        let wiring = rootView[callSite.lowerBound...].prefix(600)
        #expect(wiring.contains("onShowFollowUpsFor:"),
                "RootView doesn't wire onShowFollowUpsFor at the QueueView call site (#682).")
        guard let sheetSite = rootView.range(of: "FollowUpsView(") else {
            Issue.record("FollowUpsView call site not found in RootView")
            return
        }
        let sheetWiring = rootView[sheetSite.lowerBound...].prefix(300)
        #expect(sheetWiring.contains("initialHighlightRecipientId:"),
                "RootView doesn't pass the highlight target through to FollowUpsView (#682).")
    }
}
