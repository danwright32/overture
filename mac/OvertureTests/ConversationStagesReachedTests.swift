import Testing
import Foundation
import SwiftData

// #16 plumbing, second slice. `conversationStateRaw` holds only where a conversation IS, so a contact
// who asked a question and then decided to book no longer records that a question was ever asked. The
// funnel's middle band wants to count conversations that PASSED THROUGH each stage, which the single
// current value cannot answer, and which nothing could recover afterwards.
//
// Dan's call (2026-07-23): a stage is marked only when HE asserts it, by setting it himself or by
// accepting the AI's suggestion. An automatic suggestion he never confirmed (or overrode) leaves no
// trace, so a wrong AI read can never be baked into the permanent record. That rules out marking inside
// the shared `conversationState` setter, which the auto path also passes through.
@MainActor
@Suite("Conversation stages reached (#16)")
struct ConversationStagesReachedTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func contact(_ ctx: ModelContext? = nil, email: String = "a@org.org") -> Recipient {
        let id = Recipient.makeId(email: email, formURL: nil)!
        let r = Recipient(id: id, email: email, name: nil, role: nil, provenance: .act)
        ctx?.insert(r)
        return r
    }

    private let t0 = Date(timeIntervalSince1970: 1_000)
    private let t1 = Date(timeIntervalSince1970: 2_000)

    @Test func settingAStageByHandMarksIt() {
        let r = contact()

        r.setConversationState(.interested, now: t0)

        #expect(r.conversationStagesReached == ["interested"])
    }

    // The whole point: moving on must not erase where the conversation has been.
    @Test func movingOnKeepsTheEarlierStage() {
        let r = contact()

        r.setConversationState(.hasQuestion, now: t0)
        r.setConversationState(.wantsToBook, now: t1)

        #expect(r.conversationState == .wantsToBook)                       // where it is
        #expect(r.conversationStagesReached == ["has_question", "wants_to_book"])   // where it has been
    }

    // Recorded in the order first reached, and never twice, so a count of conversations that reached a
    // stage is a count of conversations rather than of clicks.
    @Test func aStageSetTwiceIsRecordedOnce() {
        let r = contact()

        r.setConversationState(.interested, now: t0)
        r.setConversationState(.hasQuestion, now: t0)
        r.setConversationState(.interested, now: t1)

        #expect(r.conversationStagesReached == ["interested", "has_question"])
    }

    // Dan's decision: the AI's own guess is not an assertion. Until he accepts it, nothing is recorded.
    @Test func anUnconfirmedSuggestionMarksNothing() {
        let r = contact()

        r.suggestConversationState(.hasQuestion, now: t0)

        #expect(r.conversationState == .hasQuestion)   // it still shows, as today
        #expect(r.conversationStagesReached.isEmpty)   // but the record stays empty
    }

    @Test func acceptingASuggestionMarksIt() {
        let r = contact()
        r.suggestConversationState(.hasQuestion, now: t0)

        r.confirmConversationState(now: t1)

        #expect(r.conversationStagesReached == ["has_question"])
    }

    // The failure Dan's decision exists to prevent: the AI reads a question that was not there, he
    // corrects it, and the record must show only what he said.
    @Test func overridingAWrongSuggestionRecordsOnlyDansStage() {
        let r = contact()
        r.suggestConversationState(.hasQuestion, now: t0)

        r.setConversationState(.interested, now: t1)

        #expect(r.conversationStagesReached == ["interested"])
    }

    // Declining is a stage like any other: it is the funnel's exit from a live conversation, and a
    // conversation that declined still reached whatever it reached before that.
    @Test func decliningIsRecordedAfterTheStagesBeforeIt() {
        let r = contact()
        r.setConversationState(.interested, now: t0)

        r.setConversationState(.declined, now: t1)

        #expect(r.conversationStagesReached == ["interested", "declined"])
    }

    // MARK: - seeding what is already in the store

    // No history was ever recorded, so earlier stages are genuinely gone. But a contact SITTING at a
    // stage demonstrably reached it, so recording that is a fact rather than an estimate.
    @Test func theSeedRecordsAStageDanHadSetHimself() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.setConversationState(.wantsToBook, now: t0)
        r.conversationStagesReached = []      // as every row predating this field looks
        try ctx.save()

        let changed = ConversationStagesSeed.run(in: ctx)

        #expect(changed == 1)
        #expect(r.conversationStagesReached == ["wants_to_book"])
    }

    // Same rule as the live path: an AI suggestion he never confirmed is not his assertion, so the seed
    // must not promote it into the permanent record on his behalf.
    @Test func theSeedSkipsAnUnconfirmedSuggestion() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.suggestConversationState(.hasQuestion, now: t0)
        r.conversationStagesReached = []
        try ctx.save()

        #expect(ConversationStagesSeed.run(in: ctx) == 0)
        #expect(r.conversationStagesReached.isEmpty)
    }

    // It runs on every launch, so a second pass must add nothing: a contact whose stage has since moved
    // on already carries both marks, and re-seeding would append the current one again.
    @Test func theSeedIsIdempotent() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        r.setConversationState(.interested, now: t0)
        r.conversationStagesReached = []
        try ctx.save()
        _ = ConversationStagesSeed.run(in: ctx)

        #expect(ConversationStagesSeed.run(in: ctx) == 0)
        #expect(r.conversationStagesReached == ["interested"])
    }

    // A contact that never reached any stage has nothing to seed, and must not be handed one.
    @Test func theSeedLeavesAContactWithNoStageAlone() throws {
        let ctx = ModelContext(try container())
        let r = contact(ctx)
        try ctx.save()

        #expect(ConversationStagesSeed.run(in: ctx) == 0)
        #expect(r.conversationStagesReached.isEmpty)
    }
}
