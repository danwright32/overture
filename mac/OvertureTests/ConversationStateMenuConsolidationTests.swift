import Testing
import Foundation

// #662: FollowUpsView.setStateMenu and DraftReviewView.stateMenu each independently rendered the
// same "pick a contact's conversation state" Menu (both built during #652). Both must delegate to
// the shared ConversationStateMenu view instead of keeping their own copy of the ForEach over
// ConversationState.allCases, so the two can never drift apart again.
@Suite("Conversation state menu consolidation")
struct ConversationStateMenuConsolidationTests {
    @Test func followUpsViewDelegatesToTheSharedMenu() throws {
        let src = SourceGuardHelper.source("Overture/UI/FollowUpsView.swift")
        #expect(!src.isEmpty)
        let body = try SourceGuard.functionBody(named: "setStateMenu", in: src)
        #expect(body.contains("ConversationStateMenu("),
                "setStateMenu no longer delegates to the shared ConversationStateMenu view (#662).")
        #expect(!body.contains("ForEach(ConversationState.allCases"),
                "setStateMenu reintroduced its own ForEach over ConversationState.allCases instead of using the shared view (#662).")
    }

    @Test func draftReviewViewDelegatesToTheSharedMenu() throws {
        let src = SourceGuardHelper.source("Overture/UI/DraftReviewView.swift")
        #expect(!src.isEmpty)
        let body = try SourceGuard.functionBody(named: "stateMenu", in: src)
        #expect(body.contains("ConversationStateMenu("),
                "stateMenu no longer delegates to the shared ConversationStateMenu view (#662).")
        #expect(!body.contains("ForEach(ConversationState.allCases"),
                "stateMenu reintroduced its own ForEach over ConversationState.allCases instead of using the shared view (#662).")
    }
}
