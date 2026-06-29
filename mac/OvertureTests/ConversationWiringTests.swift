import Testing
import Foundation
@testable import Overture

// Wiring the conversation lifecycle onto a Prospect (#111): setting a state stamps its anchors and
// source, marks an offline/uncontacted reply as replied so the silent FollowUp sequencer stands down
// (the real no-double-count guard), and declined resolves the lead to lost-soft. "Remind me later"
// re-anchors without sending.
@Suite("Conversation wiring")
struct ConversationWiringTests {
    private func lead(outcome: Outcome = .noResponse, sentAt: Date? = nil, source: OutcomeSource? = nil) -> Prospect {
        let p = Prospect(naturalKey: "k", groupName: "Aurora Strings", discipline: "music", venue: "Carnegie Hall",
                         performanceDate: "2026-09-01", sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "warm", production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        p.outcome = outcome
        p.outcomeSourceRaw = source?.rawValue
        p.sentAt = sentAt
        return p
    }

    private var now: Date { Date(timeIntervalSince1970: 1_000_000) }
    private func daysAgo(_ d: Double) -> Date { now.addingTimeInterval(-d * 86_400) }

    @Test func settingAnActiveStateMarksANoResponseLeadReplied() {
        let p = lead(outcome: .noResponse)
        p.setConversationState(.wantsToBook, now: now)
        #expect(p.conversationState == .wantsToBook)
        #expect(p.conversationStateSetAt == now)
        #expect(p.conversationStateSource == .manual)
        #expect(p.outcome == .replied)
        #expect(p.outcomeSourceRaw == OutcomeSource.manual.rawValue)
        #expect(p.outcomeAt == now)
    }

    @Test func settingAStateDoesNotOverwriteAnExistingReply() {
        let p = lead(outcome: .replied, source: .auto)
        p.setConversationState(.interested, now: now)
        #expect(p.conversationState == .interested)
        #expect(p.outcome == .replied)
        #expect(p.outcomeSourceRaw == OutcomeSource.auto.rawValue)   // existing reply untouched
    }

    @Test func decliningResolvesToLostSoftManually() {
        let p = lead(outcome: .replied, source: .auto)
        p.setConversationState(.declined, now: now)
        #expect(p.conversationState == .declined)
        #expect(p.outcome == .lostSoft)
        #expect(p.outcomeSourceRaw == OutcomeSource.manual.rawValue)
    }

    @Test func decliningWritesThroughToEngagedContactsButLeavesUntriedAccurate() {
        let p = lead(outcome: .replied, source: .auto)
        // Emailed, still open: Dan engaged this contact, so a close resolves it.
        let engaged = Recipient(id: "act@x.org", email: "act@x.org", provenance: .act)
        engaged.sendState = .sent
        // Never emailed but reachable (the act-then-presenter ladder): must stay accurate, NOT
        // marked won or lost, because Dan never contacted them.
        let untried = Recipient(id: "pres@x.org", email: "pres@x.org", provenance: .presenter)
        untried.sendState = .pending
        // Emailed but bounced: already terminal, not a Dan-declined contact.
        let bounced = Recipient(id: "bad@x.org", email: "bad@x.org", provenance: .act)
        bounced.sendState = .sent
        bounced.bounced = true
        p.setRecipients([engaged, untried, bounced])

        p.setConversationState(.declined, now: now)

        #expect(p.outcome == .lostSoft)                       // show-level close signal stays
        #expect(engaged.resolution == .declinedSoft)          // engaged contact written through
        #expect(engaged.outcomeSource == .manual)
        #expect(untried.resolution == nil)                    // never contacted -> no false outcome
        #expect(untried.sendState == .pending)
        #expect(bounced.resolution == nil)                    // bounced left untouched
        #expect(bounced.bounced == true)
        #expect(p.isClosed == true)                           // honest close despite an untried contact left
    }

    @Test func remindLaterStampsTheReanchor() {
        let p = lead()
        p.remindLater(now: now)
        #expect(p.conversationRemindedAt == now)
    }

    @Test func settingAStateStandsDownTheSilentSequencer() {
        // A sent, silent lead the FollowUp sequencer would nudge.
        let p = lead(outcome: .noResponse, sentAt: daysAgo(10))
        #expect(FollowUp.due(from: [p], now: now).count == 1)   // precondition: in the silent queue

        p.setConversationState(.wantsToBook, now: now)
        #expect(FollowUp.due(from: [p], now: now).isEmpty)      // now excluded: no double-count
    }

    @Test func suggestSetsAutoAndNeverOverwritesAManualState() {
        let manual = lead(outcome: .replied)
        manual.setConversationState(.interested, now: now)                 // Dan's hand-set choice
        manual.suggestConversationState(.declined, now: now.addingTimeInterval(100))
        #expect(manual.conversationState == .interested)                  // unchanged (#60)
        #expect(manual.conversationStateSource == .manual)

        let fresh = lead(outcome: .replied)
        fresh.suggestConversationState(.wantsToBook, now: now)
        #expect(fresh.conversationState == .wantsToBook)
        #expect(fresh.conversationStateSource == .auto)
        #expect(fresh.conversationStateSetAt == now)
    }

    @Test func confirmFlipsAutoToManualAndRestartsTheClock() {
        let p = lead(outcome: .replied)
        p.suggestConversationState(.wantsToBook, now: daysAgo(5))
        p.confirmConversationState(now: now)
        #expect(p.conversationState == .wantsToBook)
        #expect(p.conversationStateSource == .manual)
        #expect(p.conversationStateSetAt == now)                          // timed clock starts at confirm
    }
}
