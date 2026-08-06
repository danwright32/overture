import Testing
import Foundation
import SwiftData

// #2154, reported by Dan from the reached out row for "The Pumpkin Singalong at Sakura Park":
// "I can't confirm if they want to book without reading the message first."
//
// "Looks like wants to book" is Overture's AI guess at what a reply meant, and pressing Confirm writes
// that guess in as fact, which changes what the contact is due next and what the conversation track will
// send them. The row carries not one word the person wrote, so the only honest answer available to him is
// "I don't know", and the control did not offer that. A control that demands a judgement while
// withholding the evidence for it is asking him to rubber stamp the classifier.
@MainActor
@Suite("A guess can only be confirmed where the message is (#2154)")
struct ConfirmNeedsTheMessageTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func contact(_ ctx: ModelContext, words: String?) -> Recipient {
        let r = Recipient(id: "c@x.org", email: "c@x.org", provenance: .act)
        ctx.insert(r)
        r.replied = true
        r.repliedAt = Date(timeIntervalSince1970: 1_000)
        r.lastReplyText = words
        r.conversationStateRaw = ConversationState.wantsToBook.rawValue
        r.conversationStateSource = .auto
        return r
    }

    // MARK: when a guess may be confirmed

    // The words are there to read, so the judgement is his to make.
    @Test func aGuessMayBeConfirmedWhenTheMessageIsThereToRead() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx, words: "We'd love to book you for the October run.")
        #expect(ReplyPanel.mayConfirmGuess(r))
    }

    // Overture holds a guess and not a single word of what produced it, so there is nothing to rule on.
    // Confirming here would be Dan endorsing the classifier's reading of a message he has never seen.
    @Test func aGuessMayNotBeConfirmedWhenNoWordsWereCaptured() throws {
        let ctx = ModelContext(try container())
        #expect(!ReplyPanel.mayConfirmGuess(contact(ctx, words: nil)))
    }

    // Whitespace is not a message.
    @Test func whitespaceIsNotAMessageToRuleOn() throws {
        let ctx = ModelContext(try container())
        #expect(!ReplyPanel.mayConfirmGuess(contact(ctx, words: "   \n ")))
    }

    // A state Dan set himself is not a guess and has nothing to confirm: it is already his assertion.
    @Test func aStateHeSetHimselfIsNotAGuessAwaitingConfirmation() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx, words: "We'd love to book you.")
        r.conversationStateSource = .manual
        #expect(!ReplyPanel.mayConfirmGuess(r))
    }

    // And a contact with no state at all has no guess either.
    @Test func noStateMeansNoGuessToConfirm() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx, words: "We'd love to book you.")
        r.conversationStateRaw = nil
        #expect(!ReplyPanel.mayConfirmGuess(r))
    }

    // MARK: what the row may offer

    // #2154 part 2: the row drew Confirm twice, from two controls that call the same mutation with the
    // same arguments. The action slot's copy goes, exactly as `.sayWhatHappened` already does, because
    // the state control owns the guess and shows what the guess actually IS, while a bare second
    // "Confirm" says nothing about what it confirms (#843).
    @Test func theActionSlotNoLongerDrawsAConfirmButton() {
        #expect(ReachedOutAction.confirmState.label == nil)
    }

    // It is still a real state of the row, so what is due there is unchanged: only the duplicate control
    // is gone. Losing the case would take the row's understanding of what it is waiting for with it.
    @Test func confirmStateIsStillWhatTheRowIsWaitingFor() throws {
        let ctx = ModelContext(try container())
        #expect(ReachedOutAction.confirmState.sendsAnEmail == false)
        #expect(ReachedOutAction.allCases.contains(.confirmState))
    }
}
