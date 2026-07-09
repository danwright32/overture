import Testing
import Foundation

// #686: follow-up to #683/#684. FollowUpsView's rows have the exact same gap the Reached Out
// row had, no path to the reply text, AI reply drafter, or Mark… menu, all of which only render
// on the full card (still reachable from Archive). Same fix: a jump link reusing the existing
// archive-highlight mechanism (#236/#308), on both row types in this sheet. Source-guarded since
// this view's rows aren't directly invokable in a test.
@Suite("Follow-ups row archive jump (#686)")
struct FollowUpsRowArchiveJumpGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var followUpsView: String { source("Overture/UI/FollowUpsView.swift") }
    private var rootView: String { source("Overture/App/RootView.swift") }

    @Test func silentFollowUpRowCallsOnOpenInArchive() throws {
        #expect(!followUpsView.isEmpty)
        let body = try SourceGuard.functionBody(named: "row", in: followUpsView)
        #expect(body.contains("onOpenInArchive(d.prospect.naturalKey)"),
                "FollowUpsView's silent-follow-up row doesn't offer a jump to the full card in Archive (#686).")
    }

    @Test func conversationRowCallsOnOpenInArchive() throws {
        #expect(!followUpsView.isEmpty)
        let body = try SourceGuard.functionBody(named: "conversationRow", in: followUpsView)
        #expect(body.contains("onOpenInArchive(d.prospect.naturalKey)"),
                "FollowUpsView's conversation row doesn't offer a jump to the full card in Archive (#686).")
    }

    @Test func followUpsViewDeclaresTheCallback() {
        #expect(followUpsView.contains("var onOpenInArchive:"),
                "FollowUpsView doesn't declare an onOpenInArchive callback for its rows to call (#686).")
    }

    // Must reuse the existing archiveJumpKey/showArchive pair, not a second one, and must dismiss
    // this sheet first (showFollowUps = false) since Archive opens as a sibling sheet on the same
    // parent view.
    @Test func rootViewWiresTheCallbackAndDismissesTheSheetFirst() {
        #expect(!rootView.isEmpty)
        guard let callSite = rootView.range(of: "FollowUpsView(") else {
            Issue.record("FollowUpsView call site not found in RootView")
            return
        }
        let wiring = rootView[callSite.lowerBound...].prefix(300)
        #expect(wiring.contains("onOpenInArchive:"),
                "RootView doesn't wire onOpenInArchive at the FollowUpsView call site (#686).")
        #expect(wiring.contains("showFollowUps = false"),
                "onOpenInArchive should dismiss the Follow-ups sheet before Archive opens (#686).")
        #expect(wiring.contains("archiveJumpKey = "),
                "onOpenInArchive should set archiveJumpKey, reusing the existing jump mechanism (#686).")
        #expect(wiring.contains("showArchive = true"),
                "onOpenInArchive should set showArchive, reusing the existing jump mechanism (#686).")
    }
}
