import Testing
import Foundation

// The conversation-state dimension layered on a reply (#111): where an active conversation sits
// between a bare reply and a booking. interested / wantsToBook / hasQuestion are "active" (they get
// reminders); declined is terminal. Stored on Recipient as a raw string with an auto/manual source,
// mirroring Outcome, so #112's AI suggestion never silently overwrites a state Dan set by hand (see
// RecipientTests for the accessor round-trip coverage).
@Suite("Conversation state")
struct ConversationStateTests {
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
}
