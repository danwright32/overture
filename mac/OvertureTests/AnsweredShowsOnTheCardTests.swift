import Testing
import Foundation
import SwiftData

// #2951: the card can see that a reply was ANSWERED.
//
// `RecipientSnapshot.statusLabel` collapsed permanently to "In conversation" the moment `replied` became
// true, so a conversation Dan answered days ago read exactly like one waiting on him. The snapshot could
// not see the answer at all, which is why no card-based surface could show it.
//
// #2934 carried `hasUnhandledReply` and `replyIsAnswered` onto the snapshot for the reply block. This is
// the other surface that was blind, and it needs nothing new to be carried: the facts are already there.
@MainActor
@Suite("A card says when a reply has been answered (#2951)")
struct AnsweredShowsOnTheCardTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: AppSchema.schema,
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func contact(answered: Bool, in ctx: ModelContext, now: Date = Date()) throws -> RecipientSnapshot {
        let p = Prospect(naturalKey: "aurora|2026-11-14|carnegie", groupName: "Aurora Strings",
                         discipline: "music", venue: "Carnegie Hall", performanceDate: "2026-11-14",
                         sourceListingURL: nil, priorRelationship: "none",
                         production: "self", profile: "strong", coverage: "likely_uncovered",
                         fitScore: 9, tier: "high", fitReason: "r", matchedClientName: nil,
                         possibleMatchSource: nil, possibleMatchName: nil)
        let r = Recipient(id: "ada@aurora.test", email: "ada@aurora.test", name: "Ada", provenance: .act)
        r.sendState = .sent
        r.sentAt = now.addingTimeInterval(-6 * 86_400)
        r.replied = true
        r.repliedAt = now.addingTimeInterval(-5 * 86_400)
        r.inboundReplySentAt = now.addingTimeInterval(-5 * 86_400)
        if answered { r.replyHandledAt = now.addingTimeInterval(-4 * 86_400) }
        p.addRecipient(r)
        ctx.insert(p)
        return RecipientSnapshot(r)
    }

    // A reply nobody has answered is unchanged: it is a live exchange, and that is what the label has
    // always said.
    @Test func areplyWaitingOnDanStillReadsAsAConversation() throws {
        let ctx = ModelContext(try container())
        #expect(try contact(answered: false, in: ctx).statusLabel == "In conversation")
    }

    // THE gap: answered days ago, and the card said the same thing.
    @Test func areplyDanAnsweredSaysSo() throws {
        let ctx = ModelContext(try container())
        let snapshot = try contact(answered: true, in: ctx)

        #expect(snapshot.statusLabel != "In conversation",
                "an answered conversation read exactly like one waiting on him")
        #expect(snapshot.statusLabel == "You answered them")
    }

    // A recorded ENDING still wins over both. Those are terminal marks and they are what the row is now,
    // whatever happened on the way; the label's existing precedence is deliberate and unchanged.
    @Test func arecordedEndingStillWins() throws {
        let ctx = ModelContext(try container())
        let p = Prospect(naturalKey: "k", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-11-14", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        let r = Recipient(id: "a@b.test", email: "a@b.test", provenance: .act)
        r.sendState = .sent
        r.replied = true
        r.repliedAt = Date()
        r.inboundReplySentAt = Date()
        r.replyHandledAt = Date()
        r.resolution = .booked
        p.addRecipient(r)
        ctx.insert(p)

        #expect(RecipientSnapshot(r).statusLabel == "Booked")
    }

    // A bounce still wins over the answer too, for the same reason it always did: it is a fact about
    // whether the mail arrived at all.
    @Test func abounceStillWins() throws {
        let ctx = ModelContext(try container())
        let ctx2 = ModelContext(try container())
        _ = ctx2
        let p = Prospect(naturalKey: "k2", groupName: "G", discipline: "music", venue: "V",
                         performanceDate: "2026-11-14", sourceListingURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 9, tier: "high", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        let r = Recipient(id: "a@b.test", email: "a@b.test", provenance: .act)
        r.sendState = .sent
        r.replied = true
        r.bounced = true
        p.addRecipient(r)
        ctx.insert(p)

        #expect(RecipientSnapshot(r).statusLabel == "Bounced")
    }

    // The label reads the CARRIED fact, not its own reading of the stamps. A second reading is how the
    // card and the queue came to disagree in the first place (#2934, L16, L70).
    @Test func thelabelReadsTheCarriedAnswerRatherThanTheStamps() throws {
        let ctx = ModelContext(try container())
        var snapshot = try contact(answered: false, in: ctx)
        #expect(snapshot.statusLabel == "In conversation")
        snapshot.replyIsAnswered = true
        #expect(snapshot.statusLabel == "You answered them")
    }
}
