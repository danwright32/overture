import Testing
import Foundation

// Regression guard for #677: the "replied, no resolution yet, didn't bounce" check was
// independently recomputed in OmniFocusSync.swift, ReachedOutQueue.swift, and
// ConversationReminder.swift (plus a per-recipient-conversation-state-aware version inline in
// Prospect.hasUnhandledReply), copy pasted rather than shared. Recipient.hasUnhandledReply is now
// the one place that triplet lives; the two sites that also need to exclude a manually hand-set
// #2397: nothing composes a conversation state onto it any more; what clears a reply is answering it.
// site instead of re-deriving the base triplet themselves.
@Suite("Recipient.hasUnhandledReply")
struct RecipientHasUnhandledReplyTests {
    private func recipient(sendState: SendState = .sent, replied: Bool = false,
                           resolution: RecipientResolution? = nil, bounced: Bool = false) -> Recipient {
        let r = Recipient(id: "a@e.com", email: "a@e.com", provenance: .act)
        r.sendState = sendState
        r.replied = replied
        r.resolution = resolution
        r.bounced = bounced
        return r
    }

    @Test func trueWhenRepliedAndUnresolvedAndNotBounced() {
        #expect(recipient(replied: true).hasUnhandledReply)
    }

    @Test func falseWhenNotReplied() {
        #expect(!recipient(replied: false).hasUnhandledReply)
    }

    @Test func falseWhenTheReplyIsAlreadyResolved() {
        #expect(!recipient(replied: true, resolution: .declinedSoft).hasUnhandledReply)
    }

    @Test func falseWhenTheReplyBounced() {
        #expect(!recipient(replied: true, bounced: true).hasUnhandledReply)
    }

}

// SourceGuard for #677: each former call site must route through the shared Recipient property
// instead of re-deriving `replied && resolution == nil && !bounced` (or the recipient-facts
// version of it) inline, or the duplication this issue fixed can silently creep back in.
@Suite("hasUnhandledReply call sites stay routed through the shared property")
struct RecipientHasUnhandledReplyCallSiteGuardTests {
    private static let oldStandingTriplet = "standing.resolution == nil && !standing.bounced"
    private static let oldRecipientTriplet = "$0.resolution == nil && !$0.bounced"

    @Test func omniFocusSyncUsesTheSharedProperty() {
        let src = SourceGuardHelper.source("Overture/Domain/OmniFocusSync.swift")
        #expect(!src.isEmpty)
        #expect(!src.contains(Self.oldStandingTriplet),
                "OmniFocusSync must not re-derive the unhandled-reply triplet inline; use Recipient.hasUnhandledReply (#677).")
        #expect(src.contains(".hasUnhandledReply"),
                "OmniFocusSync must read Recipient.hasUnhandledReply instead of recomputing it (#677).")
    }

    @Test func reachedOutQueueUsesTheSharedProperty() {
        let src = SourceGuardHelper.source("Overture/Domain/ReachedOutQueue.swift")
        #expect(!src.isEmpty)
        #expect(!src.contains(Self.oldStandingTriplet),
                "ReachedOutQueue must not re-derive the unhandled-reply triplet inline; use Recipient.hasUnhandledReply (#677).")
        #expect(src.contains(".hasUnhandledReply"),
                "ReachedOutQueue must read Recipient.hasUnhandledReply instead of recomputing it (#677).")
    }

    // #2397: the conversation reminder that used to be checked here is retired. Its post-event successor
    // does not ask this question at all (it turns on the show's DATE), and the one place that still reads an
    // unhandled reply is ReachedOutQueue, guarded above.

    @Test func prospectHasUnhandledReplyUsesTheSharedProperty() {
        let src = SourceGuardHelper.source("Overture/Domain/Prospect.swift")
        #expect(!src.isEmpty)
        #expect(!src.contains(Self.oldRecipientTriplet),
                "Prospect.hasUnhandledReply must not re-derive the unhandled-reply triplet inline; use Recipient.hasUnhandledReply (#677).")
        #expect(src.contains(".hasUnhandledReply"),
                "Prospect.hasUnhandledReply must read Recipient.hasUnhandledReply instead of recomputing it (#677).")
    }
}
