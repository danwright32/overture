import Testing
import Foundation

// #682 built a targeted deep link: the reached-out row's "Send a follow-up" button opened the Follow-ups
// sheet scrolled to, and highlighting, the contact Dan clicked from.
//
// #2130 replaced that button. The row no longer navigates anywhere: it names what is actually due and does
// it, because "due now" there is min of three clocks and meant six different things behind one wording,
// two of which could not be sent at all. That left the targeted mechanism with no caller, and #2138
// removed it across QueueView, RootView and FollowUpsView.
//
// This file now pins the removal rather than the feature: a dead path half-restored is worse than either
// state, and the button it hung off must not quietly go back to navigating (L29).
@Suite("The reached-out row acts rather than deep-linking into Follow-ups")
struct FollowUpsDeepLinkGuardTests {
    private func source(_ relativeFromMac: String, file: StaticString = #filePath) -> String {
        SourceGuardHelper.source(relativeFromMac, file: file)
    }

    private var queueView: String { source("Overture/UI/QueueView.swift") }
    private var followUpsView: String { source("Overture/UI/FollowUpsView.swift") }
    private var rootView: String { source("Overture/App/RootView.swift") }

    // The behaviour that replaced it. Dan, 2026-08-05: "If I click send a follow-up I should be able to
    // send a follow-up. buttons need to do what they say."
    @Test func theRowActsInsteadOfOpeningTheFollowUpsSheet() throws {
        #expect(!queueView.isEmpty)
        let body = try SourceGuard.functionBody(named: "reachedOutRow", in: queueView)
        #expect(body.contains("ReachedOutAction.of("),
                "the reached-out row no longer labels its control by what is actually due (#2130).")
        #expect(!body.contains("onShowFollowUpsFor"),
                "the reached-out row's control must act on the row, not open the Follow-ups sheet (#2130).")
    }

    // The removal stayed complete. Any one of these coming back alone leaves a path that looks wired and
    // cannot be reached, which is exactly the state #2138 cleared.
    @Test func theTargetedMechanismIsGoneFromAllThreeFiles() {
        #expect(!queueView.contains("onShowFollowUpsFor"),
                "QueueView still declares the targeted callback, which nothing calls (#2138).")
        #expect(!rootView.contains("onShowFollowUpsFor"),
                "RootView still wires the targeted callback, which nothing calls (#2138).")
        #expect(!rootView.contains("followUpsHighlightRecipientId"),
                "RootView still holds the highlight target for a mechanism that is gone (#2138).")
        #expect(!followUpsView.contains("initialHighlightRecipientId"),
                "FollowUpsView still accepts a highlight target nothing can supply (#2138).")
        #expect(!followUpsView.contains("highlightedRecipientId"),
                "FollowUpsView still carries highlight state nothing can set (#2138).")
    }

    // The UNtargeted route is untouched: the stage pill and the Due badge still open the sheet, which is
    // how Dan reaches the whole list. Removing the targeted variant must not have taken this with it.
    @Test func theUntargetedRouteIntoFollowUpsStillWorks() {
        #expect(queueView.contains("onShowFollowUps()"),
                "the Follow-ups stage pill no longer opens the sheet (#682).")
        #expect(rootView.contains("onShowFollowUps:"),
                "RootView no longer wires the untargeted Follow-ups callback (#682).")
    }

    // Each row still tags itself with its recipient id. That is what any future scroll-to would need, and
    // it costs nothing to keep, but nothing may claim to highlight a row until something can select one.
    @Test func rowsStillCarryTheirRecipientId() throws {
        #expect(!followUpsView.isEmpty)
        for name in ["row", "postEventRow"] {
            let body = try SourceGuard.functionBody(named: name, in: followUpsView)
            #expect(body.contains(".id(r.id)"),
                    "FollowUpsView's \(name) no longer tags itself with the recipient id (#682).")
        }
    }
}
