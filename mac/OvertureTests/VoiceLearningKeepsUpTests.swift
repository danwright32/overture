import Testing
import Foundation
import SwiftData

// #2132: the voice learning degrades once answering replies is routine.
//
// It pairs the AI's draft with what Dan actually sent, to learn how he rewrites. Two things break that
// once replies come from the queue every day rather than occasionally from the Archive.
@MainActor
@Suite("Voice learning keeps up with a real conversation")
struct VoiceLearningKeepsUpTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func contact(_ ctx: ModelContext) -> Recipient {
        let r = Recipient(id: "c@x.org", email: "c@x.org", provenance: .act)
        ctx.insert(r)
        return r
    }

    // MARK: every exchange teaches, not only the first

    // A conversation is a back and forth. Guarding the capture on "never captured" meant only the first
    // answer in any thread ever taught anything, and answering from the queue is precisely about the
    // second, third and fourth.
    @Test func aSecondExchangeIsCapturedToo() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)

        r.reopenOnReply(at: Date(timeIntervalSince1970: 1_000))
        r.replyDraftBody = "My first answer."
        r.freezeSentReply(now: Date(timeIntervalSince1970: 1_100))
        #expect(r.sentReplyBody == "My first answer.")

        // They write again, and he answers again.
        r.reopenOnReply(at: Date(timeIntervalSince1970: 2_000))
        r.replyDraftBody = "My second answer."
        r.freezeSentReply(now: Date(timeIntervalSince1970: 2_100))
        #expect(r.sentReplyBody == "My second answer.")
    }

    // Without a newer inbound reply there is no new exchange, so a re-send of the same answer must not
    // overwrite the captured one with a later timestamp.
    @Test func nothingIsRecapturedWithoutANewReply() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.reopenOnReply(at: Date(timeIntervalSince1970: 1_000))
        r.replyDraftBody = "My first answer."
        r.freezeSentReply(now: Date(timeIntervalSince1970: 1_100))

        r.replyDraftBody = "A stray later draft."
        r.freezeSentReply(now: Date(timeIntervalSince1970: 1_200))
        #expect(r.sentReplyBody == "My first answer.")
        #expect(r.replySentAt == Date(timeIntervalSince1970: 1_100))
    }

    // A new inbound reply starts a new exchange, so the previous exchange's baseline must not be carried
    // into it. Left behind, the next pair would be this answer measured against an older conversation's
    // draft, which is a lesson about nothing.
    @Test func aNewReplyClearsTheOldBaseline() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.replyDraftBody = "The AI's first attempt."
        r.applyReplyDraftEdit("My first answer.")
        #expect(r.originalReplyDraftBody == "The AI's first attempt.")

        r.reopenOnReply(at: Date(timeIntervalSince1970: 2_000))
        #expect(r.originalReplyDraftBody == nil, "a new exchange starts from no baseline")
    }
}
