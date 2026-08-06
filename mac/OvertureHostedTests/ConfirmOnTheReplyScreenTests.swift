import Testing
import Foundation
import SwiftUI
import SwiftData
import ViewInspector
@testable import Overture

// #2154, the half only a rendered screen can answer.
//
// The rule being right in ReplyPanel proves nothing about where the control appears (L3), and this issue
// is entirely about WHERE: the guess and the message have to be on the same screen, because confirming
// the one means having read the other.
@MainActor
@Suite("The guess and the message are on the same screen (#2154)")
struct ConfirmOnTheReplyScreenTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self, Inquiry.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    // Dan's real row: The Pumpkin Singalong at Sakura Park, guessed as wants-to-book.
    private func screen(words: String?, source: OutcomeSource? = .auto) throws -> ReplySheet {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "The Pumpkin Singalong at Sakura Park",
                         discipline: "choral", venue: "Sakura Park", performanceDate: "2026-10-28",
                         sourceListingURL: nil, websiteURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 8, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        let r = Recipient(id: "nbecker@evc.org", email: "nbecker@evc.org", provenance: .act)
        r.sentAt = Date(timeIntervalSince1970: 1)
        r.sendState = .sent
        r.gmailThreadId = "t"
        r.replied = true
        r.repliedAt = Date(timeIntervalSince1970: 2)
        r.replyFromAddress = "nbecker@evc.org"
        r.replyAudience = ["nbecker@evc.org"]
        r.lastReplyText = words
        r.conversationStateRaw = ConversationState.wantsToBook.rawValue
        r.conversationStateSource = source
        p.setRecipients([r])
        return ReplySheet(composition: .answering(r, of: p, context: ctx, feedback: ActionFeedback()),
                          gmailConnected: true)
    }

    private func texts(_ view: ReplySheet) throws -> [String] {
        try view.inspect().findAll(ViewType.Text.self).map { try $0.string() }
    }

    // The message and the judgement about it are on screen together, which is the whole ask.
    @Test func theWordsAndTheGuessAppearTogether() throws {
        let view = try screen(words: "We'd love to book you for the October run.")
        let shown = try texts(view)
        #expect(shown.contains("We'd love to book you for the October run."))
        #expect(shown.contains(ConversationState.looksLikeNote(.wantsToBook)))
        #expect(shown.contains(ReplyPanelCopy.confirmGuess),
                "the guess must be confirmable where the message is. Shown: \(shown)")
    }

    // No captured words, so nothing to rule on: the guess is still stated and can still be CHANGED, but
    // Confirm is not offered. The sentence saying the message could not be shown is already on screen
    // directly above, which is the reason, so nothing extra is said about it.
    @Test func withNoCapturedWordsTheGuessIsStatedButNotConfirmable() throws {
        let view = try screen(words: nil)
        let shown = try texts(view)
        #expect(shown.contains(ConversationState.looksLikeNote(.wantsToBook)))
        #expect(shown.contains(ReplyPanelCopy.noCapturedWords))
        #expect(!shown.contains(ReplyPanelCopy.confirmGuess),
                "confirming a reading of a message nobody can show him is a rubber stamp. Shown: \(shown)")
        #expect(shown.contains(ReplyPanelCopy.changeGuess),
                "saying where it stands is his own assertion and stays available")
    }

    // A state Dan set himself is not a guess, so the screen offers no confirm-or-change pair about it.
    @Test func aStateHeSetHimselfIsNotPresentedAsAGuess() throws {
        let view = try screen(words: "We'd love to book you.", source: .manual)
        let shown = try texts(view)
        #expect(!shown.contains(ConversationState.looksLikeNote(.wantsToBook)))
        #expect(!shown.contains(ReplyPanelCopy.confirmGuess))
    }
}
