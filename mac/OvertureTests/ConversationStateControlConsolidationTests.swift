import Testing
import Foundation

// #661: DraftReviewView's per-contact stateControl and QueueView's new lightweight reached-out row
// both need the same "unconfirmed AI state offers Confirm/Change, everything else offers Set a
// state/Change" control. Both must delegate to the shared ConversationStateControl view instead of
// each keeping their own copy of that branching, mirroring the #662 ConversationStateMenu precedent.
@Suite("Conversation state control consolidation")
struct ConversationStateControlConsolidationTests {
    @Test func draftReviewViewDelegatesToTheSharedControl() throws {
        let src = SourceGuardHelper.source("Overture/UI/DraftReviewView.swift")
        #expect(!src.isEmpty)
        let body = try SourceGuard.functionBody(named: "stateControl", in: src)
        #expect(body.contains("ConversationStateControl("),
                "stateControl no longer delegates to the shared ConversationStateControl view (#661).")
        #expect(!body.contains("conversationStateSource == .auto"),
                "stateControl reintroduced its own Confirm/Change branching instead of using the shared view (#661).")
    }

    @Test func queueViewReachedOutRowDelegatesToTheSharedControl() throws {
        let src = SourceGuardHelper.source("Overture/UI/QueueView.swift")
        #expect(!src.isEmpty)
        let body = try SourceGuard.functionBody(named: "reachedOutRow", in: src)
        #expect(body.contains("ConversationStateControl("),
                "reachedOutRow doesn't delegate to the shared ConversationStateControl view (#661).")
    }
}
