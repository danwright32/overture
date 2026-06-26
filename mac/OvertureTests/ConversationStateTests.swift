import Testing
import Foundation
@testable import Overture

// The conversation-state dimension layered on a reply (#111): where an active conversation sits
// between a bare reply and a booking. interested / wantsToBook / hasQuestion are "active" (they get
// reminders); declined is terminal. Stored on Prospect as a raw string with an auto/manual source,
// mirroring Outcome, so #112's AI suggestion never silently overwrites a state Dan set by hand.
@Suite("Conversation state")
struct ConversationStateTests {
    private func makeProspect() -> Prospect {
        Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: nil,
                 performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                 priorRelationship: "none", production: "self", profile: "neutral",
                 coverage: "unknown", fitScore: 3, tier: "longshot", fitReason: "r",
                 matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
    }

    @Test func rawValuesAreStable() {
        #expect(ConversationState.interested.rawValue == "interested")
        #expect(ConversationState.wantsToBook.rawValue == "wants_to_book")
        #expect(ConversationState.hasQuestion.rawValue == "has_question")
        #expect(ConversationState.declined.rawValue == "declined")
    }

    @Test func eachStateHasADistinctLabel() {
        let labels = ConversationState.allCases.map(\.label)
        #expect(Set(labels).count == ConversationState.allCases.count)
        #expect(labels.allSatisfy { !$0.isEmpty })
    }

    @Test func activeStatesAreEverythingButDeclined() {
        #expect(ConversationState.interested.isActive)
        #expect(ConversationState.wantsToBook.isActive)
        #expect(ConversationState.hasQuestion.isActive)
        #expect(ConversationState.declined.isActive == false)
    }

    @Test func prospectStartsWithNoConversationState() {
        #expect(makeProspect().conversationState == nil)
        #expect(makeProspect().conversationStateSource == nil)
    }

    @Test func prospectConversationStateAccessorRoundTrips() {
        let p = makeProspect()
        p.conversationState = .wantsToBook
        #expect(p.conversationStateRaw == "wants_to_book")
        #expect(p.conversationState == .wantsToBook)
    }

    @Test func prospectConversationStateSourceReusesOutcomeSource() {
        let p = makeProspect()
        p.conversationStateSource = .manual
        #expect(p.conversationStateSourceRaw == "manual")
        #expect(p.conversationStateSource == .manual)
    }
}
