import Testing
import Foundation
import SwiftData
@testable import Overture

// #650: a show-level conversation state started before per-recipient state existed must not go
// silent the moment this ships. Seeds it onto whichever recipient actually replied (the most recent
// one, if more than one), exactly once (idempotent).
@Suite("Recipient conversation state migration")
struct RecipientConversationStateMigrationTests {
    private func container() throws -> ModelContainer {
        try ModelContainer(for: Schema([Prospect.self, Recipient.self]),
                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
    }

    private func prospect(_ ctx: ModelContext, key: String = "k") -> Prospect {
        let p = Prospect(naturalKey: key, groupName: key, discipline: "music", venue: "V",
                         performanceDate: nil, sourceListingURL: nil, websiteURL: nil,
                         priorRelationship: "none", production: "self", profile: "strong",
                         coverage: "likely_uncovered", fitScore: 5, tier: "mid", fitReason: "r",
                         matchedClientName: nil, possibleMatchSource: nil, possibleMatchName: nil)
        ctx.insert(p)
        return p
    }

    @Test func seedsTheMostRecentReplierWhenTheLeadHasAConversationState() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx)
        let now = Date(timeIntervalSince1970: 2_000_000)
        p.conversationState = .interested
        p.conversationStateSetAt = now
        p.conversationStateSource = .manual
        let earlierReplier = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        earlierReplier.replied = true
        earlierReplier.repliedAt = now.addingTimeInterval(-1_000)
        let laterReplier = Recipient(id: "b@presenter.example", email: "b@presenter.example", provenance: .presenter)
        laterReplier.replied = true
        laterReplier.repliedAt = now
        let neverReplied = Recipient(id: "c@manual.example", email: "c@manual.example", provenance: .manual)
        p.setRecipients([earlierReplier, laterReplier, neverReplied])

        RecipientConversationStateMigration.run(in: ctx)

        #expect(laterReplier.conversationState == .interested)   // the MOST RECENT replier
        #expect(laterReplier.conversationStateSetAt == now)
        #expect(laterReplier.conversationStateSource == .manual)
        #expect(earlierReplier.conversationState == nil)
        #expect(neverReplied.conversationState == nil)
    }

    @Test func isANoOpWhenTheLeadHasNoConversationState() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx)
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        r.replied = true
        p.setRecipients([r])

        RecipientConversationStateMigration.run(in: ctx)

        #expect(r.conversationState == nil)
    }

    @Test func isANoOpWhenNoRecipientEverReplied() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx)
        p.conversationState = .interested
        let r = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        p.setRecipients([r])

        RecipientConversationStateMigration.run(in: ctx)

        #expect(r.conversationState == nil)   // nothing to seed onto: no replier exists
    }

    @Test func isIdempotentOnceARecipientAlreadyHasAConversationState() throws {
        let ctx = ModelContext(try container())
        let p = prospect(ctx)
        p.conversationState = .interested
        let already = Recipient(id: "a@act.example", email: "a@act.example", provenance: .act)
        already.replied = true
        already.conversationState = .wantsToBook   // Dan (or a prior migration run) already set this directly
        p.setRecipients([already])

        RecipientConversationStateMigration.run(in: ctx)

        #expect(already.conversationState == .wantsToBook)   // untouched, never re-seeded or clobbered
    }
}
